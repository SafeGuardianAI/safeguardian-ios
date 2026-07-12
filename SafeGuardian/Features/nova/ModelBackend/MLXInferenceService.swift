import AgentInfra
import AnyLanguageModelKit
import Foundation

@Observable @MainActor
final class MLXInferenceService: AgentLanguageProvider {
    static let shared = MLXInferenceService()

    let id = "mlx"
    let displayName = "MLX (on-device)"
    var capabilities: AgentProviderCapabilities {
        AgentProviderCapabilities(
            requiresNetwork: false,
            modelCapabilities: NovaConfig.capabilities(for: activeModelID)
        )
    }

    static let defaultModelID = NovaConfig.defaultModelID
    private static let activeModelKey = "nova.activeModelID"
    private static let savedModelsKey  = "nova.savedModelIDs"

    // Models always present in the saved list regardless of UserDefaults state.
    // Order determines the order they appear in the picker on first install.
    private static let builtinModelIDs: [String] = [
        "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
    ]

    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0
    // Per-thread LanguageModelSession cache; see MLXInferenceService+Generate.swift.
    var sessions: [String: LanguageModelSession] = [:]

    var isModelLoaded: Bool {
        if case .available = model.availability { return true }
        return false
    }

    var model: MLXLanguageModel { MLXLanguageModel(modelId: activeModelID) }

    private(set) var savedModelIDs: [String] {
        didSet { UserDefaults.standard.set(savedModelIDs, forKey: Self.savedModelsKey) }
    }
    private(set) var activeModelID: String {
        didSet {
            UserDefaults.standard.set(activeModelID, forKey: Self.activeModelKey)
            sessions.removeAll()
        }
    }

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.savedModelsKey) ?? []
        // Merge builtins so new models added here appear for existing installs.
        var merged = stored.isEmpty ? Self.builtinModelIDs : stored
        for id in Self.builtinModelIDs where !merged.contains(id) { merged.append(id) }
        let active = UserDefaults.standard.string(forKey: Self.activeModelKey) ?? Self.defaultModelID
        savedModelIDs = merged
        activeModelID = merged.contains(active) ? active : Self.defaultModelID
    }

    func cancel() {}

    // MARK: - Prefetch (first-run onboarding)

    /// True when the active model's files are already on disk.
    var isActiveModelCached: Bool {
        ModelDownloadManager.shared.localSnapshotURL(modelID: activeModelID) != nil
    }

    /// Downloads the active model without keeping a session around, using a throwaway
    /// prompt so AnyLanguageModel's own downloader populates the Hub cache.
    func prefetchActiveModel(onProgress: @escaping (Double) -> Void) async throws {
        isLoading = true
        defer { isLoading = false }
        let session = LanguageModelSession(model: model)
        _ = try await session.respond(to: " ")
        onProgress(1.0)
    }

    // MARK: - Model management

    func selectModel(_ id: String) {
        guard id != activeModelID else { return }
        activeModelID = id
    }

    func addModel(_ id: String) {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !savedModelIDs.contains(t) else { return }
        savedModelIDs.append(t)
    }

    func removeModel(_ id: String) {
        guard id != Self.defaultModelID else { return }
        if activeModelID == id { selectModel(Self.defaultModelID) }
        savedModelIDs.removeAll { $0 == id }
        try? ModelDownloadManager.shared.evict(modelID: id)
    }

    func dropSession() {
        sessions.removeAll()
        Task { await MLXLanguageModel.removeAllFromCache() }
    }

    // MARK: - Generation

    func generate(input: AgentPromptInput) -> AsyncStream<AgentGenerationEvent> {
        let tools = (input.toolRegistry as? AgentToolRegistry)?.asLanguageModelTools() ?? []
        let session = sessionFor(threadID: input.threadID, systemPrompt: input.systemPrompt, history: input.history, tools: tools)
        let text = input.decorated(modelID: activeModelID)
        isLoading = true
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                await AgentProviderStreaming.drain(
                    session.streamResponse(to: text), into: continuation,
                    onFirstToken: { [weak self] in Task { @MainActor in self?.isLoading = false } }
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns the cached session for a thread, seeding a fresh one from `history`
    /// and `tools` on first use. Subsequent turns append to the session's own
    /// transcript, so `history` is only consulted the first time a thread is
    /// touched this launch; a tool set is fixed for the life of the session.
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
                model: model, tools: tools,
                transcript: .seeded(systemPrompt: systemPrompt, history: compacted)
            )
            sessions[threadID] = session
            return session
        }
        let session = LanguageModelSession(
            model: model, tools: tools,
            transcript: .seeded(systemPrompt: systemPrompt, history: history)
        )
        sessions[threadID] = session
        return session
    }
}
