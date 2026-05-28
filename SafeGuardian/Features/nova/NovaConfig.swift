import Foundation

enum NovaConfig {
    // Default HuggingFace model identifier.
    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"

    // Sampling temperature for response generation.
    static let temperature: Float = 0.7

    // Wall-clock timeout in seconds for an entire generation pass.
    // Qwen3 chain-of-thought at 193 tok/s on iPhone 16 can produce 10k+ think tokens
    // before any visible output. 300 seconds covers realistic upper-bound think blocks.
    static let generationTimeoutSeconds: UInt64 = 300

    // Number of prior conversation turns passed to ChatSession as seeding history.
    static let historyWindowSize = 10
}
