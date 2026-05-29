import Foundation
import MLXLMCommon

extension AgentToolEntry {
    /// Composite: device state + peers + storage + memory. Use before recommending a model download.
    static func getFullStatus() -> AgentToolEntry {
        make(
            name: "get_full_status",
            description: "Device state, peer list, storage, and RAM in one call. Use before recommending or initiating a model download.",
            parameters: []
        ) { _, proxy in
            async let tick = proxy.tick()
            async let peers = proxy.meshPeerIDs()
            let (t, p) = await (tick, peers)
            let device   = t?.toolJSON ?? #"{"error":"no state tick"}"#
            let peerList = p.map { #""\#($0.id)""# }.joined(separator: ",")
            let aS = DeviceMetrics.availableStorageBytes()
            let tS = DeviceMetrics.totalStorageBytes()
            let aM = DeviceMetrics.availableMemoryBytes()
            let tM = DeviceMetrics.totalMemoryBytes()
            let storage  = #"{"available_gb":\#(String(format:"%.1f",Double(aS)/1e9)),"total_gb":\#(String(format:"%.1f",Double(tS)/1e9))}"#
            let memory   = #"{"available_gb":\#(String(format:"%.2f",Double(aM)/1e9)),"total_gb":\#(String(format:"%.2f",Double(tM)/1e9))}"#
            return #"{"device":\#(device),"peers":[\#(peerList)],"storage":\#(storage),"memory":\#(memory)}"#
        }
    }
}
