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

    func handle(prompt: String, context: AgentContext) {
        let provider = AgentProviderRegistry.shared.activeProvider
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespaces)

        if !provider.isModelLoaded {
            context.addAgentLocalMessage("nova · \(provider.displayName) · \(provider.isLoading ? "downloading..." : "initializing...")", to: peerID)
        }

        let response = context.addResponse(
            sender: displayName, content: "[thinking...]", privatePeerID: Self.novaPeerID
        )
        context.notifyChange()

        let toolRegistry: AgentToolRegistry? = {
            guard provider.capabilities.modelCapabilities?.supportsToolCalling == true else { return nil }
            return AgentToolRegistry.build(
                agentID: agentID,
                context: context,
                meshTools: AgentToolEntry.meshTools(agentID: agentID)
            )
        }()

        let state = NovaStreamState()
        #if DEBUG
        let startedAt = Date()
        #endif

        Task { @MainActor in
            let input = AgentPromptInput(text: cleanPrompt, tick: context.deviceTick, toolRegistry: toolRegistry)
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
                    response.content = state.visible.isEmpty ? "[no response]" : state.visible
                    context.notifyChange()
                    #if DEBUG
                    ConversationLogger.shared.record(
                        agentThread: context.privateChats[Self.novaPeerID] ?? [],
                        systemPrompt: NovaConfig.stableSystemPrompt,
                        agentSenderID: displayName,
                        providerID: provider.id,
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
