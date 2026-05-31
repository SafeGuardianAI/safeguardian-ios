import BitFoundation
import Foundation

extension ChatViewModel: AgentContext {
    var deviceTick: NovaStateTick? { NovaBroadcaster.shared?.latestTick }
    var selectedGeohash: String? { LocationChannelManager.shared.selectedChannel.nostrGeohashTag }
    var meshPeerIDs: Set<PeerID> { unifiedPeerService.connectedPeerIDs }

    var meshPacketRate: Double { meshService.meshPacketRate() }
    var broadcastInterval: TimeInterval { NovaBroadcaster.shared?.broadcaster.currentInterval ?? 60 }
    var broadcastTTL: UInt8 { NovaBroadcaster.shared?.broadcaster.preferredTTL ?? 7 }

    func setTickInterval(_ seconds: TimeInterval) {
        NovaBroadcaster.shared?.broadcaster.setAgentInterval(seconds)
    }

    func setMessageTTL(_ ttl: UInt8) {
        NovaBroadcaster.shared?.broadcaster.setPreferredTTL(ttl)
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
    func registerPeerRequestContinuation(_ requestID: String, _ continuation: CheckedContinuation<String, Never>) {
        pendingPeerRequests[requestID] = continuation
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
}
