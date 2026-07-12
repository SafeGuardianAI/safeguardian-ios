import SafeGuardianMesh
import BitFoundation
import Foundation

// MARK: - Wire format
//
// Pattern 3 extends the existing AgentMeshRouting wire protocol with four
// session-scoped prefixes. All messages route through the existing private-
// message channel — no new BLE characteristic or framing is needed.
//
//   [SESSION_INIT:{sessionID}:{initiatorID}] {purpose}
//     Sent to a specific peer's nova agent. The peer's AgentSessionCoordinator
//     either accepts (fires a SESSION_ACCEPT reply) or rejects.
//
//   [SESSION_ACCEPT:{sessionID}]
//     Sent back to the initiator's peerID. Resumes the pending continuation
//     in openSession(with:purpose:), unblocking the calling tool.
//
//   [SESSION_REJECT:{sessionID}] {reason}
//     Sent back to the initiator on refusal or capacity limit.
//
//   [SESSION:{sessionID}] {content}
//     Bidirectional payload after a session is established. Routed to the
//     registered continuation or the active session handler by sessionID.
//
//   [SESSION_CLOSE:{sessionID}]
//     Either side may close. The coordinator removes the session entry and
//     resumes any waiting continuation with a closed sentinel.

// MARK: - Session record

struct AgentSession: Sendable {
    let sessionID: String
    let peerID: PeerID
    let purpose: String
    let openedAt: Date

    // Approximate expiry. Sessions that have not exchanged a message within
    // this window are reaped by the coordinator's maintenance sweep.
    static let ttl: TimeInterval = 300
}

// MARK: - Coordinator

