import SafeGuardianMesh
import BitFoundation
import Foundation
import AgentRuntime

extension AgentToolRegistry {
    /// Builds the standard tool registry for a given agent and context.
    /// This is the canonical list of all registered tools. Adding a new tool:
    /// 1. Create a new file in Tools/ with an AgentToolEntry extension
    /// 2. Add it to the appropriate list below — nothing else changes.
    @MainActor
    static func standard(
        agentID: String,
        context: some AgentContext,
        peerID: PeerID,
        onStatus: StatusCallback? = nil
    ) -> AgentToolRegistry {
        let record = AgentTaskRecord()
        let toolSettings = ToolSettingsStore.shared
        // task_complete is the model's own stop-signal mechanism, not a
        // user-facing capability, so it is always included regardless of
        // ToolSettingsStore state.
        let deviceTools: [AgentToolEntry] = [.taskComplete(record: record)] + [
            AgentToolEntry.getDeviceState(),
            .getFullStatus(),
            .getStorage(),
            .getMemory(),
            .getMeshLoad(),
            .setTickInterval(),
            .setMessageTTL()
        ].filter { toolSettings.isEnabled($0.name) }
        let meshTools: [AgentToolEntry] = [
            .listPeers(),
            .sendAgentMessage(senderAgentID: agentID),
            .broadcastToAgents(senderAgentID: agentID),
            .requestPeerLocation(),
            .requestMeshTopology(senderAgentID: agentID),
            .claimIncident(senderAgentID: agentID),
            .releaseIncident(senderAgentID: agentID),
            .floodAlert(senderAgentID: agentID),
            .publishStateTick(),
            .openPeerSession(agentID: agentID),
            .peerSessionRequest(),
            .closePeerSession(),
            .sdrScan(),
            .sdrTune(),
            .sdrMonitor(),
            .sdrCancel()
        ].filter { toolSettings.isEnabled($0.name) }
        return build(
            agentID: agentID,
            context: context,
            peerID: peerID,
            deviceTools: deviceTools,
            meshTools: meshTools,
            onStatus: onStatus,
            taskRecord: record
        )
    }

    /// All tool specs in OpenAI function-calling JSON format.
    /// Used for logging, training data generation, and documentation.
    @MainActor
    static func specJSON(agentID: String, context: some AgentContext) -> String {
        let registry = standard(agentID: agentID, context: context, peerID: PeerID(str: "nova-local"))
        guard let data = try? JSONSerialization.data(
            withJSONObject: registry.specs.map { $0 as Any },
            options: [.prettyPrinted, .sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
