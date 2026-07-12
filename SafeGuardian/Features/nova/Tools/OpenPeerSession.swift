import SafeGuardianMesh
import BitFoundation
import Foundation
import AgentInfra

extension AgentToolEntry {
    /// Opens a persistent coordination session with a specific peer's Nova agent.
    /// Suspends until the peer accepts or rejects. On success, returns a session_id
    /// for use with peer_session_request and close_peer_session.
    static func openPeerSession(agentID: String) -> AgentToolEntry {
        make(
            name: "open_peer_session",
            description: "Open a coordination session with a specific peer's Nova agent. Use this when a single exchange isn't enough — capability negotiation, rendezvous planning, or multi-turn resource coordination. Returns a session_id on success.",
            parameters: [
                .required("peer_id", type: .string, description: "The PeerID of the peer — use list_peers first."),
                .required("purpose", type: .string, description: "Brief description of what you want to coordinate, e.g. 'rendezvous location' or 'backboard availability'.")
            ]
        ) { args, proxy in
            guard case .string(let peerIDStr) = args["peer_id"],
                  case .string(let purpose) = args["purpose"] else {
                return #"{"error":"missing required argument"}"#
            }
            let result = await AgentSessionCoordinator.shared.openSession(
                peerID: PeerID(str: peerIDStr),
                initiatorID: agentID,
                purpose: purpose,
                sendMessage: { content, targetPeer in
                    await proxy.sendRawPrivate(content, peerID: targetPeer)
                }
            )
            switch result {
            case .success(let session):
                let escaped = session.purpose
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return #"{"session_id":"\#(session.sessionID)","status":"accepted","purpose":"\#(escaped)"}"#
            case .failure(.rejected(let reason)):
                let r = reason.replacingOccurrences(of: "\"", with: "\\\"")
                return #"{"error":"rejected","reason":"\#(r)"}"#
            case .failure(.timeout):
                return #"{"error":"timeout"}"#
            case .failure(.closed):
                return #"{"error":"closed"}"#
            }
        }
    }
}
