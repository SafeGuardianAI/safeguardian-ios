import SafeGuardianMesh
import BitFoundation
import Foundation

// SGEnvelopeHandler receives decoded SGEnvelope packets from MultiTransportManager
// and dispatches them to registered callbacks by payload type.
//
// Wire up at app launch by setting the callbacks before any transport activity begins.
// Each callback receives the raw payload bytes and the sender PeerID; higher-level
// deserialisation (JSON entity, protobuf task, etc.) happens in the callback.
final class SGEnvelopeHandler {

    var onEntity: ((Data, PeerID) -> Void)?
    var onTriage: ((Data, PeerID) -> Void)?
    var onAgentMsg: ((Data, PeerID) -> Void)?
    var onStateTick: ((Data, PeerID) -> Void)?

    func handle(_ envelope: SGEnvelope, from peerID: PeerID) {
        switch envelope.payloadType {
        case .entity:    onEntity?(envelope.payload, peerID)
        case .triage:    onTriage?(envelope.payload, peerID)
        case .agentMsg:  onAgentMsg?(envelope.payload, peerID)
        case .stateTick: onStateTick?(envelope.payload, peerID)
        }
    }
}
