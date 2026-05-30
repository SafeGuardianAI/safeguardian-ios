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
    let usage = "/bench <peer|listen|stop> [kb=10] [trials=100] [dist=<metres>]"

    func execute(args: String, context: CommandContext) -> CommandResult {
        guard let transport = context.transport else {
            return .error(message: "bench: no transport available")
        }
        BenchmarkCoordinator.shared.configure(transport: transport)

        let tokens = args.split(separator: " ").map(String.init)

        if tokens.first == "stop" {
            if BenchmarkCoordinator.shared.stopSession() {
                return .success(message: "bench: stopping after current trial…")
            } else {
                return .error(message: "bench: no session running")
            }
        }

        if tokens.first == "listen" {
            if BenchmarkCoordinator.shared.isListening {
                BenchmarkCoordinator.shared.exitListenMode()
                return .success(message: "bench: listen mode off")
            } else {
                BenchmarkCoordinator.shared.enterListenMode()
                return .success(message: "bench: listening — echo mode active, incoming bench pings will be answered")
            }
        }

        // Resolve peer: explicit nickname arg, or fall back to the currently open DM.
        let isParam = { (s: String) in s.hasPrefix("kb=") || s.hasPrefix("trials=") || s.hasPrefix("dist=") }
        let explicitPeer: String? = tokens.first.flatMap { isParam($0) ? nil : $0 }
        let paramTokens = explicitPeer == nil ? tokens : Array(tokens.dropFirst())

        let cfg = BenchmarkCoordinator.shared.config
        var payloadKB = cfg.defaultPayloadKB
        var trialCount = cfg.defaultTrialCount
        var distM: Double? = nil
        for token in paramTokens {
            if token.hasPrefix("kb="), let v = Int(token.dropFirst(3)) { payloadKB = max(1, v) }
            if token.hasPrefix("trials="), let v = Int(token.dropFirst(7)) { trialCount = max(1, min(1000, v)) }
            if token.hasPrefix("dist="), let v = Double(token.dropFirst(5)) { distM = v }
        }
        let payloadBytes = payloadKB * 1024

        let peerID: PeerID
        let peerNickname: String
        if let name = explicitPeer {
            guard let id = context.provider?.getPeerIDForNickname(name) else {
                return .error(message: "bench: '\(name)' not found — check /who")
            }
            peerID = id
            peerNickname = name
        } else if let current = context.provider?.selectedPrivateChatPeer,
                  let name = context.transport?.peerNickname(peerID: current) {
            peerID = current
            peerNickname = name
        } else {
            return .error(message: "bench: open a DM first, or specify a peer name")
        }

        let addMessage = { [weak provider = context.provider] (msg: String) in
            provider?.addLocalMessage(msg)
        }

        Task { @MainActor in
            do {
                let summary = try await BenchmarkCoordinator.shared.runSession(
                    peer: peerID,
                    peerNickname: peerNickname,
                    payloadBytes: payloadBytes,
                    trials: trialCount,
                    distM: distM,
                    progress: { msg in addMessage(msg) }
                )
                addMessage("bench complete: mean \(String(format: "%.1f", summary.meanThroughputKBps)) KB/s  p50 \(String(format: "%.1f", summary.p50ThroughputKBps))  p95 \(String(format: "%.1f", summary.p95ThroughputKBps))  min \(String(format: "%.1f", summary.minThroughputKBps))  max \(String(format: "%.1f", summary.maxThroughputKBps))")
                addMessage("bench export: \(summary.exportPath)")
            } catch BenchError.stopped {
                addMessage("bench stopped")
            } catch {
                addMessage("bench error: \(error)")
            }
        }

        return .handled
    }
}
