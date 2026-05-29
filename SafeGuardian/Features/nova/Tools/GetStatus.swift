import Foundation
import MLXLMCommon

extension AgentToolEntry {
    /// Composite: device state + peer list. Saves a round-trip vs calling each separately.
    static func getStatus() -> AgentToolEntry {
        make(
            name: "get_status",
            description: "Device state and connected peer list in one call. Prefer this over calling get_device_state and list_peers separately.",
            parameters: []
        ) { _, proxy in
            async let tick = proxy.tick()
            async let peers = proxy.meshPeerIDs()
            let (t, p) = await (tick, peers)
            let device = t?.toolJSON ?? #"{"error":"no state tick"}"#
            let peerList = p.map { #""\#($0.id)""# }.joined(separator: ",")
            return #"{"device":\#(device),"peers":[\#(peerList)]}"#
        }
    }
}
