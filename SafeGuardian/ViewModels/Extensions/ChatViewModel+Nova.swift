import BitFoundation
import Foundation

extension ChatViewModel {
    static let novaPeerID = PeerID(str: "nova-local")

    @MainActor
    func routeToNova(_ prompt: String) {
        let service = MLXInferenceService.shared

        if service.isLoading {
            addLocalMessage("nova is loading the model, please wait…")
            return
        }

        // Build dynamic system prompt with current device state
        var dynamicSystemPrompt = "You are Nova, a concise on-device AI assistant embedded in SafeGuardian, a disaster-response mesh communication app. Keep responses brief."
        
        if let tick = novaBroadcaster.latestTick {
            let battery = Int(tick.batteryPct * 100)
            let loc = String(format: "%.4f, %.4f", tick.lat, tick.lon)
            let geohash = LocationChannelManager.shared.selectedChannel.nostrGeohashTag ?? "mesh"
            
            dynamicSystemPrompt += "\n\nCurrent Device State:"
            dynamicSystemPrompt += "\n- Battery: \(battery)%"
            dynamicSystemPrompt += "\n- Location: \(loc) (geohash: \(geohash))"
            dynamicSystemPrompt += "\n- Mesh Peers Nearby: \(tick.peerCount)"
            dynamicSystemPrompt += "\n- Transport: \(tick.transportTier.rawValue)"
        }

        // Record the user turn in the Nova DM thread
        let userMsg = SafeGuardianMessage(
            sender: "local", content: prompt, timestamp: Date(), isRelay: false)
        if privateChats[Self.novaPeerID] == nil {
            privateChats[Self.novaPeerID] = []
        }
        privateChats[Self.novaPeerID]?.append(userMsg)

        // Placeholder for the streaming response
        let response = SafeGuardianMessage(
            sender: Self.novaPeerID.id, content: "[thinking…]", timestamp: Date(), isRelay: false)
        privateChats[Self.novaPeerID]?.append(response)
        messages.append(response)
        objectWillChange.send()

        // raw accumulates the full token stream; inThink tracks whether we are
        // inside a Qwen3 <think>…</think> reasoning block that must not render.
        var raw = ""
        var inThink = false

        // Build conversation history context (capped at 10 turns for token efficiency)
        let prior = (privateChats[Self.novaPeerID] ?? []).suffix(10)
        var context = ""
        for msg in prior {
            let label = msg.sender == Self.novaPeerID.id ? "Nova" : "User"
            context += "\n\(label): \(msg.content)"
        }
        
        let fullPrompt = "\(context)\nUser: \(prompt)\nNova:"

        service.generate(
            systemPrompt: dynamicSystemPrompt,
            userMessage: fullPrompt,
            onStatus: { [weak response, weak self] status in
                guard let response, let self else { return }
                response.content = status
                self.objectWillChange.send()
            },
            onToken: { [weak response, weak self] token in
                guard let response, let self else { return }
                raw += token
                // Re-derive the visible content from the full raw string each tick
                // so partial tag boundaries in the token stream are handled correctly.
                let visible = Self.stripThinkBlocks(from: raw, inThink: &inThink)
                response.content = visible.isEmpty ? "[thinking…]" : visible
                self.objectWillChange.send()
            },
            onComplete: { [weak response, weak self] in
                guard let response, let self else { return }
                // Final pass: strip any unclosed think block left open at end of stream
                var finalInThink = false
                let finalVisible = Self.stripThinkBlocks(from: raw, inThink: &finalInThink)
                if finalVisible.isEmpty {
                    response.content = "[no response]"
                } else {
                    response.content = finalVisible
                }
                self.objectWillChange.send()
            }
        )
    }

    /// Strips `<think>…</think>` blocks produced by Qwen3's chain-of-thought.
    /// Updates `inThink` so callers can track open blocks across incremental calls.
    nonisolated private static func stripThinkBlocks(from raw: String, inThink: inout Bool) -> String {
        var result = ""
        var i = raw.startIndex
        // Seed inThink from scratch on each full-string pass
        inThink = false
        while i < raw.endIndex {
            if !inThink, raw[i...].hasPrefix("<think>") {
                inThink = true
                i = raw.index(i, offsetBy: 7, limitedBy: raw.endIndex) ?? raw.endIndex
            } else if inThink, raw[i...].hasPrefix("</think>") {
                inThink = false
                i = raw.index(i, offsetBy: 8, limitedBy: raw.endIndex) ?? raw.endIndex
            } else {
                if !inThink { result.append(raw[i]) }
                i = raw.index(after: i)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
