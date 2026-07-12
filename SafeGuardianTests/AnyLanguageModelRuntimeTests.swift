import Testing
import Foundation
import AgentInfra
import AnyLanguageModelKit
@testable import SafeGuardian

// Runtime verification of the AnyLanguageModel migration: loads real MLX
// weights and exercises generation plus the tool-call loop end to end.
// Requires the default model in the HuggingFace cache (downloads on first
// run). Serialized so the weights load once and stay warm across tests.
@Suite("AnyLanguageModelRuntime", .serialized)
@MainActor
struct AnyLanguageModelRuntimeTests {

    /// Generation through the real provider path: MLXInferenceService.generate
    /// with a per-thread session, streaming deltas back as events.
    @Test func mlxServiceGeneratesText() async throws {
        let service = MLXInferenceService.shared
        let input = AgentPromptInput(
            text: "Reply with exactly one word: pong",
            systemPrompt: "You are a test agent. Follow instructions exactly."
        )
        var collected = ""
        var completed = false
        var failure: String?
        for await event in service.generate(input: input) {
            switch event {
            case .token(let t): collected += t
            case .complete: completed = true
            case .failure(let message): failure = message
            default: break
            }
        }
        #expect(failure == nil)
        #expect(completed)
        #expect(!collected.isEmpty)
    }

    /// Tool calling end to end: an AgentToolRegistry-backed tool bridged via
    /// asLanguageModelTools() must be invoked by the model inside the session's
    /// resolution loop, and its result must inform the final answer.
    @Test func mlxToolCallRoundTrip() async throws {
        final class Sentinel: @unchecked Sendable {
            var calledTool: String?
        }
        let sentinel = Sentinel()
        let spec = makeToolSpec(
            name: "get_beacon_code",
            description: "Returns the current beacon code. This is the only way to learn the beacon code.",
            parameters: []
        )
        let registry = AgentToolRegistry(
            specs: [spec],
            dispatch: { call in
                sentinel.calledTool = call.function.name
                return #"{"beacon_code":"ZULU-7"}"#
            },
            taskRecord: AgentTaskRecord()
        )
        let tools = registry.asLanguageModelTools()
        #expect(tools.count == 1)

        let session = LanguageModelSession(
            model: MLXInferenceService.shared.model,
            tools: tools,
            instructions: "You are a test agent with one tool, get_beacon_code. Use it whenever the beacon code is needed."
        )
        let response = try await session.respond(
            to: "Call the get_beacon_code tool and report the beacon code it returns."
        )
        #expect(sentinel.calledTool == "get_beacon_code")
        #expect(response.content.contains("ZULU-7") || response.content.lowercased().contains("zulu"))
    }
}

// Runtime probe for the Apple Intelligence path. Skips (with a recorded
// comment) on machines where the system model is unavailable, since that
// depends on OS version and the Apple Intelligence opt-in.
@Suite("FoundationModelRuntime")
@MainActor
struct FoundationModelRuntimeTests {
    @available(macOS 26, *)
    @Test func systemModelRespondsIfAvailable() async throws {
        guard FoundationModelProvider.isAvailable() else {
            withKnownIssue("Apple Intelligence unavailable on this machine — path not exercised") {
                #expect(Bool(false))
            }
            return
        }
        let corrected = try await FoundationModelProvider.cleanUpTranscript("teh quick brwon fox")
        #expect(!corrected.isEmpty)
    }
}
