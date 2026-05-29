import Foundation
import BitFoundation

/// Formats and parses the content prefix used to route private messages between
/// agents over the existing Noise-encrypted BLE mesh. Follows the same pattern
/// as [FAVORITED] / [UNFAVORITED] which are already intercepted in handlePrivateMessage
/// before they reach the human UI.
///
/// Wire format:  [AGENT:{agentID}] {content}
/// Example:      [AGENT:nova] what is the structural status at sector 4?
enum AgentMeshRouting {
    static func format(agentID: String, content: String) -> String {
        "[AGENT:\(agentID)] \(content)"
    }

    static func formatReply(agentID: String, content: String) -> String {
        "[AGENT_REPLY:\(agentID)] \(content)"
    }

    static func parse(_ raw: String) -> (agentID: String, content: String)? {
        Self.extract(raw, prefix: "[AGENT:")
    }

    static func parseReply(_ raw: String) -> (agentID: String, content: String)? {
        Self.extract(raw, prefix: "[AGENT_REPLY:")
    }

    private static func extract(_ raw: String, prefix: String) -> (agentID: String, content: String)? {
        guard raw.hasPrefix(prefix),
              let closeIdx = raw.firstIndex(of: "]") else { return nil }
        let agentID = String(raw[raw.index(raw.startIndex, offsetBy: prefix.count)..<closeIdx])
        let afterBracket = raw.index(closeIdx, offsetBy: 1)
        guard afterBracket < raw.endIndex, raw[afterBracket] == " " else { return nil }
        let content = String(raw[raw.index(afterBracket, offsetBy: 1)...])
        return agentID.isEmpty ? nil : (agentID, content)
    }
}

/// A formal contract for on-device or cloud-connected agents (Nova, Trek, Apex).
/// Conformers handle specific message triggers and provide routing logic.
@MainActor
protocol AgentProcessor: Sendable {
    /// The unique identifier for the agent (e.g., "nova", "trek").
    var agentID: String { get }

    /// Human-readable name shown in the sidebar and DM header (e.g., "Nova").
    var displayName: String { get }

    /// The trigger prefix this agent responds to (e.g., "@nova").
    var triggerPrefix: String { get }

    /// The PeerID used for this agent's private chat thread.
    var peerID: PeerID { get }

    /// Determines if this agent should handle the given message.
    func shouldHandle(_ message: String) -> Bool
    
    /// Executes the agent's logic for the given prompt.
    /// - Parameters:
    ///   - prompt: The user's input (stripped of the trigger prefix).
    ///   - context: Access to the ChatViewModel for message injection and state.
    ///   - replyTo: When non-nil the agent sends its final response back to this peer via AGENT_REPLY.
    func handle(prompt: String, context: AgentContext, replyTo: PeerID?)
}

/// A restricted interface for agents to interact with the main application.
/// This prevents agents from having full read/write access to the entire ViewModel.
@MainActor
protocol AgentContext {
    var nickname: String { get }
    var privateChats: [PeerID: [SafeGuardianMessage]] { get }
    var deviceTick: NovaStateTick? { get }
    var selectedGeohash: String? { get }
    /// PeerIDs of devices currently connected on the BLE mesh.
    var meshPeerIDs: Set<PeerID> { get }
    func addLocalMessage(_ content: String)
    func addAgentLocalMessage(_ content: String, to peerID: PeerID)
    func addResponse(sender: String, content: String, privatePeerID: PeerID?) -> SafeGuardianMessage
    func notifyChange()
    /// Send a mesh private message to a specific peer, routing it to the named
    /// agent on the receiving device via AgentMeshRouting. Uses the existing
    /// Noise-encrypted BLE private message path — no new transport needed.
    func sendMeshMessage(agentID: String, content: String, to peerID: PeerID)
    /// Sends a reply using AGENT_REPLY prefix — does not trigger another agent invocation on the receiver.
    func sendMeshReply(agentID: String, content: String, to peerID: PeerID)
    /// Sends an AGENT message to the named agent on every connected peer.
    func broadcastAgentMessage(agentID: String, content: String)
}