/// Manages persistent named sessions between this device's Nova agent and
/// remote Nova agents on other mesh peers. Conforms to the singleton pattern
/// used by IncidentClaimStore so tools can reach it from any isolation context.
///
/// Integration requirement: ChatViewModel+Agents (or the equivalent message
/// dispatch site) must call AgentSessionCoordinator.shared.receive(_:from:)
/// for every inbound private mesh message before routing it to the normal
/// agent pipeline. The coordinator returns true when it consumed the message.
actor AgentSessionCoordinator {
    static let shared = AgentSessionCoordinator()
    private init() {}

    private var sessions: [String: AgentSession] = [:]
    private var pendingOpen: [String: CheckedContinuation<Result<AgentSession, SessionError>, Never>] = [:]
    private var pendingMessages: [String: CheckedContinuation<String, Never>] = [:]

    enum SessionError: Error, Sendable {
        case rejected(String)
        case timeout
        case closed
    }

    // MARK: - Initiator side

    /// Open a session with a remote peer's Nova agent. Suspends until the peer
    /// accepts or rejects, or until the calling Task is cancelled.
    func openSession(
        peerID: PeerID,
        initiatorID: String,
        purpose: String,
        sendMessage: @escaping @Sendable (String, PeerID) async -> Void
    ) async -> Result<AgentSession, SessionError> {
        let sessionID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased())
        let wire = "[SESSION_INIT:\(sessionID):\(initiatorID)] \(purpose)"

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingOpen[sessionID] = continuation
                Task { await sendMessage(wire, peerID) }
            }
        } onCancel: {
            Task {
                await self._cancelPendingOpen(sessionID)
            }
        }
    }

    private func _cancelPendingOpen(_ sessionID: String) {
        guard let cont = pendingOpen.removeValue(forKey: sessionID) else { return }
        cont.resume(returning: .failure(.timeout))
    }

    // MARK: - Session messaging

    /// Send a payload on an established session and suspend until the peer replies.
    func request(
        sessionID: String,
        content: String,
        sendMessage: @escaping @Sendable (String, PeerID) async -> Void
    ) async -> String {
        guard let session = sessions[sessionID] else {
            return #"{"error":"session_not_found"}"#
        }
        let wire = "[SESSION:\(sessionID)] \(content)"

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingMessages[sessionID] = continuation
                Task { await sendMessage(wire, session.peerID) }
            }
        } onCancel: {
            Task { await self._cancelPendingMessage(sessionID) }
        }
    }

    private func _cancelPendingMessage(_ sessionID: String) {
        guard let cont = pendingMessages.removeValue(forKey: sessionID) else { return }
        cont.resume(returning: "timeout")
    }

    /// Close a session. Notifies the peer and removes the local record.
    func close(
        sessionID: String,
        sendMessage: @Sendable (String, PeerID) async -> Void
    ) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        let wire = "[SESSION_CLOSE:\(sessionID)]"
        await sendMessage(wire, session.peerID)
        if let cont = pendingMessages.removeValue(forKey: sessionID) {
            cont.resume(returning: "closed")
        }
    }

    // MARK: - Receiver side (called from ChatViewModel+Agents)

    /// Call this for every inbound mesh private message before routing to the
    /// agent pipeline. Returns true when the coordinator consumed the message.
    func receive(_ raw: String, from peerID: PeerID) -> Bool {
        if let (sessionID, initiatorID, purpose) = parseInit(raw) {
            return handleInit(sessionID: sessionID, initiatorID: initiatorID, purpose: purpose, from: peerID)
        }
        if let sessionID = parseAccept(raw) {
            return handleAccept(sessionID: sessionID, from: peerID)
        }
        if let (sessionID, reason) = parseReject(raw) {
            return handleReject(sessionID: sessionID, reason: reason)
        }
        if let (sessionID, content) = parsePayload(raw) {
            return handlePayload(sessionID: sessionID, content: content)
        }
        if let sessionID = parseClose(raw) {
            return handleClose(sessionID: sessionID)
        }
        return false
    }

    // MARK: - Accept / reject policy

    // Replace this closure to apply per-deployment acceptance policy.
    // Default: accept all sessions up to a per-device limit of 4.
    nonisolated(unsafe) var acceptPolicy: @Sendable (String, String) -> Bool = { _, _ in true }
    private let maxSessions = 4

    private func handleInit(sessionID: String, initiatorID: String, purpose: String, from peerID: PeerID) -> Bool {
        if sessions.count >= maxSessions || !acceptPolicy(initiatorID, purpose) {
            // Reject: caller needs to send the wire reply — flag is returned via a stored handler.
            // For now we store a rejection marker; the host app reads it from pendingRejections.
            pendingRejections[sessionID] = (peerID, "capacity_limit")
            return true
        }
        let session = AgentSession(sessionID: sessionID, peerID: peerID, purpose: purpose, openedAt: Date())
        sessions[sessionID] = session
        pendingAccepts[sessionID] = peerID
        return true
    }

    // Populated by handleInit; consumed by ChatViewModel+Agents to send acceptance wire messages.
    private(set) var pendingAccepts: [String: PeerID] = [:]
    private(set) var pendingRejections: [String: (PeerID, String)] = [:]
    // Populated by handlePayload when we are the responder (no waiting continuation).
    private(set) var pendingResponderPayloads: [(sessionID: String, content: String, peerID: PeerID)] = []

    func consumePendingAccepts() -> [(sessionID: String, peerID: PeerID)] {
        let result = pendingAccepts.map { (sessionID: $0.key, peerID: $0.value) }
        pendingAccepts.removeAll()
        return result
    }

    func consumePendingRejections() -> [(sessionID: String, peerID: PeerID, reason: String)] {
        let result = pendingRejections.map { (sessionID: $0.key, peerID: $0.value.0, reason: $0.value.1) }
        pendingRejections.removeAll()
        return result
    }

    func consumePendingResponderPayloads() -> [(sessionID: String, content: String, peerID: PeerID)] {
        let result = pendingResponderPayloads
        pendingResponderPayloads.removeAll()
        return result
    }

    private func handleAccept(sessionID: String, from peerID: PeerID) -> Bool {
        guard let cont = pendingOpen.removeValue(forKey: sessionID) else { return false }
        let session = AgentSession(sessionID: sessionID, peerID: peerID, purpose: "", openedAt: Date())
        sessions[sessionID] = session
        cont.resume(returning: .success(session))
        return true
    }

    private func handleReject(sessionID: String, reason: String) -> Bool {
        guard let cont = pendingOpen.removeValue(forKey: sessionID) else { return false }
        cont.resume(returning: .failure(.rejected(reason)))
        return true
    }

    private func handlePayload(sessionID: String, content: String) -> Bool {
        if let cont = pendingMessages.removeValue(forKey: sessionID) {
            cont.resume(returning: content)
            return true
        }
        guard let session = sessions[sessionID] else { return false }
        pendingResponderPayloads.append((sessionID: sessionID, content: content, peerID: session.peerID))
        return true
    }

    private func handleClose(sessionID: String) -> Bool {
        sessions.removeValue(forKey: sessionID)
        if let cont = pendingMessages.removeValue(forKey: sessionID) {
            cont.resume(returning: "closed")
        }
        return true
    }

    // MARK: - Wire parsing

    private func parseInit(_ raw: String) -> (sessionID: String, initiatorID: String, purpose: String)? {
        guard raw.hasPrefix("[SESSION_INIT:"),
              let closeIdx = raw.firstIndex(of: "]") else { return nil }
        let inner = String(raw[raw.index(raw.startIndex, offsetBy: 13)..<closeIdx])
        let parts = inner.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let sessionID   = String(parts[0])
        let initiatorID = String(parts[1])
        let afterBracket = raw.index(closeIdx, offsetBy: 1)
        guard afterBracket < raw.endIndex, raw[afterBracket] == " " else { return nil }
        let purpose = String(raw[raw.index(afterBracket, offsetBy: 1)...])
        return (sessionID, initiatorID, purpose)
    }

    private func parseAccept(_ raw: String) -> String? {
        guard raw.hasPrefix("[SESSION_ACCEPT:"),
              let closeIdx = raw.firstIndex(of: "]") else { return nil }
        return String(raw[raw.index(raw.startIndex, offsetBy: 16)..<closeIdx])
    }

    private func parseReject(_ raw: String) -> (String, String)? {
        guard raw.hasPrefix("[SESSION_REJECT:"),
              let closeIdx = raw.firstIndex(of: "]") else { return nil }
        let sessionID = String(raw[raw.index(raw.startIndex, offsetBy: 16)..<closeIdx])
        let afterBracket = raw.index(closeIdx, offsetBy: 1)
        let reason = afterBracket < raw.endIndex ? String(raw[afterBracket...]).trimmingCharacters(in: .whitespaces) : ""
        return (sessionID, reason)
    }

    private func parsePayload(_ raw: String) -> (String, String)? {
        guard raw.hasPrefix("[SESSION:"),
              let closeIdx = raw.firstIndex(of: "]") else { return nil }
        let sessionID = String(raw[raw.index(raw.startIndex, offsetBy: 9)..<closeIdx])
        let afterBracket = raw.index(closeIdx, offsetBy: 1)
        guard afterBracket < raw.endIndex, raw[afterBracket] == " " else { return nil }
        let content = String(raw[raw.index(afterBracket, offsetBy: 1)...])
        return (sessionID, content)
    }

    private func parseClose(_ raw: String) -> String? {
        guard raw.hasPrefix("[SESSION_CLOSE:"),
              let closeIdx = raw.firstIndex(of: "]") else { return nil }
        return String(raw[raw.index(raw.startIndex, offsetBy: 15)..<closeIdx])
    }
}
