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

    private enum CodingKeys: String, CodingKey {
        case type, sessionId, startedAt, appVersion, buildNumber
        case local, remotePeerId, remoteNickname, payloadBytes, trialCount
    }
}

/// One measurement record per trial.
struct BenchTrial: Codable {
    let type: String = "trial"
    let sessionId: String
    let trialIndex: Int
    let payloadBytes: Int
    let fragmentCount: Int
    /// Elapsed time from first fragment sent to XACK received (file transfer),
    /// or half-RTT for latency pings.
    let elapsedMs: Int
    let throughputKBps: Double
    let rssiDBm: Int?
    let batteryPct: Int
    let thermalState: String
    let sendTsNs: Int64
    let completeTsNs: Int64
    /// Remote metadata received in the PONG or XACK.
    let remote: RadioSnapshot?

    private enum CodingKeys: String, CodingKey {
        case type, sessionId, trialIndex, payloadBytes, fragmentCount
        case elapsedMs, throughputKBps, rssiDBm, batteryPct, thermalState
        case sendTsNs, completeTsNs, remote
    }
}

/// Final summary record appended after all trials complete.
struct BenchSummary: Codable {
    let type: String = "summary"
    let sessionId: String
    let completedTrials: Int
    let meanThroughputKBps: Double
    let p50ThroughputKBps: Double
    let p95ThroughputKBps: Double
    let minThroughputKBps: Double
    let maxThroughputKBps: Double
    let meanElapsedMs: Double
    let exportPath: String

    private enum CodingKeys: String, CodingKey {
        case type, sessionId, completedTrials
        case meanThroughputKBps, p50ThroughputKBps, p95ThroughputKBps
        case minThroughputKBps, maxThroughputKBps, meanElapsedMs, exportPath
    }

    static func compute(sessionId: String, trials: [BenchTrial], exportPath: String) -> BenchSummary {
        let throughputs = trials.map(\.throughputKBps).sorted()
        let mean = throughputs.isEmpty ? 0 : throughputs.reduce(0, +) / Double(throughputs.count)
        let p50 = throughputs.isEmpty ? 0 : throughputs[throughputs.count / 2]
        let p95 = throughputs.isEmpty ? 0 : throughputs[min(Int(Double(throughputs.count) * 0.95), throughputs.count - 1)]
        let meanElapsed = trials.isEmpty ? 0 : Double(trials.map(\.elapsedMs).reduce(0, +)) / Double(trials.count)
        return BenchSummary(
            sessionId: sessionId,
            completedTrials: trials.count,
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
