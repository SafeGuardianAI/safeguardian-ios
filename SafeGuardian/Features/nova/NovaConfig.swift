import Foundation

/// Per-model capability flags. Add an entry to `capabilities(for:)` when
/// onboarding a new model. The inference layer reads these at runtime so
/// switching models requires no changes outside this file.
struct ModelCapabilities {
    /// Model produces <think>…</think> chain-of-thought blocks.
    let hasThinkingMode: Bool
    /// Appended verbatim to every user message to suppress thinking. Nil when
    /// hasThinkingMode is false or thinking cannot be suppressed via message text.
    let noThinkSuffix: String?
    /// Model reliably emits structured tool call JSON. False for models below ~3B
    /// parameters where tool calling format compliance is unreliable.
    let supportsToolCalling: Bool
    /// Model accepts image inputs (VLM). Detected from model ID patterns such as
    /// "-vl", "vision", or "llava".
    let supportsVision: Bool
}

/// Provider-agnostic generation performance stats. MLX maps GenerateCompletionInfo here;
/// other providers compute equivalent fields from their own APIs.
struct AgentGenerationStats: Sendable {
    let promptTokens: Int
    let generationTokens: Int
    let promptMs: Double
    let generateMs: Double
    var tokensPerSecond: Double { generateMs > 0 ? Double(generationTokens) / (generateMs / 1000) : 0 }
    var promptTokensPerSecond: Double { promptMs > 0 ? Double(promptTokens) / (promptMs / 1000) : 0 }
}

enum AgentGenerationEvent: Sendable {
    case status(String)
    case token(String)
    case stats(AgentGenerationStats)
    case complete
    case failure(String)
}

enum NovaConfig {
    static let defaultModelID = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    static let temperature: Float = 0.7
    static let generationTimeoutSeconds: UInt64 = 300
    static let historyWindowSize = 10
    /// Maximum number of tool dispatch calls per generation session.
    /// When reached the dispatch returns a terminal error so the model stops looping.
    static let maxToolIterations = 8
    static let idleTimeoutSeconds: Double = 300
    /// Battery floor below which Nova skips mesh queries entirely to preserve power.
    /// Local (@nova) queries are always served regardless of battery level.
    static let meshQueryMinBatteryPct: Float = 0.10

    // Base system prompt — developer-controlled, not user editable.
    // Device state is injected as a prefix on the user message so this string
    // stays stable across calls (its hash is the session cache key).
    // Tool descriptions here are for non-tool-capable models that do not receive
    // function specs; tool-capable models get the authoritative JSON schemas via AgentToolRegistry.
    static let stableSystemPrompt = """
        You are Nova, an on-device AI assistant embedded in SafeGuardian, a disaster-response \
        mesh communication app. SafeGuardian operates without internet infrastructure — it relays \
        encrypted messages over Bluetooth between nearby devices.

        Your role is to assist with disaster response: situational awareness, peer coordination, \
        safety checks, and information relay. Be concise. In emergencies, every word costs time.

        When asked about device state, peers, or location, use your tools rather than guessing. \
        Your responses are private and never sent to the mesh unless the user explicitly shares them.

        Available tools:
        get_device_state — battery level, GPS coordinates, connection status
        get_status — brief device and mesh summary
        get_full_status — detailed status with peer list and storage
        get_memory — facts stored about this device or user
        get_storage — available storage in GB
        list_peers — connected mesh peers with their peer IDs
        send_agent_message — send a message to a named agent on a specific peer
        broadcast_to_agents — broadcast a message to all agent-capable peers on the mesh
        request_peer_location — ask a peer to share their GPS coordinates (requires their approval)
        """

    /// Composes the full system prompt from the base plus an optional user personalization blurb.
    /// The blurb is appended as a "User preference:" line and is capped by NovaPersonalizationStore.
    static func buildSystemPrompt(personalization: String?) -> String {
        guard let p = personalization?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else {
            return stableSystemPrompt
        }
        return stableSystemPrompt + "\n\nUser preference: \(p)"
    }

    /// Returns capability flags for a given HuggingFace model ID.
    /// Pattern-matched against lowercased ID; most specific match wins.
    static func capabilities(for modelID: String) -> ModelCapabilities {
        let id = modelID.lowercased()
        // Qwen3 and QwQ use chain-of-thought by default; /no_think suppresses it.
        // Tool calling requires ~3B+ parameters for reliable format compliance.
        let isLargeEnough = id.contains("2b") || id.contains("3b") || id.contains("4b") ||
            id.contains("7b") || id.contains("8b") || id.contains("14b") ||
            id.contains("32b") || id.contains("72b")
        // Vision: model IDs that include a VLM marker accept image inputs.
        let isVision = id.contains("-vl") || id.contains("vision") || id.contains("llava")
        if id.contains("qwen3") || id.contains("qwq") {
            return ModelCapabilities(hasThinkingMode: true, noThinkSuffix: " /no_think",
                                     supportsToolCalling: isLargeEnough, supportsVision: isVision)
        }
        if id.contains("deepseek-r1") {
            return ModelCapabilities(hasThinkingMode: true, noThinkSuffix: nil,
                                     supportsToolCalling: isLargeEnough, supportsVision: isVision)
        }
        if id.contains("gemma") {
            // Gemma models support function calling from the 4B class upward.
            let toolCapable = id.contains("4b") || id.contains("7b") || id.contains("8b") ||
                id.contains("9b") || id.contains("27b")
            return ModelCapabilities(hasThinkingMode: false, noThinkSuffix: nil,
                                     supportsToolCalling: toolCapable, supportsVision: isVision)
        }
        // Qwen2.5 and earlier do not reliably emit structured tool-call JSON;
        // only Qwen3/QwQ (handled above) and Gemma 4B+ are confirmed tool-capable.
        return ModelCapabilities(hasThinkingMode: false, noThinkSuffix: nil,
                                 supportsToolCalling: false, supportsVision: isVision)
    }
}
