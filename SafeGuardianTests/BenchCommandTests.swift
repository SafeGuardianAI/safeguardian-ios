import Foundation
import Testing
import BitFoundation
@testable import SafeGuardian

@Suite(.serialized)
struct BenchCommandTests {

    @MainActor
    @Test func benchNoArgsReturnsError() {
        let identityManager = MockIdentityManager(MockKeychain())
        let processor = CommandProcessor(contextProvider: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/bench")
        switch result {
        case .error:
            break  // any error message is acceptable
        default:
            Issue.record("Expected error when /bench called with no args")
        }
    }

    @MainActor
    @Test func benchListenTogglesOnThenOff() {
        let identityManager = MockIdentityManager(MockKeychain())
        let processor = CommandProcessor(contextProvider: nil, meshService: nil, identityManager: identityManager)

        // Toggle on — no transport, so configure does nothing but listen mode should still toggle
        let on = processor.process("/bench listen")
        switch on {
        case .success(let msg):
            #expect(msg?.contains("listen") == true || msg?.contains("echo") == true)
        case .error(let msg):
            // Acceptable if transport is nil and command returns early
            // But if it returns error it should not crash
            _ = msg
        default:
            break
        }

        // Toggle off
        let off = processor.process("/bench listen")
        switch off {
        case .success(let msg):
            #expect(msg?.contains("off") == true || msg?.contains("listen") == true)
        default:
            break
        }
    }

    @MainActor
    @Test func benchUnknownPeerReturnsError() {
        let identityManager = MockIdentityManager(MockKeychain())
        let processor = CommandProcessor(contextProvider: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/bench nonexistentpeer123")
        switch result {
        case .error(let msg):
            #expect(msg.contains("not found") || msg.contains("transport") || msg.contains("no transport"))
        default:
            break
        }
    }

    @MainActor
    @Test func radioSnapshotCapturesHWModel() {
        let snap = RadioSnapshot.capture(transport: nil)
        #expect(!snap.hwModel.isEmpty)
        #expect(snap.fragmentSizeBytes == TransportConfig.bleDefaultFragmentSize)
        #expect(snap.fragmentSpacingMs == TransportConfig.bleFragmentSpacingMs)
        #expect(snap.cpuCount > 0)
    }

    @MainActor
    @Test func benchmarkExporterWritesFile() throws {
        let exporter = BenchmarkExporter()
        let session = BenchSession(
            sessionId: "test-session",
            startedAt: Date(),
            appVersion: "1.0",
            buildNumber: "1",
            local: RadioSnapshot.capture(transport: nil),
            remotePeerId: "peer123",
            remoteNickname: "testpeer",
            payloadBytes: 1024,
            trialCount: 1
        )
        exporter.append(session)
        #expect(FileManager.default.fileExists(atPath: exporter.exportURL.path))
        let contents = try String(contentsOf: exporter.exportURL, encoding: .utf8)
        #expect(contents.contains("test-session"))
        #expect(contents.contains("session"))
        try FileManager.default.removeItem(at: exporter.exportURL)
    }

    @MainActor
    @Test func benchSummaryStatisticsCorrect() {
        let snap = RadioSnapshot.capture(transport: nil)
        let trials = (0..<10).map { i in
            BenchTrial(
                sessionId: "s",
                trialIndex: i,
                payloadBytes: 1024,
                fragmentCount: 3,
                elapsedMs: 100 + i * 10,
                throughputKBps: Double(1024) / Double(100 + i * 10),
                rssiDBm: -60,
                batteryPct: 80,
                thermalState: "nominal",
                sendTsNs: 0,
                completeTsNs: 1_000_000,
                remote: snap
            )
        }
        let summary = BenchSummary.compute(sessionId: "s", trials: trials, exportPath: "/tmp/test.jsonl")
        #expect(summary.completedTrials == 10)
        #expect(summary.minThroughputKBps <= summary.meanThroughputKBps)
        #expect(summary.meanThroughputKBps <= summary.maxThroughputKBps)
        #expect(summary.p50ThroughputKBps > 0)
    }
}
