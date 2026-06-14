import AgentInfra
import Foundation

enum NovaConfig {

    // MARK: - LLM model catalog

    /// A candidate on-device LLM. All models are 4-bit quantized and sourced
    /// from mlx-community on HuggingFace. The minRAMMB / minStorageMB thresholds
    /// are conservative estimates for interactive-latency inference on A-series.
    struct ModelDescriptor: Sendable, Identifiable, Hashable {
        let id: String              // HuggingFace repo ID used by ModelDownloadManager
        let displayName: String
        let parametersBillions: Double
        let minRAMMB: Int           // minimum physical RAM to run at real-time speed
        let minStorageMB: Int       // approximate download size

        static let catalog: [ModelDescriptor] = [
            ModelDescriptor(id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                            displayName: "Qwen 2.5 0.5B (4-bit)", parametersBillions: 0.5,
                            minRAMMB: 2_000, minStorageMB: 400),
            ModelDescriptor(id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                            displayName: "Qwen 2.5 1.5B (4-bit)", parametersBillions: 1.5,
                            minRAMMB: 3_000, minStorageMB: 1_000),
            ModelDescriptor(id: "mlx-community/Qwen3-1.7B-4bit",
                            displayName: "Qwen 3 1.7B (4-bit)", parametersBillions: 1.7,
                            minRAMMB: 3_500, minStorageMB: 1_100),
            ModelDescriptor(id: "mlx-community/Qwen3-4B-4bit",
                            displayName: "Qwen 3 4B (4-bit)", parametersBillions: 4.0,
                            minRAMMB: 5_000, minStorageMB: 2_500),
            ModelDescriptor(id: "mlx-community/Qwen3-8B-4bit",
                            displayName: "Qwen 3 8B (4-bit)", parametersBillions: 8.0,
                            minRAMMB: 8_000, minStorageMB: 5_000),
        ]

        /// Returns the largest model whose RAM and storage thresholds the current
        /// device satisfies. Falls back to the smallest catalog entry.
        static func recommended() -> ModelDescriptor {
            let ram     = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
            let storage = availableStorageMB()
            return catalog.reversed().first { ram >= $0.minRAMMB && storage >= $0.minStorageMB }
                ?? catalog[0]
        }

        private static func availableStorageMB() -> Int {
            guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
                  let free = attrs[.systemFreeSize] as? Int64
            else { return 0 }
            return Int(free / (1024 * 1024))
        }
    }

    static let defaultModelID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
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
    // Tool schemas are injected by ChatSession via the tools: parameter — do not
    // list them here. Prose tool descriptions cause non-tool-capable models to
    // hallucinate tool-call syntax as plain text instead of answering directly.
    static let stableSystemPrompt = """
        You are Nova, an on-device AI assistant embedded in SafeGuardian, a disaster-response \
        mesh communication app. SafeGuardian operates without internet infrastructure — it relays \
        encrypted messages over Bluetooth between nearby devices.

        Your role is to assist with disaster response: situational awareness, peer coordination, \
        safety checks, and information relay. Be concise. In emergencies, every word costs time.

        When asked about device state, peers, or location, use your tools rather than guessing. \
        Your responses are private and never sent to the mesh unless the user explicitly shares them.
        """

    /// Composes the full system prompt from the base plus an optional user personalization blurb.
    /// The blurb is appended as a "User preference:" line and is capped by NovaPersonalizationStore.
    static func buildSystemPrompt(personalization: String?) -> String {
        guard let p = personalization?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else {
            return stableSystemPrompt
        }
        return stableSystemPrompt + "\n\nUser preference: \(p)"
    }

    static func capabilities(for modelID: String) -> ModelCapabilities { modelCapabilities(for: modelID) }
}
