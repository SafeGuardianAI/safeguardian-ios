import Testing
import Foundation
@testable import SafeGuardian

// MARK: - AgentMeshRouting

@Suite("AgentMeshRouting")
struct AgentMeshRoutingTests {
    @Test func roundTrip() {
        let formatted = AgentMeshRouting.format(agentID: "nova", content: "hello world")
        let parsed = AgentMeshRouting.parse(formatted)
        #expect(parsed?.agentID == "nova")
        #expect(parsed?.content == "hello world")
    }

    @Test func parseValidMessage() {
        let parsed = AgentMeshRouting.parse("[AGENT:trek] what is the LZ status?")
        #expect(parsed?.agentID == "trek")
        #expect(parsed?.content == "what is the LZ status?")
    }

    @Test func parseRejectsNonAgentMessage() {
        #expect(AgentMeshRouting.parse("hello there") == nil)
        #expect(AgentMeshRouting.parse("[FAVORITED]") == nil)
        #expect(AgentMeshRouting.parse("[AGENT:]") == nil) // empty agent ID
        #expect(AgentMeshRouting.parse("[AGENT:nova]no space") == nil) // missing space after bracket
    }

    @Test func formatPreservesContent() {
        let content = "structural report: sector 4 has 3 voids"
        let msg = AgentMeshRouting.format(agentID: "nova", content: content)
        #expect(msg == "[AGENT:nova] \(content)")
    }
}

// MARK: - DeviceMetrics

@Suite("DeviceMetrics")
struct DeviceMetricsTests {
    @Test func storageIsPositive() {
        #expect(DeviceMetrics.availableStorageBytes() > 0)
        #expect(DeviceMetrics.totalStorageBytes() > 0)
    }

    @Test func availableDoesNotExceedTotal() {
        #expect(DeviceMetrics.availableStorageBytes() <= DeviceMetrics.totalStorageBytes())
        #expect(DeviceMetrics.availableMemoryBytes() <= DeviceMetrics.totalMemoryBytes())
    }

    @Test func memoryIsPositive() {
        #expect(DeviceMetrics.availableMemoryBytes() > 0)
        #expect(DeviceMetrics.totalMemoryBytes() > 0)
    }
}

// MARK: - ModelDownloadManager

@Suite("ModelDownloadManager")
@MainActor
struct ModelDownloadManagerTests {
    @Test func estimatedSizePatterns() {
        let mgr = ModelDownloadManager.shared
        #expect(mgr.estimatedDownloadSize(modelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit") == 350_000_000)
        #expect(mgr.estimatedDownloadSize(modelID: "mlx-community/Qwen2.5-3B-Instruct-4bit") == 1_900_000_000)
        #expect(mgr.estimatedDownloadSize(modelID: "mlx-community/Llama-3-8B-4bit") == 5_000_000_000)
    }

    @Test func hasStorageReturnsBool() {
        // Just verify it runs without crashing — actual result depends on device state.
        _ = ModelDownloadManager.shared.hasStorageForDownload(modelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    }

    @Test func cachedModelIDsReturnsList() {
        let ids = ModelDownloadManager.shared.cachedModelIDs()
        // May be empty in CI — just verify no crash and all IDs look like "org/model"
        for id in ids {
            #expect(id.contains("/"))
        }
    }
}

// MARK: - NovaStateTick.toolJSON

@Suite("NovaStateTick toolJSON")
struct NovaStateTickToolJSONTests {
    @Test func toolJSONIsValidJSON() throws {
        let tick = NovaStateTick(
            lat: 30.123, lon: -90.456,
            locationConfidence: 0.85,
            locationSource: .gps,
            medicalStatus: .unknown,
            structuralObservations: [],
            batteryPct: 0.72,
            transportTier: .ble_coded,
            peerCount: 4,
            tickSequence: 1,
            confidenceAtEmit: 0.85
        )
        let json = tick.toolJSON
        let data = try #require(json.data(using: .utf8))
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["battery_pct"] as? Int == 72)
        #expect(obj["peer_count"] as? Int == 4)
        #expect(obj["transport_tier"] as? String == "ble_coded")
        #expect((obj["location_confidence"] as? Double ?? 0) > 0)
    }
}

// MARK: - AgentToolEntry registry

@Suite("AgentToolRegistry")
@MainActor
struct AgentToolRegistryTests {
    @Test func specJSONIsValidJSONArray() throws {
        // specJSON needs a context — use a lightweight mock approach by checking
        // that the individual tool entries produce valid schemas.
        let tools: [AgentToolEntry] = [
            .getStorage(), .getMemory(), .getDeviceState(),
            .getStatus(), .getFullStatus(), .listPeers()
        ]
        #expect(tools.count == 6)
        for tool in tools {
            #expect(!tool.name.isEmpty)
            // spec is a [String: any Sendable] — verify it has the required "type" key
            #expect(tool.spec["type"] as? String == "function")
        }
    }

    @Test func toolNamesAreUnique() {
        let tools: [AgentToolEntry] = [
            .getStorage(), .getMemory(), .getDeviceState(),
            .getStatus(), .getFullStatus(), .listPeers(),
            .sendAgentMessage(senderAgentID: "nova"),
            .broadcastToAgents(senderAgentID: "nova")
        ]
        let names = tools.map { $0.name }
        #expect(Set(names).count == names.count)
    }
}
