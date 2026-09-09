import SafeGuardianMesh
// AgentConversationEngine.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import AgentRuntime
import BitFoundation
import Foundation

/// Owns the generic mechanics of every agent conversation: gate evaluation,
/// history assembly, AgentPromptInput construction, stream event processing,
/// mesh reply routing, and conversation logging. Agents supply an
/// AgentConversationConfig that expresses only what is specific to them.
@Observable @MainActor
final class AgentConversationEngine {
    static let shared = AgentConversationEngine()
    private init() {}

    private(set) var isRunning = false
    // The in-flight local generation, if any — kept so a new message can wait for the
    // previous turn's teardown to actually finish after cancelling it, rather than
    // racing a second streamResponse call onto the same session (LanguageModelSession
    // rejects that as concurrentRequests; see stopGeneration below).
    private var activeTask: Task<Void, Never>?

    enum ModelLoadPhase { case idle, waking, thinking }
    private(set) var modelLoadPhase: ModelLoadPhase = .idle

    /// Cancels the in-progress local generation, if any. The composer's send button
    /// becomes this while Nova is responding (see ContentView.sendButtonView); sending
    /// a new message calls this automatically first rather than rejecting the new
    /// message or silently queuing it, matching a normal chat app's stop/interrupt.
    func stopGeneration() {
        AgentProviderRegistry.shared.activeProvider.cancel()
    }

    func handle(
        prompt: String,
        image: Data? = nil,
        config: AgentConversationConfig,
        context: any AgentContext,
        threadPeerID: PeerID? = nil,
        replyTo: PeerID? = nil,
        replyID: String? = nil
    ) {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespaces)
        let provider = AgentProviderRegistry.shared.activeProvider

        // There is exactly one on-device model; it can only run one generation at a
        // time regardless of which thread asks. A new local message interrupts the
        // previous turn rather than being rejected or silently queued — cancel it now,
        // then have the new turn (below) await its actual teardown before calling
        // generate() again, so the two never race onto the same session.
        let previousTask: Task<Void, Never>? = replyTo == nil ? activeTask : nil
        if replyTo == nil, isRunning {
            provider.cancel()
        }

        let gateCtx = AgentGateContext(
            prompt: cleanPrompt,
            tick: context.deviceTick,
            isMeshQuery: replyTo != nil,
            modelID: provider.activeModelID
        )
        guard AgentGateRegistry.standard().shouldHandle(gateCtx) else { return }

        // For local queries: if the active provider requires configuration that is missing,
        // surface the error immediately rather than letting generate() fail asynchronously
        // and flooding the thread with status messages before the real error arrives.
        if replyTo == nil && provider.capabilities.requiresNetwork && !provider.isModelLoaded {
            context.addResponse(
                sender: config.displayName,
                content: "[provider not configured — open Settings and set the URL and model]",
                privatePeerID: threadPeerID ?? config.peerID
            )
            context.notifyChange()
            return
        }

        let isMeshQuery = replyTo != nil
        // Mesh queries use the canonical agent peerID; local queries use the active thread.
        let effectivePeerID = isMeshQuery ? config.peerID : (threadPeerID ?? config.peerID)

        // Capture the history boundary before any current-turn messages are inserted.
        // For local queries the caller already appended userTurn; subtract 1 to exclude it.
        // For mesh queries no local message was added; use the current count as-is.
        let currentCount = context.privateChats[effectivePeerID]?.count ?? 0
        let historyBoundary = isMeshQuery ? currentCount : max(0, currentCount - 1)

        if !isMeshQuery { modelLoadPhase = provider.isModelLoaded ? .thinking : .waking }

        let response: SafeGuardianMessage
        if isMeshQuery {
            response = SafeGuardianMessage(
                sender: config.displayName, content: "", timestamp: Date(), isRelay: false
            )
        } else {
            response = context.addResponse(
                sender: config.displayName, content: "...", privatePeerID: effectivePeerID
            )
            context.notifyChange()
        }

        // StatusCallback is nil for mesh queries (no local UI to update).
        // For local queries it updates response.content with the active tool name
        // so the user sees "get_device_state..." rather than a static spinner.
        let statusCallback: StatusCallback? = isMeshQuery ? nil : StatusCallback { [weak response] toolName in
            response?.content = "[\(toolName)...]"
            context.notifyChange()
        }

