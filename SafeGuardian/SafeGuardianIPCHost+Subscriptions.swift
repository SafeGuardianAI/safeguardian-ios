#if os(macOS)
import Combine
import Foundation
import Tor

extension SafeGuardianIPCHost {

    // MARK: - Subscriptions

    /// Observe $messages directly so every appended message is emitted, not just .last.
    /// Uses a flag-based warm start to index history without printing it.
    func setupSubscriptions(for fd: Int32, connectionTime: Date) {
        guard let vm = chatViewModel else { return }
        clientCancellables[fd] = Set<AnyCancellable>()

        var knownIDs = Set<String>()
        var lastContent: [String: String] = [:]
        var warmedUp = false

        TorManager.shared.$isReady
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReady in
                self?.sendToClient(fd, "-- tor: \(isReady ? "ready" : "connecting") --\n")
            }
            .store(in: &clientCancellables[fd, default: Set()])

        vm.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                guard let self, self.activeClients[fd] != nil else { return }

                if !warmedUp {
                    warmedUp = true
                    for msg in messages {
                        knownIDs.insert(msg.id)
                        lastContent[msg.id] = msg.content
                    }
                    self.log("warm start: \(knownIDs.count) messages indexed")
                    return
                }

                for msg in messages {
                    guard msg.timestamp >= connectionTime else { continue }
                    let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    if !knownIDs.contains(msg.id) {
                        knownIDs.insert(msg.id)
                        lastContent[msg.id] = text
                        self.sendToClient(fd, Self.format(msg) + "\n")
                    } else if let prev = lastContent[msg.id], prev != text {
                        lastContent[msg.id] = text
                        // In-place overwrite for streaming responses (Nova tokens)
                        self.sendToClient(fd, "\r" + Self.format(msg))
                    }
                }
            }
            .store(in: &clientCancellables[fd, default: Set()])
    }

    // MARK: - Formatting

    /// Formats a message the same way the app displays it:
    /// - system/local messages show only the content (no sender label)
    /// - user messages show "nickname: content"
    /// Prefixed with [HH:MM] timestamp.
    static func format(_ msg: SafeGuardianMessage) -> String {
        let t = timeFormatter.string(from: msg.timestamp)
        let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch msg.sender {
        case "system": return "[\(t)] \(text)"
        case "local":  return "[\(t)] > \(text)"
        default:       return "[\(t)] \(msg.sender): \(text)"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
#endif
