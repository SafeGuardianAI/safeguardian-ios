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
import AnyLanguageModelKit
import Foundation

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
                supportsToolCalling: true,
                supportsVision: false
            )
        )
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func isAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private var currentTask: Task<Void, Never>?

    // Per-thread LanguageModelSession cache, same pattern as MLXInferenceService:
    // transcript is seeded once from history, then the session carries state itself.
    private var sessions: [String: LanguageModelSession] = [:]

    private func sessionFor(
        threadID: String, systemPrompt: String, history: [ConversationTurn], tools: [any AnyLanguageModelKit.Tool]
    ) -> LanguageModelSession {
        if let existing = sessions[threadID] {
            let turns = existing.transcript.conversationTurns
            guard ContextCompressor.shouldCompact(turns, threshold: NovaConfig.contextCompactionThreshold) else {
                return existing
            }
            let compacted = ContextCompressor.compactIfNeeded(turns, threshold: NovaConfig.contextCompactionThreshold)
            let session = LanguageModelSession(
                model: SystemLanguageModel.default, tools: tools,
                transcript: .seeded(systemPrompt: systemPrompt, history: compacted)
            )
            sessions[threadID] = session
            return session
        }
        let session = LanguageModelSession(
            model: SystemLanguageModel.default, tools: tools,
            transcript: .seeded(systemPrompt: systemPrompt, history: history)
        )
        sessions[threadID] = session
        return session
    }

    func generate(input: AgentPromptInput) -> AsyncStream<AgentGenerationEvent> {
        let tools = (input.toolRegistry as? AgentToolRegistry)?.asLanguageModelTools() ?? []
        let session = sessionFor(
            threadID: input.threadID, systemPrompt: input.systemPrompt, history: input.history, tools: tools
        )
        let text = input.decorated(modelID: activeModelID)
        // Ensure budget service knows the Foundation Models context window before
        // the engine calls recommendedTurnCount for this model ID.
        Task { await PromptBudgetService.shared.register(modelID: self.activeModelID) }
        return AsyncStream { continuation in
            self.currentTask = Task {
                await AgentProviderStreaming.drain(session.streamResponse(to: text), into: continuation)
                continuation.finish()
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Spell-correct a raw ASR transcript. Useful after Whisper produces
    /// phonetically plausible but lexically incorrect output in noisy field
    /// conditions. Runs a fresh session so it does not pollute agent history.
    static func cleanUpTranscript(_ text: String) async throws -> String {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: "Fix spelling and grammar only. Return exactly the corrected text with no commentary."
        )
        return try await session.respond(to: text).content
    }
}
#endif
