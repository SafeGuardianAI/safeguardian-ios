import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

@Observable @MainActor
final class MLXInferenceService {
    static let shared = MLXInferenceService()
    private init() {}

    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0

    private let modelConfig = LLMRegistry.qwen3_0_6b_4bit
    private var container: ModelContainer?
    private var session: ChatSession?
    private var activeTask: Task<Void, Never>?

    func generate(
        systemPrompt: String? = nil,
        userMessage: String,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        activeTask?.cancel()
        activeTask = Task {
            do {
                if container == nil {
                    isLoading = true
                    downloadProgress = 0
                    Memory.cacheLimit = 20 * 1024 * 1024
                    let downloader = #hubDownloader()
                    let loader = #huggingFaceTokenizerLoader()
                    let loaded = try await LLMModelFactory.shared.loadContainer(
                        from: downloader,
                        using: loader,
                        configuration: modelConfig
                    ) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.downloadProgress = progress.fractionCompleted
                        }
                    }
                    isLoading = false
                    container = loaded
                    session = ChatSession(
                        loaded,
                        instructions: systemPrompt,
                        generateParameters: GenerateParameters(temperature: 0.7)
                    )
                }
                guard let session, !Task.isCancelled else { return }
                for try await token in session.streamResponse(to: userMessage) {
                    onToken(token)
                    if Task.isCancelled { break }
                }
            } catch {
                // errors surface as incomplete responses; ChatViewModel handles display
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
