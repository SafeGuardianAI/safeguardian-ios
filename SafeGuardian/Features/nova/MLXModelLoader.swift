import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
@preconcurrency import Tokenizers

/// Loads and caches a ModelContainer using a state machine that prevents double-loads.
/// Two concurrent callers during .loading share the same Task rather than starting separate loads.
@MainActor final class MLXModelLoader {
    enum State {
        case idle
        case loading(Task<ModelContainer, Error>)
        case loaded(ModelContainer)
    }

    private(set) var state = State.idle
    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0

    var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    func container(modelID: String, onProgress: @escaping (Double) -> Void) async throws -> ModelContainer {
        switch state {
        case .loaded(let model):
            return model
        case .loading(let task):
            return try await task.value
        case .idle:
            let task = Task<ModelContainer, Error> {
                try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: ModelConfiguration(id: modelID)
                ) { [weak self] p in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = p.fractionCompleted
                        onProgress(p.fractionCompleted)
                    }
                }
            }
            state = .loading(task)
            isLoading = true
            do {
                let model = try await task.value
                state = .loaded(model)
                isLoading = false
                return model
            } catch {
                state = .idle
                isLoading = false
                throw error
            }
        }
    }

    func invalidate() {
        state = .idle
    }
}
