import Foundation

enum NovaConfig {
    // Default HuggingFace model identifier.
    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"

    // Sampling temperature for response generation.
    static let temperature: Float = 0.7

    // Wall-clock timeout in seconds for an entire generation pass.
    static let generationTimeoutSeconds: UInt64 = 60

    // Number of prior conversation turns passed to ChatSession as seeding history.
    static let historyWindowSize = 10
}
