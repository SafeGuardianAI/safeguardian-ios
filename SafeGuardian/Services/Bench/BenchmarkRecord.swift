import Foundation

/// Top-level session record written as the first line of a bench output file.
struct BenchSession: Codable {
    let type: String = "session"
    let sessionId: String
    let startedAt: Date
    let appVersion: String
    let buildNumber: String
    let local: RadioSnapshot
    let remotePeerId: String
    let remoteNickname: String
    let payloadBytes: Int
    let trialCount: Int
    /// Measured distance between devices in metres, supplied manually via dist= argument.
    let distM: Double?

    private enum CodingKeys: String, CodingKey {
        case type, sessionId, startedAt, appVersion, buildNumber
        case local, remotePeerId, remoteNickname, payloadBytes, trialCount, distM
    }
}

/// One measurement record per trial.
struct BenchTrial: Codable {
    let type: String = "trial"
    let sessionId: String
    let trialIndex: Int
    let payloadBytes: Int
    let fragmentCount: Int
    let elapsedMs: Int
    let throughputKBps: Double
    let rssiDBm: Int?
    let batteryPct: Int
    let thermalState: String
    let sendTsNs: Int64
    let completeTsNs: Int64
    let remote: RadioSnapshot?
    /// True when no PONG was received within the trial timeout window.
    let dropped: Bool

    private enum CodingKeys: String, CodingKey {
        case type, sessionId, trialIndex, payloadBytes, fragmentCount
        case elapsedMs, throughputKBps, rssiDBm, batteryPct, thermalState
        case sendTsNs, completeTsNs, remote, dropped
    }
}

/// Final summary record appended after all trials complete.
struct BenchSummary: Codable {
    let type: String = "summary"
    let sessionId: String
    let completedTrials: Int
    let droppedTrials: Int
    let deliveryRatio: Double
    let meanThroughputKBps: Double
    let p50ThroughputKBps: Double
    let p95ThroughputKBps: Double
    let minThroughputKBps: Double
    let maxThroughputKBps: Double
    let meanElapsedMs: Double
    let exportPath: String

    private enum CodingKeys: String, CodingKey {
        case type, sessionId, completedTrials, droppedTrials, deliveryRatio
        case meanThroughputKBps, p50ThroughputKBps, p95ThroughputKBps
        case minThroughputKBps, maxThroughputKBps, meanElapsedMs, exportPath
    }

    static func compute(sessionId: String, trials: [BenchTrial], exportPath: String) -> BenchSummary {
        let received = trials.filter { !$0.dropped }
        let dropped = trials.count - received.count
        let deliveryRatio = trials.isEmpty ? 1.0 : Double(received.count) / Double(trials.count)
        let throughputs = received.map(\.throughputKBps).sorted()
        let mean = throughputs.isEmpty ? 0 : throughputs.reduce(0, +) / Double(throughputs.count)
        let p50 = throughputs.isEmpty ? 0 : throughputs[throughputs.count / 2]
        let p95 = throughputs.isEmpty ? 0 : throughputs[min(Int(Double(throughputs.count) * 0.95), throughputs.count - 1)]
        let meanElapsed = received.isEmpty ? 0 : Double(received.map(\.elapsedMs).reduce(0, +)) / Double(received.count)
        return BenchSummary(
            sessionId: sessionId,
            completedTrials: received.count,
            droppedTrials: dropped,
            deliveryRatio: deliveryRatio,
            meanThroughputKBps: mean,
            p50ThroughputKBps: p50,
            p95ThroughputKBps: p95,
            minThroughputKBps: throughputs.first ?? 0,
            maxThroughputKBps: throughputs.last ?? 0,
            meanElapsedMs: meanElapsed,
            exportPath: exportPath
        )
    }
}
