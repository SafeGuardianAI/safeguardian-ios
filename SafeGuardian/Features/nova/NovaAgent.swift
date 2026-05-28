import BitFoundation
import Foundation
import MLXLMCommon

@MainActor
final class NovaAgent: AgentProcessor {
    let agentID = "nova"
    let triggerPrefix = "@nova"
    static let novaPeerID = PeerID(str: "nova-local")
    
    func shouldHandle(_ message: String) -> Bool {
        let lower = message.trimmed.lowercased()
        return lower == triggerPrefix || lower.hasPrefix(triggerPrefix + " ")
    }
    
    func handle(prompt: String, context: AgentContext) {
        let service = MLXInferenceService.shared
        
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespaces)
        
        if service.isLoading {
            let shortID = service.activeModelID.components(separatedBy: "/").last ?? service.activeModelID
            context.addLocalMessage("nova · \(shortID) · loading, please wait...")
            return
        }

        if !service.isModelLoaded {
            let shortID = service.activeModelID.components(separatedBy: "/").last ?? service.activeModelID
            context.addLocalMessage("nova · \(shortID) · initializing...")
        }

        var dynamicSystemPrompt = "You are Nova, a concise on-device AI assistant embedded in SafeGuardian, a disaster-response mesh communication app. Keep responses brief."

        if let tick = context.deviceTick {
            let battery = Int(tick.batteryPct * 100)
            let loc = String(format: "%.4f, %.4f", tick.lat, tick.lon)
            let geohash = context.selectedGeohash ?? "mesh"
            
            dynamicSystemPrompt += "\n\nCurrent Device State:"
            dynamicSystemPrompt += "\n- Battery: \(battery)%"
            dynamicSystemPrompt += "\n- Location: \(loc) (geohash: \(geohash))"
            dynamicSystemPrompt += "\n- Mesh Peers Nearby: \(tick.peerCount)"
            dynamicSystemPrompt += "\n- Transport: \(tick.transportTier.rawValue)"
        }

        let prior = (context.privateChats[Self.novaPeerID] ?? []).suffix(NovaConfig.historyWindowSize)
        let history = prior.compactMap { msg -> Chat.Message? in
            let role: Chat.Message.Role = (msg.sender == Self.novaPeerID.id) ? .assistant : .user
            // Status messages are formatted as "[...]"; exclude them from conversation history.
            guard !msg.content.hasPrefix("[") || !msg.content.hasSuffix("]") else { return nil }
            return Chat.Message(role: role, content: msg.content)
        }

        let response = context.addResponse(sender: Self.novaPeerID.id, content: "[thinking...]", privatePeerID: Self.novaPeerID)
        context.notifyChange()

        let state = NovaStreamState()

        service.generate(
            systemPrompt: dynamicSystemPrompt,
            history: history,
            userMessage: cleanPrompt,
            onStatus: { status in
                Task { @MainActor in
                    response.content = status
                    context.notifyChange()
                }
            },
            onToken: { token in
                Task { @MainActor in
                    autoreleasepool {
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

                        // Throttle updates to ~10 FPS (100ms) to prevent main thread saturation and memory leaks
                        let now = Date().timeIntervalSince1970
                        if now - state.lastUpdate >= 0.1 {
                            state.lastUpdate = now
                            context.notifyChange()
                        }
                    }
                }
            },
            onComplete: {
                Task { @MainActor in
                    // Flush any pending buffer content that didn't contain a complete tag boundary.
                    if !state.inThink {
                        state.visible += state.pending
                    }
                    state.pending = ""
                    if state.visible.isEmpty {
                        response.content = "[no response]"
                    } else {
                        response.content = state.visible
                    }
                    context.notifyChange()
                }
            }
        )
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
                // Stop before a potential partial tag at the end so we don't emit characters
                // that might be the start of a <think> or </think> spanning the next token.
                let remaining = input[i...]
                let couldBeTag = remaining.count < tagMaxLen &&
                    ("<think>".hasPrefix(String(remaining)) || "</think>".hasPrefix(String(remaining)))
                if couldBeTag { break }
                result.append(input[i])
                i = input.index(after: i)
            } else {
                // Buffer a potential partial </think> spanning the next token;
                // without this, a split close tag is silently discarded.
                let remaining = input[i...]
                if remaining.count < tagMaxLen, "</think>".hasPrefix(String(remaining)) { break }
                i = input.index(after: i)
            }
        }
        let remainder = i < input.endIndex ? String(input[i...]) : ""
        return (result, remainder)
    }
}
