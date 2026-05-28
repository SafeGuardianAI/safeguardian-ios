import Foundation

enum NovaConfig {
    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"
    static let temperature: Float = 0.7
    // Qwen3 chain-of-thought at 193 tok/s on iPhone 16 can produce 10k+ think tokens
    // before visible output. 300s covers realistic upper-bound think blocks.
    static let generationTimeoutSeconds: UInt64 = 300
    static let historyWindowSize = 10
}
