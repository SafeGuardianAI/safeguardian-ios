import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func getMemory() -> AgentToolEntry {
        make(
            name: "get_memory",
            description: "Returns device RAM availability. Check before loading a large model.",
            parameters: []
        ) { _, _ in
            let a = DeviceMetrics.availableMemoryBytes()
            let t = DeviceMetrics.totalMemoryBytes()
            return #"{"available_gb":\#(String(format:"%.2f",Double(a)/1e9)),"total_gb":\#(String(format:"%.2f",Double(t)/1e9))}"#
        }
    }
}
