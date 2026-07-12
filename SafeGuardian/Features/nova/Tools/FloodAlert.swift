import SafeGuardianMesh
import BitFoundation
import Foundation
import AgentInfra

extension AgentToolEntry {
    // Temporarily raises TTL to maximum, broadcasts a life-safety alert to
    // every peer's nova agent, then restores the original TTL. The [FLOOD]
    // prefix allows receivers to surface the message above normal agent traffic.
    // Restricted to genuine life-safety events: max-TTL flooding on a dense
    // mesh causes significant relay amplification.
    static func floodAlert(senderAgentID: String) -> AgentToolEntry {
        make(
            name: "flood_alert",
            description: "Broadcast a life-safety alert at maximum mesh TTL (7 hops) to every " +
                         "reachable Nova agent. Use ONLY for confirmed mass-casualty, structural " +
                         "collapse, or immediate evacuation. TTL is restored automatically after " +
                         "transmission. Abuse of this tool saturates the mesh.",
            parameters: [
                .required("message",  type: .string,
                          description: "Alert text. Keep under 200 chars. Include location if known."),
                .required("alert_type", type: .string,
                          description: "evacuation | structural_collapse | mass_casualty | hazmat | other_lifesafety"),
            ]
        ) { args, proxy in
            guard case .string(let message)   = args["message"],
                  case .string(let alertType) = args["alert_type"] else {
                return #"{"error":"message and alert_type required"}"#
            }
            let allowed = ["evacuation", "structural_collapse", "mass_casualty", "hazmat", "other_lifesafety"]
            guard allowed.contains(alertType) else {
                return #"{"error":"invalid alert_type","valid":\#(allowed)}"#
            }

            let previousTTL = await proxy.broadcastTTL()
            await proxy.setMessageTTL(7)

            let payload = "[FLOOD] [\(alertType.uppercased())] \(message)"
            let peers = await proxy.meshPeerIDs()
            for peerID in peers {
                await proxy.sendMesh(toAgentID: "nova", content: payload, peerID: peerID)
            }

            await proxy.setMessageTTL(previousTTL)

            return """
            {"sent":true,"alert_type":"\(alertType)","peers_reached":\(peers.count),"ttl_restored":\(previousTTL)}
            """
        }
    }
}
