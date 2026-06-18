import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func sdrTune() -> AgentToolEntry {
        make(
            name: "sdr_tune",
            description: "Tune the SDR node to a specific frequency and begin capturing. " +
                         "Use for sustained monitoring of a known channel.",
            parameters: [
                .required("freq_hz", type: .int,
                          description: "Center frequency in Hz, e.g. 162550000 for NOAA Weather Radio."),
                .optional("mode", type: .string,
                          description: "Demodulation mode: fm_voice | am | nfm | raw. Default fm_voice."),
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
            guard !peer.rejectsTool("sdr_tune") else {
                return #"{"error":"sdr_capability_unavailable","message":"Detected SDR node does not advertise sdr_tune."}"#
            }
            var toolArgs: [String: Any] = ["freq_hz": freqHz]
            if case .string(let mode) = args["mode"] { toolArgs["mode"] = mode }
            do {
                return try await router.callTool(
                    destHash: peer.destinationHash, toolName: "sdr_tune", args: toolArgs)
            } catch LXMFToolError.timeout {
                return #"{"error":"sdr_timeout","message":"SDR node did not respond within 15 seconds."}"#
            }
        }
    }
}
