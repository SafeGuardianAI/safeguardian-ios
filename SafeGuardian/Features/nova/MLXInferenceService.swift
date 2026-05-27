import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
@preconcurrency import Tokenizers

@Observable @MainActor
final class MLXInferenceService {
    static let shared = MLXInferenceService()

    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"
    private static let activeModelKey = "nova.activeModelID"
    private static let savedModelsKey  = "nova.savedModelIDs"

    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0

    // Persisted list of user-managed model IDs, always containing at least the default.
    private(set) var savedModelIDs: [String] {
        didSet { UserDefaults.standard.set(savedModelIDs, forKey: Self.savedModelsKey) }
    }

    // The model that will be used on the next generate call.
    private(set) var activeModelID: String {
        didSet { UserDefaults.standard.set(activeModelID, forKey: Self.activeModelKey) }
    }

    private var container: ModelContainer?
    private var session: ChatSession?
    private var activeTask: Task<Void, Never>?

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.savedModelsKey) ?? []
        let initialSaved = stored.isEmpty ? [Self.defaultModelID] : stored

        let active = UserDefaults.standard.string(forKey: Self.activeModelKey) ?? Self.defaultModelID
        let initialActive = initialSaved.contains(active) ? active : Self.defaultModelID
        
        self.savedModelIDs = initialSaved
        self.activeModelID = initialActive
    }

    // MARK: - Model management

    func selectModel(_ id: String) {
        guard id != activeModelID else { return }
        activeModelID = id
        resetSession()
    }

    func addModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !savedModelIDs.contains(trimmed) else { return }
        savedModelIDs.append(trimmed)
    }

    func removeModel(_ id: String) {
        guard id != Self.defaultModelID else { return }
        savedModelIDs.removeAll { $0 == id }
        if activeModelID == id {
            activeModelID = Self.defaultModelID
            resetSession()
        }
    }

    // MARK: - Inference

    private var lastSystemPrompt: String?

    func generate(
        systemPrompt: String? = nil,
        userMessage: String,
        onStatus: @escaping @Sendable (String) -> Void,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        activeTask?.cancel()
        let modelID = activeModelID
        
        activeTask = Task {
            do {
                if container == nil {
                    isLoading = true
                    downloadProgress = 0
                    onStatus("[initializing...]")
                    Memory.cacheLimit = 20 * 1024 * 1024
                    let downloader = #hubDownloader()
                    let loader = #huggingFaceTokenizerLoader()
                    let config = ModelConfiguration(id: modelID)
                    let loaded = try await LLMModelFactory.shared.loadContainer(
                        from: downloader,
                        using: loader,
                        configuration: config
                    ) { [weak self] progress in
                        let pct = Int(progress.fractionCompleted * 100)
                        onStatus("[downloading model: \(pct)%]")
                        Task { @MainActor [weak self] in
                            self?.downloadProgress = progress.fractionCompleted
                        }
                    }
                    isLoading = false
                    container = loaded
                    session = nil // Force new session for new container
                }
                
                // If system prompt changed, we must reset the session to apply new state context
                if session == nil || (systemPrompt != nil && systemPrompt != lastSystemPrompt) {
                    onStatus("[starting session...]")
                    lastSystemPrompt = systemPrompt
                    if let container {
                        session = ChatSession(
                            container,
                            instructions: systemPrompt,
                            generateParameters: GenerateParameters(temperature: 0.7)
                        )
                    }
                }

                guard let session, !Task.isCancelled else { return }
                onStatus("[thinking...]")
                for try await token in session.streamResponse(to: userMessage) {
                    // Log token to console for live tracing
                    print("Nova Token: \(token)")
                    onToken(token)
                    if Task.isCancelled { break }
                }
            } catch {
                print("Nova Error: \(error)")
                onStatus("[error: \(error.localizedDescription)]")
            }
            onComplete()
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func resetSession() {
        activeTask?.cancel()
        session = nil
        container = nil
    }
}
