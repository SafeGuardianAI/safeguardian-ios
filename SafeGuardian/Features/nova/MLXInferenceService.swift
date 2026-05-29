import Foundation
import MLXLMCommon

@Observable @MainActor
final class MLXInferenceService: AgentLanguageProvider {
    static let shared = MLXInferenceService()

    let id = "mlx"
    let displayName = "MLX (on-device)"
    let capabilities = AgentProviderCapabilities(requiresNetwork: false)

    static let defaultModelID = NovaConfig.defaultModelID
    private static let activeModelKey = "nova.activeModelID"
    private static let savedModelsKey  = "nova.savedModelIDs"

    private let loader: MLXModelLoader
    let coordinator: MLXInferenceCoordinator

    var isLoading: Bool { loader.isLoading }
    var downloadProgress: Double { loader.downloadProgress }
    var isModelLoaded: Bool { loader.isLoaded }

    private(set) var savedModelIDs: [String] {
        didSet { UserDefaults.standard.set(savedModelIDs, forKey: Self.savedModelsKey) }
    }
    private(set) var activeModelID: String {
        didSet { UserDefaults.standard.set(activeModelID, forKey: Self.activeModelKey) }
    }

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.savedModelsKey) ?? []
        let initialSaved = stored.isEmpty ? [Self.defaultModelID] : stored
        let active = UserDefaults.standard.string(forKey: Self.activeModelKey) ?? Self.defaultModelID
        let l = MLXModelLoader()
        loader = l
        coordinator = MLXInferenceCoordinator(loader: l)
        savedModelIDs = initialSaved
        activeModelID = initialSaved.contains(active) ? active : Self.defaultModelID
    }

    // MARK: - Inference

    func generate(input: AgentPromptInput) -> AsyncStream<AgentGenerationEvent> {
        coordinator.generate(modelID: activeModelID, input: input)
    }

    func cancel() { coordinator.cancel() }

    func dropSession() {
        coordinator.cancelAndClearSessions()
        loader.invalidate()
    }

    // MARK: - Model management

    func selectModel(_ id: String) {
        guard id != activeModelID else { return }
        activeModelID = id
        coordinator.cancelAndClearSessions()
        loader.invalidate()
    }

    func addModel(_ id: String) {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !savedModelIDs.contains(t) else { return }
        savedModelIDs.append(t)
    }

    func removeModel(_ id: String) {
        guard id != Self.defaultModelID else { return }
        savedModelIDs.removeAll { $0 == id }
        if activeModelID == id { selectModel(Self.defaultModelID) }
    }
}
