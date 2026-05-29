import BitFoundation
import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func listPeers() -> AgentToolEntry {
        make(
            name: "list_peers",
            description: "Returns peer IDs currently connected on the BLE mesh. Use these IDs with send_agent_message or broadcast_to_agents.",
            parameters: []
        ) { _, proxy in
            let peers = await proxy.meshPeerIDs()
            let list = peers.map { #""\#($0.id)""# }.joined(separator: ",")
            return #"{"peers":[\#(list)]}"#
        }
    }
}
