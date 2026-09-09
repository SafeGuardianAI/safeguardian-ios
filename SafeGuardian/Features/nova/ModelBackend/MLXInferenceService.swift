import AgentRuntime
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
        NovaConfig.bundledModelID,
        "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
    ]

    /// Resolves the bundled model's snapshot directory under Resources/Models,
    /// mirroring MLXVLMBackend.bundledModelDirectories() — one subdirectory
    /// containing a config.json, shipped in the app bundle so no download is
    /// ever required for this model.
    static func bundledModelDirectory() -> URL? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Models"),
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return nil }
        return entries.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path)
        }
    }

    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0
    // Per-thread LanguageModelSession cache; see MLXInferenceService+Generate.swift.
    var sessions: [String: LanguageModelSession] = [:]
    // The wrapping Task around the current streamResponse call — there is exactly one
    // on-device model, so only one of these is ever meaningful at a time. cancel() stops
    // this; AgentConversationEngine awaits its own copy of the equivalent task before
    // starting a new turn, so a stop is never racing a fresh generate() call.
    private var activeGenerationTask: Task<Void, Never>?

    var isModelLoaded: Bool {
        if case .available = model.availability { return true }
        return false
    }

    var model: MLXLanguageModel {
        if activeModelID == NovaConfig.bundledModelID, let dir = Self.bundledModelDirectory() {
            return MLXLanguageModel(modelId: activeModelID, directory: dir)
        }
        return MLXLanguageModel(modelId: activeModelID)
    }

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

    /// Cancels the in-flight generation, if any. AgentProviderStreaming.drain() checks
    /// Task.checkCancellation() on every token and finishes the stream silently rather
    /// than throwing, so AgentConversationEngine's for-await loop over generate() simply
    /// ends — no .complete, no .failure — which is how it tells a stop apart from a
    /// normal finish or a real error.
    func cancel() {
        activeGenerationTask?.cancel()
    }

    // MARK: - Prefetch (first-run onboarding)

    /// True when the active model's files are already on disk. The bundled model
    /// ships inside the app itself, so it's always considered present.
    var isActiveModelCached: Bool {
        if activeModelID == NovaConfig.bundledModelID { return Self.bundledModelDirectory() != nil }
        return ModelDownloadManager.shared.localSnapshotURL(modelID: activeModelID) != nil
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
        let options = generationOptions(for: activeModelID)
        isLoading = true
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                await AgentProviderStreaming.drain(
                    session.streamResponse(to: text, options: options), into: continuation,
                    onFirstToken: { [weak self] in Task { @MainActor in self?.isLoading = false } }
                )
                continuation.finish()
            }
            activeGenerationTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Builds real sampling options from GenerationSettingsStore instead of letting every
    /// call fall through to the library's own unconfigured defaults. maximumResponseTokens
    /// is only set when the user has explicitly dialed it down; the model's own context
    /// window (contextWindowSize, from its real config.json) is the ceiling that dial
    /// clamps against, never something this app raises past what the model file supports.
    private func generationOptions(for modelID: String) -> GenerationOptions {
        let contextWindow = ModelDownloadManager.shared.contextWindowSize(modelID: modelID)
        return GenerationOptions(
            temperature: GenerationSettingsStore.shared.temperature(for: modelID),
            maximumResponseTokens: GenerationSettingsStore.shared.maxResponseTokens(
                for: modelID, contextWindow: contextWindow
            )
        )
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
            let bytesPerToken = PromptBudgetService.bytesPerToken(modelID: activeModelID) ?? ContextCompressor.defaultBytesPerToken
            guard ContextCompressor.shouldCompact(turns, threshold: NovaConfig.contextCompactionThreshold, bytesPerToken: bytesPerToken) else {
                return existing
            }
            let compacted = ContextCompressor.compactIfNeeded(
                turns, threshold: NovaConfig.contextCompactionThreshold, bytesPerToken: bytesPerToken
            )
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
