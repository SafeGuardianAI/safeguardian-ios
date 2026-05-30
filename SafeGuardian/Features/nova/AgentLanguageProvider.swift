import Foundation

struct AgentPromptInput: Sendable {
    var text: String
    var tick: NovaStateTick?
    /// Full composed system prompt (base + personalization). Set by the caller.
    var systemPrompt: String = NovaConfig.stableSystemPrompt
    /// Windowed prior conversation turns, oldest first. Assembled by the agent
    /// layer from privateChats and capped at NovaConfig.historyWindowSize turns.
    /// Excludes the current user message — that is carried by `text`.
    var history: [ConversationTurn] = []
    /// Tool registry for this call. Nil when the model does not support tools.
    var toolRegistry: AgentToolRegistry?
    /// True when this prompt originates from a remote peer via AgentMeshRouting.
    /// Used by AgentGateRegistry to apply mesh-only gate conditions.
    var isMeshQuery: Bool = false

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

struct AgentProviderCapabilities: Sendable {
    let requiresNetwork: Bool
    /// Capability flags for the currently active model. Nil until a model is loaded.
    var modelCapabilities: ModelCapabilities?
}

@MainActor
protocol AgentLanguageProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// The HuggingFace model ID currently active for this provider.
    var activeModelID: String { get }
    var capabilities: AgentProviderCapabilities { get }
    var isLoading: Bool { get }
    var isModelLoaded: Bool { get }
    func generate(input: AgentPromptInput) -> AsyncStream<AgentGenerationEvent>
    func cancel()
}
