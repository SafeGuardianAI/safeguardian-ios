#if DEBUG
import BitFoundation
import Foundation

/// Output format for logged conversations.
enum LogFormat: String {
    /// OpenAI chat messages format — compatible with axolotl, LLaMA-Factory, unsloth, etc.
    case openai = "jsonl"
    /// ShareGPT format — "from"/"value" pairs, compatible with FastChat and most fine-tuning repos.
    case sharegpt
}

/// Appends one JSONL entry per completed agent exchange to:
///   <AppSupport>/chat.safeguardian/dev/conversations.jsonl
///
/// Each entry contains the full multi-turn thread so it is usable for SFT directly
/// or annotated externally for DPO. Format is configurable via /log.
///
/// Gate: #if DEBUG — this type does not exist in Release builds.
@MainActor
final class ConversationLogger {
    static let shared = ConversationLogger()

    private static let formatKey = "dev.conversationLogger.format"
    private static let iso8601 = ISO8601DateFormatter()

    private let devDir: URL
    private let fileURL: URL

    var format: LogFormat {
        get {
            LogFormat(rawValue: UserDefaults.standard.string(forKey: Self.formatKey) ?? "") ?? .openai
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.formatKey)
        }
    }

    var logDirPath: String { devDir.path }
    var logFilePath: String { fileURL.path }

    var entryCount: Int {
        guard let data = try? Data(contentsOf: fileURL) else { return 0 }
        return data.filter { $0 == 10 }.count // count newlines
    }

    var fileSizeString: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int else { return "0 B" }
        switch size {
        case ..<1_024:              return "\(size) B"
        case ..<1_048_576:         return String(format: "%.1f KB", Double(size) / 1_024)
        default:                   return String(format: "%.1f MB", Double(size) / 1_048_576)
        }
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        devDir = appSupport
            .appendingPathComponent("chat.safeguardian", isDirectory: true)
            .appendingPathComponent("dev", isDirectory: true)
        try? FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)
        fileURL = devDir.appendingPathComponent("conversations.jsonl")
    }

    func clear() {
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func record(
        agentThread: [SafeGuardianMessage],
        systemPrompt: String,
        agentSenderID: String,
        providerID: String,
        tick: NovaStateTick?,
        startedAt: Date,
        thinkingContent: String? = nil,
        stats: AgentGenerationStats? = nil
    ) {
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        // Build the turn sequence from the thread, filtering status noise.
        var turns: [(role: String, content: String)] = []
        for msg in agentThread {
            guard msg.sender != "local", msg.sender != "system" else { continue }
            let text = msg.content.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("[") else { continue }
            let role = (msg.sender == agentSenderID || msg.sender == "Nova") ? "assistant" : "user"
            turns.append((role, text))
        }
        guard turns.contains(where: { $0.role == "user" }),
              turns.contains(where: { $0.role == "assistant" }) else { return }

        var metadata: [String: Any] = ["duration_ms": durationMs, "provider": providerID]
        if let tick {
            metadata["battery_pct"] = tick.batteryPct
            metadata["peer_count"] = tick.peerCount
        }
        if let stats {
            metadata["prompt_tokens"] = stats.promptTokens
            metadata["generation_tokens"] = stats.generationTokens
            metadata["prompt_ms"] = Int(stats.promptMs)
            metadata["generate_ms"] = Int(stats.generateMs)
            metadata["tokens_per_sec"] = (stats.tokensPerSecond * 10).rounded() / 10
            metadata["prompt_tokens_per_sec"] = (stats.promptTokensPerSecond * 10).rounded() / 10
        }

        var entry: [String: Any]
        switch format {
        case .openai:
            var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
            messages += turns.map { ["role": $0.role, "content": $0.content] }
            entry = ["id": UUID().uuidString, "timestamp": Self.iso8601.string(from: Date()),
                     "messages": messages, "metadata": metadata]
        case .sharegpt:
            let conversations = turns.map { ["from": $0.role == "assistant" ? "gpt" : "human",
                                             "value": $0.content] }
            entry = ["id": UUID().uuidString, "timestamp": Self.iso8601.string(from: Date()),
                     "system": systemPrompt, "conversations": conversations, "metadata": metadata]
        }
        if let thinkingContent { entry["thinking"] = thinkingContent }

        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let json = String(data: data, encoding: .utf8) else { return }
        let lineData = Data((json + "\n").utf8)

        if let handle = FileHandle(forWritingAtPath: fileURL.path) {
            handle.seekToEndOfFile(); handle.write(lineData); try? handle.close()
        } else {
            try? lineData.write(to: fileURL)
        }
    }
}
#endif
