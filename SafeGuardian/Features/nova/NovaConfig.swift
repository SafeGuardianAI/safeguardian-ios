import Foundation

enum NovaConfig {
    // Default HuggingFace model identifier.
    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"

    // Sampling temperature for response generation.
    static let temperature: Float = 0.7

    // Wall-clock timeout in seconds for an entire generation pass.
    static let generationTimeoutSeconds: UInt64 = 60

    // Appended to every system prompt to suppress Qwen3 <think>...</think> reasoning
    // blocks, which otherwise generate thousands of invisible tokens before any output.
    // This is the primary guard against chain-of-thought RAM exhaustion; maxTokens is
    // not used because the correct cap is model-dependent and nil (no cap) is the safe
    // default once think-mode is disabled.
    static let noThinkSuffix = "\n/no_think"

    // Number of prior conversation turns passed to ChatSession as seeding history.
    static let historyWindowSize = 10
}
