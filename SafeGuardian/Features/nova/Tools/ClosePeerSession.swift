import BitFoundation
import Foundation
import MLXLMCommon

extension AgentToolEntry {
    /// Closes a peer session and notifies the remote side.
    static func closePeerSession() -> AgentToolEntry {
        make(
            name: "close_peer_session",
            description: "Close an open peer session when coordination is complete or no longer needed. Notifies the peer so they can clean up their end.",
            parameters: [
                .required("session_id", type: .string, description: "The session_id to close.")
            ]
        ) { args, proxy in
            guard case .string(let sessionID) = args["session_id"] else {
                return #"{"error":"missing required argument"}"#
            }
            await AgentSessionCoordinator.shared.close(
                sessionID: sessionID,
                sendMessage: { content, peerID in
                    await proxy.sendRawPrivate(content, peerID: peerID)
                }
            )
            return #"{"status":"closed","session_id":"\#(sessionID)"}"#
        }
    }
}
