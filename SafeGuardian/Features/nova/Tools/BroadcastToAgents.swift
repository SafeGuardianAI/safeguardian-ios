import BitFoundation
import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func broadcastToAgents(senderAgentID: String) -> AgentToolEntry {
        make(
            name: "broadcast_to_agents",
            description: "Send a message to a named agent on all currently connected peer devices.",
            parameters: [
                .required("agent_id", type: .string, description: "Target agent identifier on each peer, e.g. 'nova'."),
                .required("content", type: .string, description: "The message to broadcast.")
            ]
        ) { args, proxy in
            guard case .string(let agentID) = args["agent_id"],
                  case .string(let content) = args["content"] else {
                return #"{"error":"missing required argument"}"#
            }
            let peers = await proxy.meshPeerIDs()
            for peerID in peers {
                await proxy.sendMesh(toAgentID: agentID, content: content, peerID: peerID)
            }
            return #"{"sent":true,"peer_count":\#(peers.count),"agent":"\#(agentID)"}"#
        }
    }
}
