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
        config: AgentConversationConfig,
        context: any AgentContext,
        replyTo: PeerID? = nil
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

        if !provider.isModelLoaded {
            context.addAgentLocalMessage(
                provider.isLoading ? "downloading model..." : "initializing...",
                to: config.peerID
            )
        }

        let response = context.addResponse(
            sender: config.displayName, content: "[thinking...]", privatePeerID: config.peerID
        )
        context.notifyChange()

        let toolRegistry: AgentToolRegistry? =
            provider.capabilities.modelCapabilities?.supportsToolCalling == true
                ? config.toolRegistry?(context)
                : nil

        let state = StreamState()
        #if DEBUG
        let startedAt = Date()
        #endif

        Task { @MainActor in
            let systemPrompt = config.systemPrompt()
            let modelID = provider.activeModelID
            let maxTurns = await PromptBudgetService.shared.recommendedTurnCount(modelID: modelID)
            let history = Self.buildHistory(
                from: context.privateChats[config.peerID] ?? [],
                agentDisplayName: config.displayName,
                maxTurns: maxTurns
            )
            let input = AgentPromptInput(
                text: cleanPrompt,
                tick: context.deviceTick,
                systemPrompt: systemPrompt,
                history: history,
                toolRegistry: toolRegistry,
                isMeshQuery: replyTo != nil
            )
            let hasThinking = provider.capabilities.modelCapabilities?.hasThinkingMode == true

            for await event in provider.generate(input: input) {
                switch event {
                case .status(let s):
                    response.content = s
                    context.notifyChange()

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
                        if state.visible.isEmpty {
                            if state.inThink { state.thinkTokens += 1 }
                            response.content = state.thinkTokens > 0
                                ? "[thinking... \(state.thinkTokens)t]"
                                : "[thinking...]"
                        } else {
                            response.content = state.visible
                        }
                    } else {
                        state.visible += token
                        response.content = state.visible
                    }
                    context.notifyChange()

                case .complete:
                    if hasThinking, !state.inThink { state.visible += state.pending }
                    state.pending = ""
                    response.content = state.visible.isEmpty ? "[no response]" : state.visible
                    context.notifyChange()
                    if let peer = replyTo, !state.visible.isEmpty {
                        context.sendMeshReply(
                            agentID: config.agentID, content: state.visible, to: peer
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
                        agentThread: context.privateChats[config.peerID] ?? [],
                        systemPrompt: input.systemPrompt,
                        agentSenderID: config.displayName,
                        providerID: provider.id,
                        modelID: provider.activeModelID,
                        tick: context.deviceTick,
                        startedAt: startedAt,
                        thinkingContent: state.thinking.isEmpty ? nil : state.thinking,
                        stats: state.stats
                    )
                    #endif

                case .failure(let err):
                    response.content = "[error: \(err)]"
                    context.notifyChange()
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
        let completed = thread.count >= 2 ? Array(thread.dropLast(2)) : []
        let turns: [ConversationTurn] = completed.compactMap { msg in
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
