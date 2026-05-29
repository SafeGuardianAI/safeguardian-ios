import BitFoundation
import Foundation

extension ChatViewModel: AgentContext {
    var deviceTick: NovaStateTick? { NovaBroadcaster.shared?.latestTick }
    var selectedGeohash: String? { LocationChannelManager.shared.selectedChannel.nostrGeohashTag }
    var meshPeerIDs: Set<PeerID> { unifiedPeerService.connectedPeerIDs }

    @MainActor
    func sendMeshMessage(agentID: String, content: String, to peerID: PeerID) {
        sendPrivateMessage(AgentMeshRouting.format(agentID: agentID, content: content), to: peerID)
    }

    @MainActor
    func sendMeshReply(agentID: String, content: String, to peerID: PeerID) {
        sendPrivateMessage(AgentMeshRouting.formatReply(agentID: agentID, content: content), to: peerID)
    }

    @MainActor
    func broadcastAgentMessage(agentID: String, content: String) {
        for peerID in meshService.getPeersWithAgent(agentID) {
            sendMeshMessage(agentID: agentID, content: content, to: peerID)
        }
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
