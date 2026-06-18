import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func sdrScan() -> AgentToolEntry {
        make(
            name: "sdr_scan",
            description: "Scan a list of frequencies for signal activity using the SDR node on the mesh. " +
                         "Returns detected signals, power levels, and modulation estimates.",
            parameters: [
                .required("freq_list", type: .array(elementType: .double),
                          description: "List of frequencies to scan in Hz, e.g. [162550000, 156800000]."),
                .optional("dwell_ms", type: .int,
                          description: "Dwell time per frequency in milliseconds. Default 500."),
            ]
        ) { args, _ in
            guard case .array(let freqArray) = args["freq_list"], !freqArray.isEmpty else {
                return #"{"error":"freq_list is required and must be a non-empty array"}"#
            }
            guard let peer = MeshAgentRegistry.shared.agent(type: "sdr"),
                  let router = MeshAgentRegistry.shared.toolRouter else {
                return #"{"error":"sdr_agent_unavailable","message":"No SDR node detected on the mesh."}"#
            }
            guard !peer.rejectsTool("sdr_scan") else {
                return #"{"error":"sdr_capability_unavailable","message":"Detected SDR node does not advertise sdr_scan."}"#
            }
            var toolArgs: [String: Any] = ["freq_list": freqArray.map { $0.anyValue }]
            if case .int(let ms) = args["dwell_ms"] { toolArgs["dwell_ms"] = ms }
            do {
                return try await router.callTool(
                    destHash: peer.destinationHash, toolName: "sdr_scan", args: toolArgs)
            } catch LXMFToolError.timeout {
                return #"{"error":"sdr_timeout","message":"SDR node did not respond within 15 seconds."}"#
            }
        }
    }
}
