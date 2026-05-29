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
        let provider = NovaProviderRegistry.shared.activeProvider
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespaces)

        if !provider.isModelLoaded {
            context.addAgentLocalMessage("nova · \(provider.displayName) · \(provider.isLoading ? "downloading..." : "initializing...")", to: peerID)
        }

        let response = context.addResponse(
            sender: displayName, content: "[thinking...]", privatePeerID: Self.novaPeerID
        )
        context.notifyChange()

        let state = NovaStreamState()

        Task { @MainActor in
            for await event in provider.generate(input: NovaPromptInput(text: cleanPrompt, tick: context.deviceTick)) {
                switch event {
                case .status(let s):
                    response.content = s
                    context.notifyChange()
                case .token(let token):
                    state.pending += token
                    let (visible, remaining) = self.drainVisible(from: state.pending, inThink: &state.inThink)
                    state.visible += visible
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
        var inThink: Bool = false
        var thinkTokens: Int = 0  // tokens consumed inside think blocks
        var lastUpdate: TimeInterval = 0
    }

    // Drains all complete visible characters from `input`, leaving any incomplete tag suffix
    // (e.g. a partial "<think" that might complete with the next token) in the returned remainder.
    private func drainVisible(from input: String, inThink: inout Bool) -> (visible: String, remainder: String) {
        let tagMaxLen = 8 // len("</think>")
        var result = ""
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
                result.append(input[i])
                i = input.index(after: i)
            } else {
                let remaining = input[i...]
                if remaining.count < tagMaxLen, "</think>".hasPrefix(String(remaining)) { break }
                i = input.index(after: i)
            }
        }
        let remainder = i < input.endIndex ? String(input[i...]) : ""
        return (result, remainder)
    }
}
