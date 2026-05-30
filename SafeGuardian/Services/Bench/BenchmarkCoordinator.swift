import BitFoundation
import Foundation

// In-band bench protocol over private BLE messages.
// Prefix all bench messages so ChatViewModel can intercept and route them silently.
let benchMessagePrefix = "SGBench/1 "

/// Orchestrates latency and throughput measurements between two devices running SafeGuardian.
/// Both devices must have bench mode active (sender via /bench, receiver via /bench listen or
/// by simply having the coordinator running and watching for incoming bench messages).
@MainActor
final class BenchmarkCoordinator {
    static let shared = BenchmarkCoordinator()

    /// Override before calling `runSession` to configure a specific experiment or test.
    var config = BenchmarkConfig()

    private var transport: (any Transport)?
    private var exporter: BenchmarkExporter?
    private var activeSessions: [String: ActiveSession] = [:]
    private var listenMode = false
    private var stopRequested = false

    var isRunning: Bool { !activeSessions.isEmpty }

    /// Cancels the in-progress session after the current trial resolves.
    /// Returns false if no session is running.
    @discardableResult
    func stopSession() -> Bool {
        guard !activeSessions.isEmpty else { return false }
        stopRequested = true
        for (sid, var session) in activeSessions {
            if let cont = session.pendingContinuation {
                session.pendingContinuation = nil
                activeSessions[sid] = session
                cont.resume(throwing: BenchError.stopped)
            }
        }
        return true
    }

    private struct ActiveSession {
        let id: String
        let peerID: PeerID
        let payloadBytes: Int
        let expectedTrials: Int
        var completedTrials: [BenchTrial] = []
        var pendingContinuation: CheckedContinuation<BenchTrial, Error>?
        var pendingTrialIndex: Int = 0
        var pendingSendNs: Int64 = 0
    }

    func configure(transport: any Transport) {
        self.transport = transport
    }

    // MARK: - Incoming message routing (called from ChatViewModel)

    func receive(_ message: SafeGuardianMessage) {
        guard message.content.hasPrefix(benchMessagePrefix) else { return }
        let body = String(message.content.dropFirst(benchMessagePrefix.count))
        let parts = body.split(separator: " ", omittingEmptySubsequences: true)
        guard let verb = parts.first.map(String.init) else { return }

        switch verb {
        case "PING":
            handlePing(body: body, from: message.senderPeerID)
        case "PONG":
            handlePong(body: body)
        case "XACK":
            handleXack(body: body)
        default:
            break
        }
    }

    // MARK: - Sender: run a bench session

