import BitFoundation
import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func sendAgentMessage(senderAgentID: String) -> AgentToolEntry {
        make(
            name: "send_agent_message",
            description: "Send a private message to a specific agent on a specific peer device. The message is routed to that agent and never shown in the human chat.",
            parameters: [
                .required("agent_id", type: .string, description: "Target agent identifier, e.g. 'nova' or 'trek'."),
                .required("content", type: .string, description: "The message to send."),
                .required("peer_id", type: .string, description: "Recipient device peer ID from list_peers.")
            ]
        ) { args, proxy in
            guard case .string(let agentID) = args["agent_id"],
                  case .string(let content) = args["content"],
                  case .string(let peerIDStr) = args["peer_id"] else {
                return #"{"error":"missing required argument"}"#
            }
            let response = await proxy.requestFromAgent(
                agentID: agentID, content: content, peerID: PeerID(str: peerIDStr)
            )
            return #"{"response":"\#(response)","from":"\#(peerIDStr)","agent":"\#(agentID)"}"#
        }
    }
}