        let toolRegistry: AgentToolRegistry? =
            provider.capabilities.modelCapabilities?.supportsToolCalling == true
                ? config.toolRegistry?(context, statusCallback ?? StatusCallback { _ in }, effectivePeerID)
                : nil

        // Capture names and task record now (on MainActor); used inside the Task.
        let toolNames: [String] = toolRegistry?.names ?? []
        let taskRecord: AgentTaskRecord? = toolRegistry?.taskRecord

        let state = StreamState()
        #if DEBUG
        let startedAt = Date()
        #endif

        if !isMeshQuery { isRunning = true }
        let task = Task { @MainActor in
            defer { if !isMeshQuery { self.isRunning = false; self.modelLoadPhase = .idle } }
            // Wait for the interrupted turn's own teardown (its defer above) to actually
            // run before touching the shared session — cancellation is cooperative, not
            // instantaneous, and starting this turn's generate() before that finishes
            // would race a second streamResponse call onto the same LanguageModelSession.
            if let previousTask { _ = await previousTask.value }
            let baseSystemPrompt = config.systemPrompt()
            // Append tool names when tools are active so the model knows its vocabulary
            // regardless of how the chat template formats the injected schemas.
            // Non-capable models never reach this branch (toolNames is empty when
            // toolRegistry is nil), so no risk of hallucinated function-call syntax.
            let systemPrompt: String
            if toolNames.isEmpty {
                systemPrompt = baseSystemPrompt
            } else {
                systemPrompt = baseSystemPrompt
                    + "\n\nAvailable tools: \(toolNames.joined(separator: ", "))."
            }
            let modelID = provider.activeModelID
            let maxTurns = await PromptBudgetService.shared.recommendedTurnCount(modelID: modelID)
            let fullThread = context.privateChats[effectivePeerID] ?? []
            let historySlice = historyBoundary > 0 ? Array(fullThread.prefix(historyBoundary)) : []
            let rawHistory = Self.buildHistory(
                from: historySlice,
                agentDisplayName: config.displayName,
                maxTurns: maxTurns
            )
            let bytesPerToken = PromptBudgetService.bytesPerToken(modelID: modelID) ?? ContextCompressor.defaultBytesPerToken
            let history = ContextCompressor.compactIfNeeded(
                rawHistory, threshold: NovaConfig.contextCompactionThreshold, bytesPerToken: bytesPerToken
            )
            var input = AgentPromptInput(
                text: cleanPrompt,
                tick: context.deviceTick,
                systemPrompt: systemPrompt,
                history: history,
                toolRegistry: toolRegistry,
                isMeshQuery: replyTo != nil
            )
            input.imageData = image.map { [$0] } ?? []
            input.threadID = effectivePeerID.id
            let hasThinking = provider.capabilities.modelCapabilities?.hasThinkingMode == true

            for await event in provider.generate(input: input) {
                switch event {
                case .status:
                    break

                case .stats(let s):
                    state.stats = s

                case .token(let token):
                    if !isMeshQuery && modelLoadPhase == .waking { modelLoadPhase = .thinking }
                    if hasThinking {
                        state.pending += token
                        let (visible, thinking, remaining) = Self.drain(
                            from: state.pending, inThink: &state.inThink
                        )
                        state.visible += visible
                        state.thinking += thinking
                        state.pending = remaining
                        if !isMeshQuery {
                            if state.visible.isEmpty {
                                if state.inThink { state.thinkTokens += 1 }
                                response.content = state.thinkTokens > 0
                                    ? "[thinking... \(state.thinkTokens)t]"
                                    : "[thinking...]"
                            } else {
                                response.content = state.visible
                            }
                            context.notifyChange()
                        }
                    } else {
                        state.visible += token
                        if !isMeshQuery {
                            response.content = state.visible
                            context.notifyChange()
                        }
                    }

                case .complete:
                    state.reachedTerminal = true
                    if hasThinking, !state.inThink { state.visible += state.pending }
                    state.pending = ""

                    // task_complete tool provides the canonical summary; use it over model echo.
                    let finalContent = taskRecord?.taskCompleteSummary ?? state.visible

                    // shouldSendResponse nil = always send; false = suppress cleanly.
                    let send = config.shouldSendResponse.map { $0(finalContent) } ?? true

                    if !isMeshQuery {
                        if send {
                            response.content = finalContent.isEmpty ? "[no response]" : finalContent
                            context.notifyChange()
                        } else {
                            // Remove the placeholder entirely so the UI shows no orphaned bubble.
                            context.removeResponse(response, from: effectivePeerID)
                        }
                    }
                    if send, let peer = replyTo, !finalContent.isEmpty {
                        context.sendMeshReply(
                            agentID: config.agentID, content: finalContent,
                            to: peer, requestID: replyID
                        )
                    }
                    if let stats = state.stats, stats.promptTokens > 0 {
                        let promptByteLength = history.reduce(0) { $0 + $1.content.utf8.count }
                        await PromptBudgetService.shared.record(
                            modelID: modelID,
                            promptTokens: stats.promptTokens,
                            promptByteLength: promptByteLength,
                            historyTurnCount: history.count
                        )
                    }
                    #if DEBUG
                    ConversationLogger.shared.record(
                        agentThread: context.privateChats[effectivePeerID] ?? [],
                        systemPrompt: input.systemPrompt,
                        agentSenderID: config.displayName,
                        providerID: provider.id,
                        modelID: provider.activeModelID,
                        tick: context.deviceTick,
                        startedAt: startedAt,
                        thinkingContent: state.thinking.isEmpty ? nil : state.thinking,
                        toolCallNames: statusCallback?.calledToolNames ?? [],
                        stats: state.stats
                    )
                    #endif

                case .failure(let err):
                    state.reachedTerminal = true
                    if !isMeshQuery {
                        response.content = "[error: \(err)]"
                        context.notifyChange()
                    }
                }
            }
            // The loop ended without .complete or .failure only when this turn was
            // itself interrupted by a newer message (stopGeneration/provider.cancel()) —
            // AgentProviderStreaming.drain() finishes the stream silently on cancellation.
            // Leaving the placeholder at "..." or mid-token forever would look broken.
            if !state.reachedTerminal, !isMeshQuery {
                response.content = "[stopped]"
                context.notifyChange()
            }
        }
        if !isMeshQuery { activeTask = task }
    }

    // MARK: - History

    static func buildHistory(
        from thread: [SafeGuardianMessage],
        agentDisplayName: String,
        maxTurns: Int = NovaConfig.historyWindowSize
    ) -> [ConversationTurn] {
        let turns: [ConversationTurn] = thread.compactMap { msg in
            guard msg.sender != "local", msg.sender != "system" else { return nil }
            let c = msg.content
            guard !(c.hasPrefix("[") && c.hasSuffix("]")) else { return nil }
            let role: ConversationTurn.Role = msg.sender == agentDisplayName ? .assistant : .user
            return ConversationTurn(role: role, content: c)
        }
        return Array(turns.suffix(maxTurns))
    }

    // MARK: - Think-tag drain

    private static func drain(
        from input: String,
        inThink: inout Bool
    ) -> (visible: String, thinking: String, remainder: String) {
        let tagMaxLen = 8
        var visible = ""
        var thinking = ""
        var i = input.startIndex
        while i < input.endIndex {
            if !inThink, input[i...].hasPrefix("<think>") {
                inThink = true
                i = input.index(i, offsetBy: 7, limitedBy: input.endIndex) ?? input.endIndex
            } else if inThink, input[i...].hasPrefix("</think>") {
                inThink = false
                i = input.index(i, offsetBy: 8, limitedBy: input.endIndex) ?? input.endIndex
            } else if !inThink {
                let remaining = input[i...]
                let couldBeTag = remaining.count < tagMaxLen &&
                    ("<think>".hasPrefix(String(remaining)) || "</think>".hasPrefix(String(remaining)))
                if couldBeTag { break }
                visible.append(input[i])
                i = input.index(after: i)
            } else {
                let remaining = input[i...]
                if remaining.count < tagMaxLen, "</think>".hasPrefix(String(remaining)) { break }
                thinking.append(input[i])
                i = input.index(after: i)
            }
        }
        let remainder = i < input.endIndex ? String(input[i...]) : ""
        return (visible, thinking, remainder)
    }

    // MARK: - Stream state

    private final class StreamState {
        var pending: String = ""
        var visible: String = ""
        var thinking: String = ""
        var inThink: Bool = false
        var thinkTokens: Int = 0
        var stats: AgentGenerationStats? = nil
        var reachedTerminal: Bool = false
    }
}
