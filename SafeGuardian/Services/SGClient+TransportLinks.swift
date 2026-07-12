import SafeGuardianMesh
import Foundation

// Transport introspection: aggregates the current peer snapshots into one
// entry per link type so agent tools can reason about available bandwidth.
extension SGClient {

    func availableTransportLinks() -> [SGTransportLink] {
        guard let transport else { return [] }
        return transport.currentPeerSnapshots()
            .reduce(into: [LinkType: SGTransportLink]()) { acc, snap in
                if acc[snap.linkType] == nil {
                    acc[snap.linkType] = SGTransportLink(
                        linkType: snap.linkType,
                        estimatedBandwidthBps: snap.estimatedBandwidthBps,
                        peerCount: 1
                    )
                } else {
                    acc[snap.linkType]?.peerCount += 1
                }
            }
            .values
            .sorted { $0.estimatedBandwidthBps > $1.estimatedBandwidthBps }
    }
}

// MARK: - SGTransportLink

struct SGTransportLink {
    let linkType: LinkType
    let estimatedBandwidthBps: Int
    var peerCount: Int
}
