import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func setTickInterval() -> AgentToolEntry {
        make(
            name: "set_tick_interval",
            description: "Set Nova's state tick broadcast interval in seconds (30–300). HIGHER interval = fewer ticks = less mesh bandwidth consumed. Default conserves bandwidth. Only reduce interval when saturation is low AND fresher state is operationally necessary.",
            parameters: [
                .required("interval_seconds", type: .string,
                          description: "Seconds between ticks as a number string. Clamped to [30, 300]. Prefer higher values to reduce mesh load.")
            ]
        ) { args, proxy in
            guard case .string(let s) = args["interval_seconds"],
                  let val = Double(s) else {
                return #"{"error":"interval_seconds required"}"#
            }
            await proxy.setTickInterval(TimeInterval(val))
            let applied = await proxy.broadcastInterval()
            return String(format: #"{"tick_interval_s":%.0f}"#, applied)
        }
    }
}
