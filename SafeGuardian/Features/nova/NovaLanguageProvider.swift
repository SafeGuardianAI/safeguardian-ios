import Foundation

struct NovaPromptInput: Sendable {
    var text: String
    var tick: NovaStateTick?

    func decorated(modelID: String) -> String {
        let caps = NovaConfig.capabilities(for: modelID)
        var result = text
        if let tick {
            let battery = Int(tick.batteryPct * 100)
            let loc = String(format: "%.4f,%.4f", tick.lat, tick.lon)
            result = "[state: battery \(battery)%, loc \(loc), \(tick.peerCount) peers] \(result)"
        }
        if let suffix = caps.noThinkSuffix {
            result += suffix
        }
        return result
    }
}

struct NovaProviderCapabilities: Sendable {
    let requiresNetwork: Bool
}

@MainActor
protocol NovaLanguageProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var capabilities: NovaProviderCapabilities { get }
    var isLoading: Bool { get }
    var isModelLoaded: Bool { get }
    func generate(input: NovaPromptInput) -> AsyncStream<NovaGenerationEvent>
    func cancel()
}
