import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func getDeviceState() -> AgentToolEntry {
        make(
            name: "get_device_state",
            description: "Returns battery, location confidence, peer count, and transport tier.",
            parameters: []
        ) { _, proxy in
            guard let t = await proxy.tick() else { return #"{"error":"no state tick available"}"# }
            return t.toolJSON
        }
    }
}
