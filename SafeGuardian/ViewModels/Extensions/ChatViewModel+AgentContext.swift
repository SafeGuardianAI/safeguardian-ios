import BitFoundation
import Foundation

extension ChatViewModel: AgentContext {
    @MainActor
    func addResponse(sender: String, content: String, privatePeerID: PeerID?) -> SafeGuardianMessage {
        let msg = SafeGuardianMessage(sender: sender, content: content, timestamp: Date(), isRelay: false)
        if let peerID = privatePeerID {
            if privateChats[peerID] == nil { privateChats[peerID] = [] }
            privateChats[peerID]?.append(msg)
        }
        messages.append(msg)
        objectWillChange.send()
        return msg
    }

    @MainActor
    func notifyChange() {
        objectWillChange.send()
    }
}
