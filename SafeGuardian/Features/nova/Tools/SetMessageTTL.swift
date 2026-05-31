import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func setMessageTTL() -> AgentToolEntry {
        make(
            name: "set_message_ttl",
            description: "Set hop limit for Nova's outgoing mesh ticks (3–7). LOWER TTL = fewer relay hops = less total mesh bandwidth consumed. Use lower values in dense meshes or when saturated. Only raise TTL in sparse meshes where peers cannot be reached in fewer hops.",
            parameters: [
                .required("ttl", type: .string,
                          description: "Hop limit as a number string. Clamped to [3, 7]. Prefer lower values to reduce relay flood.")
            ]
        ) { args, proxy in
            guard case .string(let s) = args["ttl"],
                  let val = Int(s) else {
                return #"{"error":"ttl required"}"#
            }
            await proxy.setMessageTTL(UInt8(clamping: val))
            let applied = await proxy.broadcastTTL()
            return #"{"message_ttl":\#(applied)}"#
        }
    }
}
