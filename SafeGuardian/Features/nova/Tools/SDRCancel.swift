import Foundation
import MLXLMCommon

extension AgentToolEntry {
    static func sdrCancel() -> AgentToolEntry {
        make(
            name: "sdr_cancel",
            description: "Cancel an active SDR monitoring reservation by token.",
            parameters: [
                .required("reservation_token", type: .string,
                          description: "Token returned by sdr_monitor when the reservation was created."),
            ]
        ) { args, _ in
            guard case .string(let token) = args["reservation_token"] else {
                return #"{"error":"reservation_token is required"}"#
            }
            guard let peer = MeshAgentRegistry.shared.agent(type: "sdr"),
                  let router = MeshAgentRegistry.shared.toolRouter else {
                return #"{"error":"sdr_agent_unavailable","message":"No SDR node detected on the mesh."}"#
            }
            guard !peer.rejectsTool("sdr_cancel") else {
                return #"{"error":"sdr_capability_unavailable","message":"Detected SDR node does not advertise sdr_cancel."}"#
            }
            do {
                return try await router.callTool(
                    destHash: peer.destinationHash, toolName: "sdr_cancel",
                    args: ["reservation_token": token])
            } catch LXMFToolError.timeout {
                return #"{"error":"sdr_timeout","message":"SDR node did not respond within 15 seconds."}"#
            }
        }
    }
}
