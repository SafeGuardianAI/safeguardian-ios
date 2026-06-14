import BitFoundation
import Foundation
import MLXLMCommon

// Tracks incidents claimed by this device's Nova agent for the current session.
// Claims are soft locks: other devices see the broadcast and prefer unclaimed
// incidents. The store is in-process only; it resets on restart.
actor IncidentClaimStore {
    static let shared = IncidentClaimStore()
    private var claims: [String: String] = [:]

    func claim(incidentID: String, claimerID: String) -> Bool {
        guard claims[incidentID] == nil else { return false }
        claims[incidentID] = claimerID
        return true
    }

    func holder(of incidentID: String) -> String? { claims[incidentID] }

    func release(incidentID: String, claimerID: String) {
        if claims[incidentID] == claimerID { claims.removeValue(forKey: incidentID) }
    }
}

extension AgentToolEntry {
    static func claimIncident(senderAgentID: String) -> AgentToolEntry {
        make(
            name: "claim_incident",
            description: "Register this Nova agent as the active responder for an incident and " +
                         "broadcast the claim to all mesh peers so other agents yield that incident. " +
                         "Returns claimed:true when the slot was free; claimed:false when another " +
                         "agent already holds it. Call release_incident when response is complete.",
            parameters: [
                .required("incident_id", type: .string,
                          description: "Incident identifier from the incident report or EIDO record."),
                .required("agent_id",    type: .string,
                          description: "This agent's unique identifier, e.g. the nova callsign."),
            ]
        ) { args, proxy in
            guard case .string(let incidentID) = args["incident_id"],
                  case .string(let agentID)    = args["agent_id"] else {
                return #"{"error":"incident_id and agent_id required"}"#
            }

            let claimed = await IncidentClaimStore.shared.claim(incidentID: incidentID, claimerID: agentID)
            guard claimed else {
                let holder = await IncidentClaimStore.shared.holder(of: incidentID) ?? "unknown"
                return """
                {"claimed":false,"incident_id":"\(incidentID)","held_by":"\(holder)"}
                """
            }

            let payload = """
            {"type":"incident_claim","incident_id":"\(incidentID)","agent_id":"\(agentID)"}
            """
            let peers = await proxy.meshPeerIDs()
            for peerID in peers {
                await proxy.sendMesh(toAgentID: "nova", content: payload, peerID: peerID)
            }
            return """
            {"claimed":true,"incident_id":"\(incidentID)","agent_id":"\(agentID)","peers_notified":\(peers.count)}
            """
        }
    }

    static func releaseIncident(senderAgentID: String) -> AgentToolEntry {
        make(
            name: "release_incident",
            description: "Release a previously claimed incident so other agents can take it. " +
                         "Call this when the response is complete, the unit is departing, or " +
                         "command reassigns the incident to another team.",
            parameters: [
                .required("incident_id", type: .string, description: "Incident to release."),
                .required("agent_id",    type: .string, description: "Must match the original claimant."),
            ]
        ) { args, proxy in
            guard case .string(let incidentID) = args["incident_id"],
                  case .string(let agentID)    = args["agent_id"] else {
                return #"{"error":"incident_id and agent_id required"}"#
            }
            await IncidentClaimStore.shared.release(incidentID: incidentID, claimerID: agentID)
            let payload = """
            {"type":"incident_release","incident_id":"\(incidentID)","agent_id":"\(agentID)"}
            """
            let peers = await proxy.meshPeerIDs()
            for peerID in peers {
                await proxy.sendMesh(toAgentID: "nova", content: payload, peerID: peerID)
            }
            return """
            {"released":true,"incident_id":"\(incidentID)","peers_notified":\(peers.count)}
            """
        }
    }
}
