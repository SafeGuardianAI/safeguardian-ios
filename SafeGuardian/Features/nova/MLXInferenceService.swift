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

    var isModelLoaded: Bool {
        container != nil
    }

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

    private func log(_ message: String) {
        let timestamp = Date().description
        let logLine = "[MLX] [\(timestamp)] \(message)\n"
        print(logLine) // Console
        
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let logPath = paths[0].appendingPathComponent("chat.safeguardian").appendingPathComponent("tui.log").path
        
        if let data = logLine.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: data)
            } else if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }

    func generate(
        systemPrompt: String? = nil,
        history: [Chat.Message] = [],
        userMessage: String,
        onStatus: @escaping @Sendable (String) -> Void,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        let modelID = activeModelID
        log("[Generate] Starting for prompt: \(userMessage.prefix(30))...")
        
        activeTask?.cancel()
        
        activeTask = Task {
            log("[Generate] Task started.")
            do {
                if container == nil {
                    isLoading = true
                    downloadProgress = 0
                    onStatus("[initializing...]")
                    log("Initializing model container...")
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
                    log("Model loaded successfully.")
                }
                
                if session == nil || (systemPrompt != nil && systemPrompt != lastSystemPrompt) {
                    onStatus("[starting session...]")
                    log("Starting new session. History turns: \(history.count)")
                    lastSystemPrompt = systemPrompt
                    if let container {
                        session = ChatSession(
                            container,
                            instructions: systemPrompt,
                            history: history,
                            generateParameters: GenerateParameters(temperature: 0.7)
                        )
                    }
                }

                guard let session, !Task.isCancelled else { 
                    log("Session or task cancelled.")
                    return 
                }
                
                if userMessage.isEmpty {
                    onStatus("[error: empty prompt]")
                    onComplete()
                    return
                }

                onStatus("[thinking...]")
                log("Streaming response for prompt: \(userMessage)")
                
                // Add a timeout for the first token
                let stream = session.streamResponse(to: userMessage)
                var iterator = stream.makeAsyncIterator()
                
                while !Task.isCancelled {
                    let next = try await withThrowingTaskGroup(of: String?.self) { group in
                        group.addTask {
                            return try await iterator.next()
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 30 * 1_000_000_000) // 30s timeout
                            throw NSError(domain: "Nova", code: 408, userInfo: [NSLocalizedDescriptionKey: "inference timed out"])
                        }
                        let first = try await group.next()
                        group.cancelAll()
                        return first ?? nil
                    }
                    
                    guard let token = next else { 
                        log("Stream completed.")
                        break 
                    }
                    onToken(token)
                }
            } catch {
                log("Nova Error: \(error.localizedDescription)")
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
