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
        if id.contains("qwen3") || id.contains("qwq") {
            return ModelCapabilities(hasThinkingMode: true, noThinkSuffix: " /no_think")
        }
        // DeepSeek-R1 distillations use thinking mode.
        if id.contains("deepseek-r1") {
            return ModelCapabilities(hasThinkingMode: true, noThinkSuffix: nil)
        }
        return ModelCapabilities(hasThinkingMode: false, noThinkSuffix: nil)
    }
}
