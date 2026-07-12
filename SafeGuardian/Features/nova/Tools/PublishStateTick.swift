import SafeGuardianMesh
import Foundation
import AgentInfra

extension AgentToolEntry {
    // Publishes the latest StateTick immediately, then briefly requests the
    // shortest broadcaster interval so a fresh tick can follow if state changes.
    // Use when field conditions change rapidly and stale state on peer devices
    // would cause bad decisions.
    static func publishStateTick() -> AgentToolEntry {
        make(
            name: "publish_state_tick",
            description: "Immediately transmit the latest StateTick over the mesh and " +
                         "briefly request the shortest broadcast interval for a follow-up tick. " +
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
            let published = await proxy.publishCurrentStateTick()
            let previous = await proxy.broadcastInterval()
            await proxy.setTickInterval(2.0)
            let applied = await proxy.broadcastInterval()
            Task.detached {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await proxy.setTickInterval(previous)
            }
            let escapedReason = reason
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return """
            {"published":\(published),"scheduled":true,"reason":"\(escapedReason)","temporary_interval":\(applied),"previous_interval":\(previous)}
            """
        }
    }
}
