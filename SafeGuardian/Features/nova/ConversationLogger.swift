#if DEBUG
import BitFoundation
import Foundation

/// Appends one JSONL entry per completed Nova exchange to a file in Application Support.
/// Each entry contains the full multi-turn context from the Nova private thread so it can
/// be used directly for SFT or annotated externally for DPO.
///
/// Format: OpenAI chat messages (system/user/assistant roles), one JSON object per line.
/// Gate: DEBUG builds only. This file does not compile into Release.
@MainActor
final class ConversationLogger {
    static let shared = ConversationLogger()

    private let fileURL: URL
    private static let iso8601 = ISO8601DateFormatter()

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat.safeguardian", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("nova-training.jsonl")
    }

    var logFilePath: String { fileURL.path }

    func record(
        novaThread: [SafeGuardianMessage],
        systemPrompt: String,
        providerID: String,
        tick: NovaStateTick?,
        startedAt: Date
    ) {
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]

        for msg in novaThread {
            // Skip injected status/local messages.
            guard msg.sender != "local", msg.sender != "system" else { continue }
            // Skip agent status strings like "[thinking...]", "[error: ...]".
            let text = msg.content.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("[") else { continue }
            let role = (msg.sender == "Nova" || msg.sender == "nova-local") ? "assistant" : "user"
            messages.append(["role": role, "content": text])
        }

        // Require at least one user turn and one assistant turn.
        let turns = messages.filter { $0["role"] != "system" }
        guard turns.count >= 2 else { return }

        var metadata: [String: Any] = ["duration_ms": durationMs]
        if let tick {
            metadata["battery_pct"] = tick.batteryPct
            metadata["peer_count"] = tick.peerCount
        }

        let entry: [String: Any] = [
            "id": UUID().uuidString,
            "timestamp": Self.iso8601.string(from: Date()),
            "provider": providerID,
            "messages": messages,
            "metadata": metadata
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let json = String(data: data, encoding: .utf8) else { return }
        let lineData = Data((json + "\n").utf8)

        if let handle = FileHandle(forWritingAtPath: fileURL.path) {
            handle.seekToEndOfFile()
            handle.write(lineData)
            try? handle.close()
        } else {
            try? lineData.write(to: fileURL)
        }
    }
}
#endif
