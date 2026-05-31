// AgentConversationEngine.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import BitFoundation
import Foundation
import MLXLMCommon

/// Owns the generic mechanics of every agent conversation: gate evaluation,
/// history assembly, AgentPromptInput construction, stream event processing,
/// mesh reply routing, and conversation logging. Agents supply an
/// AgentConversationConfig that expresses only what is specific to them.
@MainActor
final class AgentConversationEngine {
    static let shared = AgentConversationEngine()
    private init() {}

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
            let response = context.addResponse(
                sender: config.displayName,
                content: "[provider not configured — open Settings and set the URL and model]",
                privatePeerID: threadPeerID ?? config.peerID
            )
            _ = response
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

        // For local queries only: show loading state and insert a response placeholder
        // that streams tokens into the chat. Mesh queries run inference silently —
        // the reply goes back to the requester; nothing appears in the local thread.
        if !isMeshQuery && !provider.isModelLoaded {
            context.addAgentLocalMessage(
                provider.isLoading ? "downloading model..." : "initializing...",
                to: effectivePeerID
            )
        }

        let response: SafeGuardianMessage
        if isMeshQuery {
            response = SafeGuardianMessage(
                sender: config.displayName, content: "", timestamp: Date(), isRelay: false
            )
        } else {
            response = context.addResponse(
                sender: config.displayName, content: "[thinking...]", privatePeerID: effectivePeerID
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
                ? config.toolRegistry?(context, statusCallback ?? StatusCallback { _ in }, config.approvalRequired)
                : nil

        let state = StreamState()
        #if DEBUG
        let startedAt = Date()
        #endif

        Task { @MainActor in
            let systemPrompt = config.systemPrompt()
            let modelID = provider.activeModelID
            let maxTurns = await PromptBudgetService.shared.recommendedTurnCount(modelID: modelID)
            let fullThread = context.privateChats[effectivePeerID] ?? []
            let historySlice = historyBoundary > 0 ? Array(fullThread.prefix(historyBoundary)) : []
            let history = Self.buildHistory(
                from: historySlice,
                agentDisplayName: config.displayName,
                maxTurns: maxTurns
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
            let hasThinking = provider.capabilities.modelCapabilities?.hasThinkingMode == true

            for await event in provider.generate(input: input) {
                switch event {
                case .status(let s):
                    if !isMeshQuery {
                        response.content = s
                        context.notifyChange()
                    }

                case .stats(let s):
                    state.stats = s

                case .token(let token):
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
                    if hasThinking, !state.inThink { state.visible += state.pending }
                    state.pending = ""

                    // shouldSendResponse nil = always send; false = suppress cleanly.
                    let send = config.shouldSendResponse.map { $0(state.visible) } ?? true

                    if !isMeshQuery {
                        if send {
                            response.content = state.visible.isEmpty ? "[no response]" : state.visible
                            context.notifyChange()
                        } else {
                            // Remove the placeholder entirely so the UI shows no orphaned bubble.
                            context.removeResponse(response, from: effectivePeerID)
                        }
                    }
                    if send, let peer = replyTo, !state.visible.isEmpty {
                        context.sendMeshReply(
                            agentID: config.agentID, content: state.visible,
                            to: peer, requestID: replyID
                        )
                    }
                    if let stats = state.stats, stats.promptTokens > 0 {
                        await PromptBudgetService.shared.record(
                            modelID: modelID,
                            promptTokens: stats.promptTokens,
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
                    if !isMeshQuery {
                        response.content = "[error: \(err)]"
                        context.notifyChange()
                    }
                }
            }
        }
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
    }
}