    func runSession(
        peer: PeerID,
        peerNickname: String,
        payloadBytes: Int,
        trials: Int,
        distM: Double? = nil,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> BenchSummary {
        guard let transport else { throw BenchError.notConfigured }

        let sessionId = UUID().uuidString
        let exp = BenchmarkExporter(peerNickname: peerNickname, payloadBytes: payloadBytes, trials: trials, distM: distM, config: config)
        exporter = exp

        let localSnap = RadioSnapshot.capture(transport: transport, forPeer: peer)
        let session = BenchSession(
            sessionId: sessionId,
            startedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            local: localSnap,
            remotePeerId: peer.bare,
            remoteNickname: peerNickname,
            payloadBytes: payloadBytes,
            trialCount: trials,
            distM: distM
        )
        exp.append(session)
        let distLabel = distM.map { " @ \(Int($0))m" } ?? ""
        await progress("bench \(sessionId.prefix(8)) → \(peerNickname)\(distLabel), \(payloadBytes / 1024) KB × \(trials) trials")

        activeSessions[sessionId] = ActiveSession(id: sessionId, peerID: peer, payloadBytes: payloadBytes, expectedTrials: trials)
        stopRequested = false

        let fragmentSize = TransportConfig.bleDefaultFragmentSize
        let fragmentCount = max(1, (payloadBytes + fragmentSize - 1) / fragmentSize)
        let payload = Data(repeating: 0xBE, count: payloadBytes)
        let packet = SafeGuardianFilePacket(content: payload)
        let trialTimeoutNs = UInt64(config.trialTimeoutSeconds * 1_000_000_000)

        for i in 0..<trials {
            if stopRequested { break }
            await progress("trial \(i + 1)/\(trials)…")
            let sendNs = Int64(DispatchTime.now().uptimeNanoseconds)
            activeSessions[sessionId]?.pendingTrialIndex = i
            activeSessions[sessionId]?.pendingSendNs = sendNs

            // Race the PONG continuation against a 5-second timeout.
            // A timeout counts as a dropped trial.
            let timeoutTask = Task { @MainActor [weak self] in
                try await Task.sleep(nanoseconds: trialTimeoutNs)
                guard let self, let cont = self.activeSessions[sessionId]?.pendingContinuation else { return }
                self.activeSessions[sessionId]?.pendingContinuation = nil
                cont.resume(throwing: BenchError.timeout)
            }

            var trial: BenchTrial
            do {
                trial = try await withCheckedThrowingContinuation { continuation in
                    activeSessions[sessionId]?.pendingContinuation = continuation
                    transport.sendFilePrivate(packet, to: peer, transferId: UUID().uuidString)
                    sendBenchMessage("PING sid=\(sessionId) t=\(sendNs) idx=\(i)", to: peer)
                }
                timeoutTask.cancel()
            } catch BenchError.stopped {
                timeoutTask.cancel()
                break
            } catch {
                // Timeout — record as a dropped trial.
                let nowNs = Int64(DispatchTime.now().uptimeNanoseconds)
                let snap = RadioSnapshot.capture(transport: transport, forPeer: peer)
                trial = BenchTrial(
                    sessionId: sessionId, trialIndex: i,
                    payloadBytes: payloadBytes, fragmentCount: fragmentCount,
                    elapsedMs: Int(trialTimeoutNs / 1_000_000),
                    throughputKBps: 0,
                    rssiDBm: snap.rssiDBm, batteryPct: snap.batteryPct, thermalState: snap.thermalState,
                    sendTsNs: sendNs, completeTsNs: nowNs,
                    remote: nil, dropped: true
                )
            }

            activeSessions[sessionId]?.completedTrials.append(trial)
            exp.append(trial)
            if trial.dropped {
                await progress("  → dropped")
            } else {
                await progress("  → \(String(format: "%.1f", trial.throughputKBps)) KB/s, \(trial.elapsedMs) ms")
            }
        }

        let completedTrials = activeSessions[sessionId]?.completedTrials ?? []
        activeSessions.removeValue(forKey: sessionId)

        let summary = BenchSummary.compute(sessionId: sessionId, trials: completedTrials, exportPath: exp.exportURL.path)
        exp.append(summary)
        return summary
    }

    // MARK: - Listen mode (receiver echoes)

    func enterListenMode() {
        listenMode = true
    }

    func exitListenMode() {
        listenMode = false
    }

    var isListening: Bool { listenMode }

    // MARK: - Private: send bench protocol messages

    private func sendBenchMessage(_ body: String, to peer: PeerID) {
        guard let transport else { return }
        let content = benchMessagePrefix + body
        transport.sendPrivateMessage(content, to: peer, recipientNickname: "", messageID: UUID().uuidString)
    }

    // MARK: - Private: handle incoming protocol messages

    private func handlePing(body: String, from senderPeerID: PeerID?) {
        guard let transport, let senderPeerID else { return }
        let params = parseParams(body)
        guard let sid = params["sid"], let sendNs = params["t"].flatMap(Int64.init), let idx = params["idx"] else { return }
        let recvNs = Int64(DispatchTime.now().uptimeNanoseconds)
        let snap = RadioSnapshot.capture(transport: transport, forPeer: senderPeerID)
        let reply = "PONG sid=\(sid) t=\(sendNs) rt=\(recvNs) idx=\(idx) hw=\(snap.hwModel.replacingOccurrences(of: " ", with: "_")) os=\(snap.osVersion.replacingOccurrences(of: " ", with: "_")) mtu=\(snap.negotiatedMTU) rssi=\(snap.rssiDBm.map(String.init) ?? "nil") batt=\(snap.batteryPct) therm=\(snap.thermalState)"
        sendBenchMessage(reply, to: senderPeerID)
    }

    private func handlePong(body: String) {
        let params = parseParams(body)
        guard
            let sid = params["sid"],
            let sendNs = params["t"].flatMap(Int64.init),
            let recvNs = params["rt"].flatMap(Int64.init),
            let idx = params["idx"].flatMap(Int.init),
            var session = activeSessions[sid]
        else { return }

        let completeTsNs = Int64(DispatchTime.now().uptimeNanoseconds)
        let elapsedMs = max(1, Int((completeTsNs - sendNs) / 1_000_000))
        let remoteSnap = remoteSnapshot(from: params)
        let snap = RadioSnapshot.capture(transport: transport, forPeer: session.peerID)
        let fragmentCount = max(1, (session.payloadBytes + TransportConfig.bleDefaultFragmentSize - 1) / TransportConfig.bleDefaultFragmentSize)
        let trial = BenchTrial(
            sessionId: sid,
            trialIndex: idx,
            payloadBytes: session.payloadBytes,
            fragmentCount: fragmentCount,
            elapsedMs: elapsedMs,
            throughputKBps: Double(session.payloadBytes) / Double(elapsedMs),
            rssiDBm: snap.rssiDBm,
            batteryPct: snap.batteryPct,
            thermalState: snap.thermalState,
            sendTsNs: sendNs,
            completeTsNs: completeTsNs,
            remote: remoteSnap,
            dropped: false
        )
        let continuation = session.pendingContinuation
        session.pendingContinuation = nil
        activeSessions[sid] = session
        _ = recvNs  // captured for potential one-way latency analysis offline
        continuation?.resume(returning: trial)
    }

    private func handleXack(body: String) {
        let params = parseParams(body)
        guard
            let sid = params["sid"],
            let idx = params["idx"].flatMap(Int.init),
            var session = activeSessions[sid]
        else { return }

        let completeTsNs = Int64(DispatchTime.now().uptimeNanoseconds)
        let sendNs = session.pendingSendNs
        let elapsedMs = max(1, Int((completeTsNs - sendNs) / 1_000_000))
        let remoteSnap = remoteSnapshot(from: params)
        let snap = RadioSnapshot.capture(transport: transport, forPeer: session.peerID)
        let fragCount = params["frags"].flatMap(Int.init) ?? max(1, (session.payloadBytes + TransportConfig.bleDefaultFragmentSize - 1) / TransportConfig.bleDefaultFragmentSize)
        let trial = BenchTrial(
            sessionId: sid,
            trialIndex: idx,
            payloadBytes: session.payloadBytes,
            fragmentCount: fragCount,
            elapsedMs: elapsedMs,
            throughputKBps: Double(session.payloadBytes) / Double(elapsedMs),
            rssiDBm: snap.rssiDBm,
            batteryPct: snap.batteryPct,
            thermalState: snap.thermalState,
            sendTsNs: sendNs,
            completeTsNs: completeTsNs,
            remote: remoteSnap,
            dropped: false
        )
        let continuation = session.pendingContinuation
        session.pendingContinuation = nil
        activeSessions[sid] = session
        continuation?.resume(returning: trial)
    }

    private func remoteSnapshot(from params: [String: String]) -> RadioSnapshot? {
        guard let hw = params["hw"], let os = params["os"], let mtu = params["mtu"].flatMap(Int.init) else { return nil }
        return RadioSnapshot(
            hwModel: hw.replacingOccurrences(of: "_", with: " "),
            osVersion: os.replacingOccurrences(of: "_", with: " "),
            physicalMemoryGB: 0,
            cpuCount: 0,
            batteryPct: params["batt"].flatMap(Int.init) ?? -1,
            thermalState: params["therm"] ?? "unknown",
            appState: "unknown",
            negotiatedMTU: mtu,
            fragmentSizeBytes: TransportConfig.bleDefaultFragmentSize,
            fragmentSpacingMs: TransportConfig.bleFragmentSpacingMs,
            rssiDBm: params["rssi"].flatMap(Int.init),
            connectedPeerCount: 0
        )
    }

    private func parseParams(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for token in body.split(separator: " ").dropFirst() {
            let kv = token.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { result[String(kv[0])] = String(kv[1]) }
        }
        return result
    }
}

enum BenchError: Error {
    case notConfigured
    case timeout
    case stopped
}
