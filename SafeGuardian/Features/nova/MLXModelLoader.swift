import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
@preconcurrency import Tokenizers

/// Loads and caches a ModelContainer using a state machine that prevents double-loads.
/// State is keyed by model ID so that a model-switch never returns a stale container.
@MainActor final class MLXModelLoader {
    enum State {
        case idle
        case loading(String, Task<ModelContainer, Error>)   // modelID, task
        case loaded(String, ModelContainer)                  // modelID, container
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
        case .loaded(let id, let model) where id == modelID:
            return model

        case .loaded:
            // Wrong model loaded — discard and reload.
            invalidate()
            return try await startLoad(modelID: modelID, onProgress: onProgress)

        case .loading(let id, let task) where id == modelID:
            return try await task.value

        case .loading(_, let task):
            // Wrong model loading — cancel it and start the right one.
            task.cancel()
            state = .idle
            return try await startLoad(modelID: modelID, onProgress: onProgress)

        case .idle:
            return try await startLoad(modelID: modelID, onProgress: onProgress)
        }
    }

    func invalidate() {
        if case .loading(_, let task) = state { task.cancel() }
        state = .idle
        isLoading = false
    }

    private func startLoad(modelID: String,
                           onProgress: @escaping (Double) -> Void) async throws -> ModelContainer {
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
        state = .loading(modelID, task)
        isLoading = true
        do {
            let model = try await task.value
            state = .loaded(modelID, model)
            isLoading = false
            return model
        } catch {
            state = .idle
            isLoading = false
            throw error
        }
    }
}
