import Foundation

/// All tunable parameters for a benchmark run. Assign a custom value to
/// `BenchmarkCoordinator.config` before calling `runSession` to configure
/// an experiment or test without touching production defaults.
struct BenchmarkConfig {
    /// Default payload size used by `/bench` when `kb=` is not specified.
    var defaultPayloadKB: Int = 10

    /// Default trial count used by `/bench` when `trials=` is not specified.
    var defaultTrialCount: Int = 100

    /// Maximum time to wait for a PONG before counting a trial as dropped.
    var trialTimeoutSeconds: Double = 5

    /// Constructs the metadata slug embedded in the export filename.
    /// Parameters: (peerNickname, payloadBytes, trials, distM)
    var makeFilenameSlug: (String, Int, Int, Double?) -> String = { peer, bytes, trials, dist in
        let safe = peer
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let distPart = dist.map { "_\(Int($0))m" } ?? ""
        return "\(safe)\(distPart)_\(bytes / 1024)KB_\(trials)t"
    }
}
