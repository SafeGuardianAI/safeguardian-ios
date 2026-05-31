import Foundation
import MLXLMCommon

extension AgentToolRegistry {
    /// Builds the standard tool registry for a given agent and context.
    /// This is the canonical list of all registered tools. Adding a new tool:
    /// 1. Create a new file in Tools/ with an AgentToolEntry extension
    /// 2. Add it to the appropriate list below — nothing else changes.
    @MainActor
    static func standard(
        agentID: String,
        context: some AgentContext,
        onStatus: StatusCallback? = nil,
        approvalCheck: (@Sendable (String) -> Bool)? = nil
    ) -> AgentToolRegistry {
        build(
            agentID: agentID,
            context: context,
            deviceTools: [
                .getStorage(),
                .getMemory(),
                .getDeviceState(),
                .getStatus(),
                .getFullStatus(),
                .getMeshLoad(),
                .setTickInterval(),
                .setMessageTTL()
            ],
            meshTools: [
                .listPeers(),
                .sendAgentMessage(senderAgentID: agentID),
                .broadcastToAgents(senderAgentID: agentID),
                .requestPeerLocation()
            ],
            onStatus: onStatus,
            approvalCheck: approvalCheck
        )
    }

    /// All tool specs in OpenAI function-calling JSON format.
    /// Used for logging, training data generation, and documentation.
    @MainActor
    static func specJSON(agentID: String, context: some AgentContext) -> String {
        let registry = standard(agentID: agentID, context: context)
        guard let data = try? JSONSerialization.data(
            withJSONObject: registry.specs.map { $0 as Any },
            options: [.prettyPrinted, .sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
