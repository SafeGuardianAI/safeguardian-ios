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
    static let idleTimeoutSeconds: Double = 300

    // Stable system prompt — device state is injected as a prefix on the user
    // message so the session key (which hashes this string) never changes mid-run.
    static let stableSystemPrompt =
        "You are Nova, a concise on-device AI assistant embedded in SafeGuardian, " +
        "a disaster-response mesh communication app. Keep responses brief."

    /// Returns capability flags for a given HuggingFace model ID.
    /// Pattern-matched against lowercased ID; most specific match wins.
    static func capabilities(for modelID: String) -> ModelCapabilities {
        let id = modelID.lowercased()
        // Qwen3 and QwQ use chain-of-thought by default; /no_think suppresses it.
        // Tool calling requires ~3B+ parameters for reliable format compliance.
        let isLargeEnough = id.contains("2b") || id.contains("3b") || id.contains("4b") ||
            id.contains("7b") || id.contains("8b") || id.contains("14b") ||
            id.contains("32b") || id.contains("72b")
        if id.contains("qwen3") || id.contains("qwq") {
            return ModelCapabilities(hasThinkingMode: true, noThinkSuffix: " /no_think",
                                     supportsToolCalling: isLargeEnough)
        }
        if id.contains("deepseek-r1") {
            return ModelCapabilities(hasThinkingMode: true, noThinkSuffix: nil,
                                     supportsToolCalling: isLargeEnough)
        }
        if id.contains("gemma") {
            // Gemma models support function calling from the 4B class upward.
            let toolCapable = id.contains("4b") || id.contains("7b") || id.contains("8b") ||
                id.contains("9b") || id.contains("27b")
            return ModelCapabilities(hasThinkingMode: false, noThinkSuffix: nil,
                                     supportsToolCalling: toolCapable)
        }
        // Qwen2.5 and earlier do not reliably emit structured tool-call JSON;
        // only Qwen3/QwQ (handled above) and Gemma 4B+ are confirmed tool-capable.
        return ModelCapabilities(hasThinkingMode: false, noThinkSuffix: nil,
                                 supportsToolCalling: false)
    }
}
