import Foundation

enum NovaConfig {
    // Default HuggingFace model identifier.
    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"

    // Hard cap on tokens generated per response. Prevents Qwen3 chain-of-thought
    // from running unbounded and exhausting device memory.
    static let maxTokens = 512

    // Sampling temperature for response generation.
    static let temperature: Float = 0.7

    // Wall-clock timeout in seconds for an entire generation pass.
    static let generationTimeoutSeconds: UInt64 = 60

    // Appended to every system prompt to suppress Qwen3 <think>...</think> reasoning
    // blocks, which otherwise generate thousands of invisible tokens before any output.
    static let noThinkSuffix = "\n/no_think"

    // Number of prior conversation turns passed to ChatSession as seeding history.
    static let historyWindowSize = 10
}
