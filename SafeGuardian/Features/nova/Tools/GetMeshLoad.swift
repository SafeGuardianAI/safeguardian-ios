import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func getMeshLoad() -> AgentToolEntry {
        make(
            name: "get_mesh_load",
            description: "Returns mesh packet rate, peer count, saturation %, and current tick interval and TTL. High saturation means the mesh is congested — reduce tick frequency and TTL to conserve bandwidth. Low saturation means spare capacity exists.",
            parameters: []
        ) { _, proxy in
            async let rate     = proxy.meshPacketRate()
            async let interval = proxy.broadcastInterval()
            async let ttl      = proxy.broadcastTTL()
            async let peers    = proxy.meshPeerIDs()

            let (r, iv, t, p) = await (rate, interval, ttl, peers)
            let peerCount = p.count

            // Saturation: ~36 pkt/s network-wide capacity at 1M PHY D=8 K=sqrt(D).
            let networkCapacity: Double = 36.0
            let saturationPct = min(100.0, (r / networkCapacity) * 100.0)

            return String(format: #"{"packet_rate_per_s":%.2f,"peer_count":%d,"saturation_pct":%.1f,"tick_interval_s":%.0f,"message_ttl":%d}"#,
                          r, peerCount, saturationPct, iv, t)
        }
    }
}
