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
    // requestID is included when the sender expects a correlated reply (agent-to-agent).
    // Omitting it produces the original fire-and-forget format (human-to-agent).
    static func format(agentID: String, content: String, requestID: String? = nil) -> String {
        if let id = requestID { return "[AGENT:\(agentID):\(id)] \(content)" }
        return "[AGENT:\(agentID)] \(content)"
    }

    static func formatReply(agentID: String, content: String, requestID: String? = nil) -> String {
        if let id = requestID { return "[AGENT_REPLY:\(agentID):\(id)] \(content)" }
        return "[AGENT_REPLY:\(agentID)] \(content)"
    }

    // Pattern 1 — Structured peer request (no inference, explicit consent).
    // Wire: [REQUEST:{type}:{requestID}] and [REQUEST_RESPONSE:{requestID}] {result}

    static func formatRequest(type requestType: String, requestID: String) -> String {
        "[REQUEST:\(requestType):\(requestID)]"
    }

    static func formatRequestResponse(requestID: String, result: String) -> String {
        "[REQUEST_RESPONSE:\(requestID)] \(result)"
    }

    static func parseRequest(_ raw: String) -> (type: String, requestID: String)? {
        guard raw.hasPrefix("[REQUEST:") else { return nil }
        let inner = raw.dropFirst(9) // drop "[REQUEST:"
        guard let closeIdx = inner.firstIndex(of: "]") else { return nil }
        let parts = String(inner[..<closeIdx]).split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let type = String(parts[0])
        let requestID = String(parts[1])
        guard !type.isEmpty, !requestID.isEmpty else { return nil }
        return (type, requestID)
    }

    static func parseRequestResponse(_ raw: String) -> (requestID: String, result: String)? {
        guard raw.hasPrefix("[REQUEST_RESPONSE:") else { return nil }
        let inner = raw.dropFirst(18) // drop "[REQUEST_RESPONSE:"
        guard let closeIdx = inner.firstIndex(of: "]") else { return nil }
        let requestID = String(inner[..<closeIdx])
        guard !requestID.isEmpty else { return nil }
        let afterBracket = inner.index(closeIdx, offsetBy: 1)
        guard afterBracket < inner.endIndex, inner[afterBracket] == " " else { return nil }
        let result = String(inner[inner.index(afterBracket, offsetBy: 1)...])
        return (requestID, result)
    }

    static func parse(_ raw: String) -> (agentID: String, content: String, requestID: String?)? {
        Self.extract(raw, prefix: "[AGENT:")
    }

    static func parseReply(_ raw: String) -> (agentID: String, content: String, requestID: String?)? {
        Self.extract(raw, prefix: "[AGENT_REPLY:")
    }

    // Parses [PREFIX:{agentID}] or [PREFIX:{agentID}:{requestID}] followed by content.
    private static func extract(
        _ raw: String, prefix: String
    ) -> (agentID: String, content: String, requestID: String?)? {
        guard raw.hasPrefix(prefix),
              let closeIdx = raw.firstIndex(of: "]") else { return nil }
        let inner = String(raw[raw.index(raw.startIndex, offsetBy: prefix.count)..<closeIdx])
        let afterBracket = raw.index(closeIdx, offsetBy: 1)
        guard afterBracket < raw.endIndex, raw[afterBracket] == " " else { return nil }
        let content = String(raw[raw.index(afterBracket, offsetBy: 1)...])
        // inner is either "agentID" or "agentID:requestID"
        let parts = inner.split(separator: ":", maxSplits: 1)
        guard let first = parts.first, !first.isEmpty else { return nil }
        let agentID = String(first)
        let requestID = parts.count == 2 ? String(parts[1]) : nil
        return (agentID, content, requestID)
    }
}

/// A formal contract for on-device or cloud-connected agents (Nova, Trek, Apex).
/// The single requirement is conversationConfig; all other properties and methods
/// are derived from it via the protocol extension below.
@MainActor
protocol AgentProcessor: Sendable {
    var conversationConfig: AgentConversationConfig { get }
}

extension AgentProcessor {
    var agentID: String       { conversationConfig.agentID }
    var displayName: String   { conversationConfig.displayName }
    var peerID: PeerID        { conversationConfig.peerID }
    var triggerPrefix: String { conversationConfig.triggerPrefix }

    func shouldHandle(_ message: String) -> Bool {
        let lower = message.trimmed.lowercased()
        return lower == triggerPrefix || lower.hasPrefix(triggerPrefix + " ")
    }

    func handle(prompt: String, image: Data? = nil, context: any AgentContext, threadPeerID: PeerID? = nil, replyTo: PeerID? = nil, replyID: String? = nil) {
        AgentConversationEngine.shared.handle(
            prompt: prompt, image: image, config: conversationConfig,
            context: context, threadPeerID: threadPeerID, replyTo: replyTo, replyID: replyID
        )
    }
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
    @discardableResult
    func addResponse(sender: String, content: String, privatePeerID: PeerID?) -> SafeGuardianMessage
    /// Removes a previously added response from a thread — used to suppress
    /// placeholder messages when an agent decides to skip a mesh query.
    func removeResponse(_ response: SafeGuardianMessage, from threadID: PeerID)
    func notifyChange()
    /// Send a mesh private message to a specific peer, routing it to the named agent.
    /// When requestID is non-nil the wire format includes the ID so the receiver's reply
    /// can be correlated back to a waiting continuation (agent-to-agent pattern).
    func sendMeshMessage(agentID: String, content: String, to peerID: PeerID, requestID: String?)
    /// Sends a reply using AGENT_REPLY prefix. requestID mirrors the one from the inbound
    /// request so the sender can resume a waiting continuation rather than showing UI.
    func sendMeshReply(agentID: String, content: String, to peerID: PeerID, requestID: String?)
    /// Sends an AGENT message to the named agent on every connected peer.
    func broadcastAgentMessage(agentID: String, content: String)
    // Mesh adaptation — Nova tools read and adjust broadcast parameters.
    var meshPacketRate: Double { get }
    var broadcastInterval: TimeInterval { get }
    var broadcastTTL: UInt8 { get }
    func setTickInterval(_ seconds: TimeInterval)
    func setMessageTTL(_ ttl: UInt8)

    /// Sends a [REQUEST:{type}:{requestID}] wire message to the peer, initiating a structured peer request.
    func sendPeerRequest(type: String, requestID: String, to peerID: PeerID)
    /// Stores a continuation to be resumed when the peer sends back [REQUEST_RESPONSE:{requestID}].
    func registerPeerRequestContinuation(_ requestID: String, _ continuation: CheckedContinuation<String, Never>)
    /// Stores a continuation to be resumed when a remote agent replies with the matching requestID.
    func registerAgentReplyContinuation(_ requestID: String, _ continuation: CheckedContinuation<String, Never>)
    /// Stores a continuation to be resumed when the user approves or denies a tool execution.
    /// The continuation is keyed by an opaque token generated by AgentContextProxy.
    func registerToolApprovalContinuation(_ token: String, _ continuation: CheckedContinuation<Bool, Never>)
    /// Removes and resumes the agent reply continuation for requestID with "timeout".
    /// Called when the waiting Task is cancelled so the continuation does not leak.
    func cancelAgentRequest(_ requestID: String)
    /// Removes and resumes the peer request continuation for requestID with "timeout".
    /// Called when the waiting Task is cancelled so the continuation does not leak.
    func cancelPeerRequest(_ requestID: String)
}
