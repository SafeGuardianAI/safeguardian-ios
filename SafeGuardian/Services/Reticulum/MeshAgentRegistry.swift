import BitFoundation
import Foundation

// Tracks Reticulum agent peers detected from structured ANNOUNCE appData.
// Keyed by PeerID so multiple agents of the same type (e.g. two SDR nodes)
// are all retained. ReticulumTransport sets localDestinationHash on init so
// tool handlers can identify the caller in outbound tool call bodies.
final class MeshAgentRegistry: @unchecked Sendable {
    static let shared = MeshAgentRegistry()

    private let lock = NSLock()
    private var peers: [PeerID: ReticulumAgentPeer] = [:]

    var toolRouter: LXMFToolRouter?
    var localDestinationHash: String?

    private init() {}

    func register(_ peer: ReticulumAgentPeer) {
        lock.lock()
        peers[peer.peerID] = peer
        lock.unlock()
    }

    func agents(type agentType: String) -> [ReticulumAgentPeer] {
        lock.lock()
        defer { lock.unlock() }
        return peers.values.filter { $0.agentType == agentType && !$0.isStale }
    }

    // Convenience — returns first matching peer. Sufficient for single-node deployments.
    func agent(type agentType: String) -> ReticulumAgentPeer? {
        agents(type: agentType).first
    }

    func remove(peerID: PeerID) {
        lock.lock()
        peers.removeValue(forKey: peerID)
        lock.unlock()
    }
}

struct ReticulumAgentPeer: Sendable {
    let peerID:          PeerID
    let destinationHash: Data
    let agentType:       String
    let capabilities:    [String]
    let lastSeenAt:      Date

    // A peer that has not re-announced within 2× the 300s re-announce interval is considered stale.
    static let stalenessThreshold: TimeInterval = 600

    var isStale: Bool {
        Date().timeIntervalSince(lastSeenAt) > Self.stalenessThreshold
    }

    // Returns true when caps is non-empty and tool is absent from it.
    // An empty caps list does not constrain calls (backward compat).
    func rejectsTool(_ toolName: String) -> Bool {
        !capabilities.isEmpty && !capabilities.contains(toolName)
    }

    static func decode(peerID: PeerID, destinationHash: Data, appData: Data) -> ReticulumAgentPeer? {
        guard let json = try? JSONSerialization.jsonObject(with: appData) as? [String: Any],
              let type_ = json["type"] as? String else { return nil }
        let caps = json["caps"] as? [String] ?? []
        return ReticulumAgentPeer(
            peerID: peerID,
            destinationHash: destinationHash,
            agentType: type_,
            capabilities: caps,
            lastSeenAt: Date()
        )
    }
}
