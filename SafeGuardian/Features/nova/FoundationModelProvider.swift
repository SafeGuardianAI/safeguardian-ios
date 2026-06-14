// FoundationModelProvider.swift
// SafeGuardian
//
// macOS 26+ only. Wraps LanguageModelSession as an AgentLanguageProvider
// so the provider registry can offer on-device Foundation Models inference
// as a fallback when MLX is unavailable or Apple Intelligence is preferred.
//
// Foundation Models context window: 4096 tokens (~12 KB). ContextCompressor
// runs in AgentConversationEngine before history reaches this provider, so
// overflow is unlikely in practice, but the model will raise a context error
// if it occurs and the failure event propagates cleanly.

#if os(macOS)
import AgentInfra
import Foundation
import FoundationModels

@available(macOS 26, *)
@Observable @MainActor
final class FoundationModelProvider: AgentLanguageProvider {
    static let shared = FoundationModelProvider()

    // V2 suffix prevents a stale UserDefaults true from prior installs enabling
    // the provider before the user explicitly opts in on a fresh run.
    static let enabledKey = "foundationModelProviderEnabledV2"

    private init() {}

    var id: String { "foundation-models" }
    var displayName: String { "Apple Intelligence" }
    var activeModelID: String { "apple/on-device" }
    var isLoading: Bool = false

    var isModelLoaded: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var capabilities: AgentProviderCapabilities {
        AgentProviderCapabilities(
            requiresNetwork: false,
            modelCapabilities: ModelCapabilities(
                hasThinkingMode: false,
                noThinkSuffix: nil,
                supportsToolCalling: false,
                supportsVision: false
            )
        )
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func isAvailable() -> Bool {
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        return false
    }

    private var currentTask: Task<Void, Never>?

    func generate(input: AgentPromptInput) -> AsyncStream<AgentGenerationEvent> {
        let systemPrompt = input.systemPrompt
        let prompt = Self.buildPrompt(from: input)
        // Ensure budget service knows the Foundation Models context window before
        // the engine calls recommendedTurnCount for this model ID.
        Task { await PromptBudgetService.shared.register(modelID: self.activeModelID) }
        return AsyncStream { continuation in
            self.currentTask = Task {
                let session = LanguageModelSession(instructions: systemPrompt)
                do {
                    // Dual-task race: inference vs. 30-second timeout.
                    let content = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask { try await session.respond(to: prompt).content }
                        group.addTask {
                            try await Task.sleep(for: .seconds(30))
                            throw CancellationError()
                        }
                        guard let result = try await group.next() else { throw CancellationError() }
                        group.cancelAll()
                        return result
                    }
                    continuation.yield(.token(content))
                    continuation.yield(.complete)
                } catch is CancellationError {
                    continuation.yield(.failure("cancelled"))
                } catch {
                    continuation.yield(.failure(error.localizedDescription))
                }
                continuation.finish()
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Flattens history + current message into a single prompt string.
    /// Foundation Models sessions retain transcript automatically, but since
    /// AgentPromptInput carries pre-assembled history we use a single-turn
    /// format to avoid replaying prior turns through inference.
    static func buildPrompt(from input: AgentPromptInput) -> String {
        var parts: [String] = []
        for turn in input.history {
            let label = turn.role == .user ? "User" : "Assistant"
            parts.append("\(label): \(turn.content)")
        }
        parts.append("User: \(input.decorated(modelID: "apple/on-device"))")
        return parts.joined(separator: "\n\n")
    }

    /// Spell-correct a raw ASR transcript. Useful after Whisper produces
    /// phonetically plausible but lexically incorrect output in noisy field
    /// conditions. Runs a fresh session so it does not pollute agent history.
    static func cleanUpTranscript(_ text: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: "Fix spelling and grammar only. Return exactly the corrected text with no commentary."
        )
        return try await session.respond(to: text).content
    }
}
#endif
