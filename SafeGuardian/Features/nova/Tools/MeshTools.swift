import BitFoundation
import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func meshTools(agentID: String) -> [AgentToolEntry] {
        [listPeersEntry(), sendAgentMessageEntry(senderAgentID: agentID), broadcastEntry(senderAgentID: agentID)]
    }

    // MARK: - List peers

    private static func listPeersEntry() -> AgentToolEntry {
        make(
            name: "list_peers",
            description: "Returns the peer IDs currently connected on the BLE mesh. Use these IDs with send_agent_message or broadcast_to_agents.",
            parameters: []
        ) { _, proxy in
            let peers = await proxy.meshPeerIDs()
            if peers.isEmpty { return #"{"peers":[]}"# }
            let list = peers.map { #""\#($0.id)""# }.joined(separator: ",")
            return #"{"peers":[\#(list)]}"#
        }
    }

    // MARK: - Targeted agent message

    private static func sendAgentMessageEntry(senderAgentID: String) -> AgentToolEntry {
        make(
            name: "send_agent_message",
            description: "Send a private message to a specific agent on a specific peer device. The message is routed to the named agent on that device and never shown in the human chat.",
            parameters: [
                .required("agent_id", type: .string, description: "Target agent identifier, e.g. 'nova' or 'trek'."),
                .required("content", type: .string, description: "The message to send."),
                .required("peer_id", type: .string, description: "The recipient device's peer ID from list_peers.")
            ]
        ) { args, proxy in
            guard case .string(let agentID) = args["agent_id"],
                  case .string(let content) = args["content"],
                  case .string(let peerIDStr) = args["peer_id"] else {
                return #"{"error":"missing required argument"}"#
            }
            let peerID = PeerID(str: peerIDStr)
            await proxy.sendMesh(toAgentID: agentID, content: content, peerID: peerID)
            return #"{"sent":true,"to":"\#(peerIDStr)","agent":"\#(agentID)"}"#
        }
    }

    // MARK: - Broadcast

    private static func broadcastEntry(senderAgentID: String) -> AgentToolEntry {
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
