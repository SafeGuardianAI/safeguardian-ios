import AgentInfra
import BitFoundation
import Foundation

extension ChatViewModel: AgentContext {
    var deviceTick: AgentStateTick? { NovaBroadcaster.shared?.latestTick }
    var selectedGeohash: String? { LocationChannelManager.shared.selectedChannel.nostrGeohashTag }
    var meshPeerIDs: Set<PeerID> {
        Set(unifiedPeerService.peers.filter { $0.isConnected || $0.isReachable }.map { $0.peerID })
    }

    var meshPacketRate: Double { meshService.meshPacketRate() }
    var broadcastInterval: TimeInterval { NovaBroadcaster.shared?.broadcaster.currentInterval ?? 60 }
    var broadcastTTL: UInt8 { NovaBroadcaster.shared?.broadcaster.preferredTTL ?? 7 }

    func setTickInterval(_ seconds: TimeInterval) {
        NovaBroadcaster.shared?.broadcaster.setAgentInterval(seconds)
    }

    func setMessageTTL(_ ttl: UInt8) {
        NovaBroadcaster.shared?.broadcaster.setPreferredTTL(ttl)
    }

    @discardableResult
    func publishCurrentStateTick() -> Bool {
        guard let tick = deviceTick,
              let sgClient else { return false }
        sgClient.publishStateTick(tick)
        return true
    }

    @MainActor
    func sendMeshMessage(agentID: String, content: String, to peerID: PeerID, requestID: String? = nil) {
        sendPrivateMessage(AgentMeshRouting.format(agentID: agentID, content: content, requestID: requestID), to: peerID)
    }

    @MainActor
    func sendMeshReply(agentID: String, content: String, to peerID: PeerID, requestID: String? = nil) {
        sendPrivateMessage(AgentMeshRouting.formatReply(agentID: agentID, content: content, requestID: requestID), to: peerID)
    }

    @MainActor
    func registerAgentReplyContinuation(_ requestID: String, _ continuation: CheckedContinuation<String, Never>) {
        pendingAgentReplies[requestID] = continuation
    }

    @MainActor
    func registerToolApprovalContinuation(_ token: String, _ continuation: CheckedContinuation<Bool, Never>) {
        pendingToolApprovals[token] = continuation
        // Auto-approve until UI approval is wired up. To add interactive approval:
        // 1. Remove this line and store the continuation in pendingToolApprovals
        // 2. Surface an alert/sheet keyed on token
        // 3. On user action: pendingToolApprovals.removeValue(forKey: token)?.resume(returning: decision)
        pendingToolApprovals.removeValue(forKey: token)?.resume(returning: true)
    }

    @MainActor
    func broadcastAgentMessage(agentID: String, content: String) {
        for peerID in meshService.getPeersWithAgent(agentID) {
            sendMeshMessage(agentID: agentID, content: content, to: peerID)
        }
    }

    @MainActor
    func sendPeerRequest(type: String, requestID: String, to peerID: PeerID) {
        sendPrivateMessage(AgentMeshRouting.formatRequest(type: type, requestID: requestID), to: peerID)
    }

    @MainActor
    func sendRawPrivate(_ content: String, to peerID: PeerID) {
        sendPrivateMessage(content, to: peerID)
    }

    @MainActor
    func registerPeerRequestContinuation(_ requestID: String, _ continuation: CheckedContinuation<String, Never>) {
        pendingPeerRequests[requestID] = continuation
    }

    @MainActor
    func cancelAgentRequest(_ requestID: String) {
        pendingAgentReplies.removeValue(forKey: requestID)?.resume(returning: "timeout")
    }

    @MainActor
    func cancelPeerRequest(_ requestID: String) {
        pendingPeerRequests.removeValue(forKey: requestID)?.resume(returning: "timeout")
    }

    @MainActor
    func addAgentLocalMessage(_ content: String, to peerID: PeerID) {
        let msg = SafeGuardianMessage(sender: "local", content: content, timestamp: Date(), isRelay: false)
        if privateChats[peerID] == nil { privateChats[peerID] = [] }
        privateChats[peerID]?.append(msg)
        objectWillChange.send()
    }

    @MainActor
    func removeResponse(_ response: SafeGuardianMessage, from threadID: PeerID) {
        privateChats[threadID]?.removeAll(where: { $0 === response })
        objectWillChange.send()
    }

    @MainActor
    @discardableResult
    func addResponse(sender: String, content: String, privatePeerID: PeerID?) -> SafeGuardianMessage {
        let msg = SafeGuardianMessage(sender: sender, content: content, timestamp: Date(), isRelay: false)
        if let peerID = privatePeerID {
            if privateChats[peerID] == nil { privateChats[peerID] = [] }
            privateChats[peerID]?.append(msg)
        } else {
            messages.append(msg)
        }
        objectWillChange.send()
        return msg
    }

    @MainActor
    func notifyChange() {
        objectWillChange.send()
        // Poke privateChatManager so its $privateChats publisher fires — the TUI
        // subscription watches $privateChats and would otherwise miss streaming token updates
        // since those mutate SafeGuardianMessage.content in-place without replacing the dict.
        privateChatManager.privateChats = privateChatManager.privateChats
    }

    /// Intercepts inbound agent-specific wire messages (Pattern 1 Requests, Pattern 3 Sessions)
    /// before they reach the human DM view or the standard agent pipeline.
    @MainActor
    func interceptAgentInbound(_ message: SafeGuardianMessage) async -> Bool {
        guard let peerID = message.senderPeerID else { return false }

        // Pattern 3: Agent Sessions
        if await AgentSessionCoordinator.shared.receive(message.content, from: peerID) {
            let coordinator = AgentSessionCoordinator.shared
            for (sessionID, targetPeerID) in await coordinator.consumePendingAccepts() {
                sendPrivateMessage("[SESSION_ACCEPT:\(sessionID)]", to: targetPeerID)
            }
            for (sessionID, targetPeerID, reason) in await coordinator.consumePendingRejections() {
                sendPrivateMessage("[SESSION_REJECT:\(sessionID)] \(reason)", to: targetPeerID)
            }
            for (sessionID, content, senderPeerID) in await coordinator.consumePendingResponderPayloads() {
                let prompt = "Peer coordination session \(sessionID) — incoming: \(content). Reply using peer_session_request with session_id \"\(sessionID)\"."
                agents.first(where: { $0.agentID == "nova" })?.handle(
                    prompt: prompt, context: self, threadPeerID: senderPeerID
                )
            }
            return true
        }

        // Pattern 1: Topology Request
        if let request = AgentMeshRouting.parseRequest(message.content), request.type == "topology" {
            let response = "{\"peer_count\":\(meshPeerIDs.count)}"
            sendPrivateMessage(AgentMeshRouting.formatRequestResponse(requestID: request.requestID, result: response), to: peerID)
            return true
        }

        // Pattern: Nova Agent Mesh Broadcasts (Incident Claims)
        if let data = message.content.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = obj["type"] as? String,
           let incidentID = obj["incident_id"] as? String,
           let agentID = obj["agent_id"] as? String {
            
            if type == "incident_claim" {
                _ = await IncidentClaimStore.shared.claim(incidentID: incidentID, claimerID: agentID)
                return true
            } else if type == "incident_release" {
                await IncidentClaimStore.shared.release(incidentID: incidentID, claimerID: agentID)
                return true
            }
        }

        return false
    }
}
