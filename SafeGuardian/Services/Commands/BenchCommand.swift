import BitFoundation
import Foundation

/// Runs BLE throughput and latency benchmarks between two peers and exports
/// the results as JSON lines to the app's Documents directory.
///
/// Usage:
///   /bench <peer>             — 100 trials × 10 KB, prints summary
///   /bench <peer> kb=50       — override payload size
///   /bench <peer> trials=20   — override trial count
///   /bench listen             — put this device in passive echo mode
@MainActor
struct BenchCommand: Command {
    let names = ["/bench"]
    let usage = "/bench <peer|listen> [kb=10] [trials=100]"

    func execute(args: String, context: CommandContext) -> CommandResult {
        guard let transport = context.transport else {
            return .error(message: "bench: no transport available")
        }
        BenchmarkCoordinator.shared.configure(transport: transport)

        let tokens = args.split(separator: " ").map(String.init)

        if tokens.first == "listen" {
            if BenchmarkCoordinator.shared.isListening {
                BenchmarkCoordinator.shared.exitListenMode()
                return .success(message: "bench: listen mode off")
            } else {
                BenchmarkCoordinator.shared.enterListenMode()
                return .success(message: "bench: listening — echo mode active, incoming bench pings will be answered")
            }
        }

        guard let peerToken = tokens.first else {
            return .error(message: usage)
        }

        var payloadKB = 10
        var trialCount = 100
        for token in tokens.dropFirst() {
            if token.hasPrefix("kb="), let v = Int(token.dropFirst(3)) { payloadKB = max(1, v) }
            if token.hasPrefix("trials="), let v = Int(token.dropFirst(7)) { trialCount = max(1, min(1000, v)) }
        }
        let payloadBytes = payloadKB * 1024

        guard let peerID = context.provider?.getPeerIDForNickname(peerToken) else {
            return .error(message: "bench: peer '\(peerToken)' not found — check /who for connected peers")
        }

        let addMessage = { [weak provider = context.provider] (msg: String) in
            provider?.addLocalMessage(msg)
        }

        Task { @MainActor in
            do {
                let summary = try await BenchmarkCoordinator.shared.runSession(
                    peer: peerID,
                    peerNickname: peerToken,
                    payloadBytes: payloadBytes,
                    trials: trialCount,
                    progress: { msg in addMessage(msg) }
                )
                addMessage("bench complete: mean \(String(format: "%.1f", summary.meanThroughputKBps)) KB/s  p50 \(String(format: "%.1f", summary.p50ThroughputKBps))  p95 \(String(format: "%.1f", summary.p95ThroughputKBps))  min \(String(format: "%.1f", summary.minThroughputKBps))  max \(String(format: "%.1f", summary.maxThroughputKBps))")
                addMessage("bench export: \(summary.exportPath)")
            } catch {
                addMessage("bench error: \(error)")
            }
        }

        return .handled
    }
}
