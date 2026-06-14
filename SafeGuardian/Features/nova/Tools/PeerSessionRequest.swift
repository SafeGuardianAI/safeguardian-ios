import BitFoundation
import Foundation
import MLXLMCommon

extension AgentToolEntry {
    /// Sends a message on an open peer session and suspends until the peer replies.
    /// The session must have been opened with open_peer_session first.
    static func peerSessionRequest() -> AgentToolEntry {
        make(
            name: "peer_session_request",
            description: "Send a message on an established peer session and wait for the peer's reply. The session_id comes from a previous open_peer_session call. Use this for each turn of a negotiation.",
            parameters: [
                .required("session_id", type: .string, description: "The session_id returned by open_peer_session."),
                .required("content", type: .string, description: "The message to send. Can be a question, an offer, a counter-proposal, or a confirmation.")
            ]
        ) { args, proxy in
            guard case .string(let sessionID) = args["session_id"],
                  case .string(let content) = args["content"] else {
                return #"{"error":"missing required argument"}"#
            }
            let response = await AgentSessionCoordinator.shared.request(
                sessionID: sessionID,
                content: content,
                sendMessage: { msg, peerID in
                    await proxy.sendRawPrivate(msg, peerID: peerID)
                }
            )
            if response == "timeout" { return #"{"error":"timeout"}"# }
            if response == "closed"  { return #"{"error":"session_closed"}"# }
            let escaped = response
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return #"{"response":"\#(escaped)"}"#
        }
    }
}
