import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func getStorage() -> AgentToolEntry {
        make(
            name: "get_storage",
            description: "Returns device storage availability. Check before recommending a model download.",
            parameters: []
        ) { _, _ in
            let a = DeviceMetrics.availableStorageBytes()
            let t = DeviceMetrics.totalStorageBytes()
            return #"{"available_gb":\#(String(format:"%.1f",Double(a)/1e9)),"total_gb":\#(String(format:"%.1f",Double(t)/1e9))}"#
        }
    }
}
