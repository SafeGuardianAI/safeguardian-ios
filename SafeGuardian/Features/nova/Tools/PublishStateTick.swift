import Foundation
import MLXLMCommon

extension AgentToolEntry {
    // Shortens the broadcast interval to 2 seconds so the next StateTick fires
    // almost immediately, then restores the original interval after 4 seconds.
    // The restore runs in a detached task so this tool returns without blocking.
    // Use when field conditions change rapidly and the normal tick cadence is
    // too slow to propagate current device state to mesh peers.
    static func publishStateTick() -> AgentToolEntry {
        make(
            name: "publish_state_tick",
            description: "Force the next StateTick broadcast to fire within 2 seconds by " +
                         "temporarily tightening the broadcast interval, then restoring it. " +
                         "Use after a significant location change, battery threshold crossing, " +
                         "or any event where stale state on peer devices would cause bad decisions.",
            parameters: [
                .required("reason", type: .string,
                          description: "Brief description of why an immediate tick is needed."),
            ]
        ) { args, proxy in
            guard case .string(let reason) = args["reason"] else {
                return #"{"error":"reason required"}"#
            }
            let previous = await proxy.broadcastInterval()
            await proxy.setTickInterval(2.0)
            Task.detached {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await proxy.setTickInterval(previous)
            }
            return """
            {"scheduled":true,"reason":"\(reason)","next_tick_within_seconds":2,"previous_interval":\(previous)}
            """
        }
    }
}
