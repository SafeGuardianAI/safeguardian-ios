import SafeGuardianMesh
import BitFoundation
import Foundation
import AgentInfra

extension AgentToolEntry {
    // Queries every direct peer for its own peer count, building a one-hop graph.
    // Peers that do not respond within the structured-request timeout appear with
    // peer_count: null. The receiving side must handle [REQUEST:topology:{id}] and
    // reply with [REQUEST_RESPONSE:{id}] {"peer_count":N} — this is a host-layer
    // concern wired in ChatViewModel+Agents, not inference.
    static func requestMeshTopology(senderAgentID: String) -> AgentToolEntry {
        make(
            name: "request_mesh_topology",
            description: "Returns the local mesh topology: this device's direct peers and each " +
                         "peer's own peer count. Use before routing decisions, swarm role " +
                         "assignment, or when diagnosing coverage gaps. Contacts each peer " +
                         "directly; unresponsive peers appear with peer_count null.",
            parameters: []
        ) { _, proxy in
            let directPeers = await proxy.meshPeerIDs()
            guard !directPeers.isEmpty else {
                return #"{"direct_peer_count":0,"nodes":[]}"#
            }

            var nodes: [[String: Any]] = []
            await withTaskGroup(of: (String, Int?).self) { group in
                for peerID in directPeers {
                    group.addTask {
                        let response = await proxy.requestFromPeer(type: "topology", peerID: peerID)
                        guard response != "timeout",
                              let data  = response.data(using: .utf8),
                              let obj   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let count = obj["peer_count"] as? Int
                        else { return (peerID.id, nil) }
                        return (peerID.id, count)
                    }
                }
                for await (id, count) in group {
                    var node: [String: Any] = ["peer_id": id]
                    if let c = count { node["peer_count"] = c }
                    nodes.append(node)
                }
            }

            guard let data = try? JSONSerialization.data(withJSONObject: [
                "direct_peer_count": directPeers.count,
                "nodes": nodes,
            ]), let json = String(data: data, encoding: .utf8) else {
                return #"{"error":"serialization_failed"}"#
            }
            return json
        }
    }
}
