import BitFoundation
import Foundation
import MLXLMCommon

@MainActor
final class NovaAgent: AgentProcessor {
    let agentID = "nova"
    let displayName = "Nova"
    let triggerPrefix = "@nova"
    let peerID = PeerID(str: "nova-local")
    static let novaPeerID = PeerID(str: "nova-local")

    func shouldHandle(_ message: String) -> Bool {
        let lower = message.trimmed.lowercased()
        return lower == triggerPrefix || lower.hasPrefix(triggerPrefix + " ")
    }

    func handle(prompt: String, context: AgentContext, replyTo: PeerID? = nil) {
        // Layer 1: battery gate — skip mesh queries on critically low battery.
        if replyTo != nil {
            let battery = context.deviceTick?.batteryPct ?? 1.0
            if Float(battery) < NovaConfig.meshQueryMinBatteryPct {
                return
            }
        }

        let provider = AgentProviderRegistry.shared.activeProvider
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespaces)

        if !provider.isModelLoaded {
            context.addAgentLocalMessage(provider.isLoading ? "downloading model..." : "initializing...", to: peerID)
        }

        let response = context.addResponse(
            sender: displayName, content: "[thinking...]", privatePeerID: Self.novaPeerID
        )
        context.notifyChange()

        let toolRegistry: AgentToolRegistry? = provider.capabilities.modelCapabilities?.supportsToolCalling == true
            ? AgentToolRegistry.standard(agentID: agentID, context: context)
            : nil

        let state = NovaStreamState()
        #if DEBUG
        let startedAt = Date()
        #endif

        Task { @MainActor in
            let input = AgentPromptInput(
                text: cleanPrompt,
                tick: context.deviceTick,
                toolRegistry: toolRegistry,
                isMeshQuery: replyTo != nil
            )
            for await event in provider.generate(input: input) {
                switch event {
                case .status(let s):
                    response.content = s
                    context.notifyChange()
                case .stats(let s):
                    state.stats = s
                case .token(let token):
                    state.pending += token
                    let (visible, thinking, remaining) = self.drain(from: state.pending, inThink: &state.inThink)
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
                    context.notifyChange()
                case .complete:
                    if !state.inThink { state.visible += state.pending }
                    state.pending = ""
                    // Layer 2: sentinel skip — model replied with SKIP (or tool-capable
                    // model called skip_reply producing no visible text).
                    let isSkip = state.visible.trimmingCharacters(in: .whitespacesAndNewlines) == "SKIP"
                        || (state.visible.isEmpty && replyTo != nil)
                    if isSkip {
                        context.removeResponse(response, from: Self.novaPeerID)
                        context.notifyChange()
                    } else {
                        response.content = state.visible.isEmpty ? "[no response]" : state.visible
                        context.notifyChange()
                        if let peer = replyTo, !state.visible.isEmpty {
                            context.sendMeshReply(agentID: agentID, content: state.visible, to: peer)
                        }
                    }
                    #if DEBUG
                    ConversationLogger.shared.record(
                        agentThread: context.privateChats[Self.novaPeerID] ?? [],
                        systemPrompt: NovaConfig.stableSystemPrompt,
                        agentSenderID: displayName,
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

    private class NovaStreamState {
        var pending: String = ""
        var visible: String = ""
        var thinking: String = ""
        var inThink: Bool = false
        var thinkTokens: Int = 0
        var stats: AgentGenerationStats? = nil
    }

    // Drains the pending buffer, separating visible output from think-block content.
    // Returns (visible, thinking, remainder) where remainder is an incomplete tag suffix
    // that may complete with the next token.
    private func drain(from input: String, inThink: inout Bool) -> (visible: String, thinking: String, remainder: String) {
        let tagMaxLen = 8 // len("</think>")
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
}
