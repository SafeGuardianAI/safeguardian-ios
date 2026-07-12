import SafeGuardianMesh
import Foundation
import AgentInfra

extension AgentToolEntry {
    static func sdrMonitor() -> AgentToolEntry {
        make(
            name: "sdr_monitor",
            description: "Reserve the SDR node to monitor a frequency for a fixed duration. " +
                         "Returns a reservation_token usable with sdr_cancel.",
            parameters: [
                .required("freq_hz", type: .int,
                          description: "Frequency to monitor in Hz."),
                .optional("mode", type: .string,
                          description: "Demodulation mode: fm_voice | am | nfm | raw."),
                .optional("duration_s", type: .int,
                          description: "Monitoring duration in seconds. Default 60."),
                .optional("priority", type: .string,
                          description: "Priority tier: low | normal | high | critical."),
                .optional("requesting_agent", type: .string,
                          description: "Agent identifier to associate with this reservation."),
            ]
        ) { args, _ in
            let freqHz: Int
            switch args["freq_hz"] {
            case .int(let v):    freqHz = v
            case .double(let v): freqHz = Int(v)
            default:
                return #"{"error":"freq_hz is required"}"#
            }
            guard let peer = MeshAgentRegistry.shared.agent(type: "sdr"),
                  let router = MeshAgentRegistry.shared.toolRouter else {
                return #"{"error":"sdr_agent_unavailable","message":"No SDR node detected on the mesh."}"#
            }
            guard !peer.rejectsTool("sdr_monitor") else {
                return #"{"error":"sdr_capability_unavailable","message":"Detected SDR node does not advertise sdr_monitor."}"#
            }
            var toolArgs: [String: Any] = ["freq_hz": freqHz]
            if case .string(let mode)  = args["mode"]       { toolArgs["mode"] = mode }
            if case .int(let dur)      = args["duration_s"] { toolArgs["duration_s"] = dur }
            if case .string(let pri)   = args["priority"]   { toolArgs["priority"] = pri }
            // Use model-provided requesting_agent if given; otherwise identify this Nova node.
            if case .string(let agent) = args["requesting_agent"] {
                toolArgs["requesting_agent"] = agent
            } else if let selfHash = MeshAgentRegistry.shared.localDestinationHash {
                toolArgs["requesting_agent"] = selfHash
            }
            do {
                return try await router.callTool(
                    destHash: peer.destinationHash, toolName: "sdr_monitor", args: toolArgs)
            } catch LXMFToolError.timeout {
                return #"{"error":"sdr_timeout","message":"SDR node did not respond within 15 seconds."}"#
            }
        }
    }
}
