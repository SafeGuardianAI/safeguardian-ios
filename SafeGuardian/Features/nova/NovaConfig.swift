import Foundation

enum NovaConfig {
    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"
    static let temperature: Float = 0.7
    static let generationTimeoutSeconds: UInt64 = 300
    static let historyWindowSize = 10
    static let idleTimeoutSeconds: Double = 300  // release model after 5 min idle

    // Stable Nova identity — device state is NOT here.
    // Runtime observations (battery, GPS, peers) are injected as a decorated
    // prefix on the user message so the session key never changes.
    static let stableSystemPrompt =
        "You are Nova, a concise on-device AI assistant embedded in SafeGuardian, " +
        "a disaster-response mesh communication app. Keep responses brief."
}
