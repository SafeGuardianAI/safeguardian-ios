import Foundation
import MLXLMCommon

@Observable @MainActor
final class MLXInferenceService {
    static let shared = MLXInferenceService()

    static let defaultModelID = NovaConfig.defaultModelID
    private static let activeModelKey = "nova.activeModelID"
    private static let savedModelsKey  = "nova.savedModelIDs"

    private let loader = MLXModelLoader()

    var isLoading: Bool { loader.isLoading }
    var downloadProgress: Double { loader.downloadProgress }

    private(set) var savedModelIDs: [String] {
        didSet { UserDefaults.standard.set(savedModelIDs, forKey: Self.savedModelsKey) }
    }
    private(set) var activeModelID: String {
        didSet { UserDefaults.standard.set(activeModelID, forKey: Self.activeModelKey) }
    }

    private var session: ChatSession?
    private var activeTask: Task<Void, Never>?
    private var lastSystemPrompt: String?

    var isModelLoaded: Bool { loader.isLoaded }

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.savedModelsKey) ?? []
        savedModelIDs = stored.isEmpty ? [Self.defaultModelID] : stored
        let active = UserDefaults.standard.string(forKey: Self.activeModelKey) ?? Self.defaultModelID
        activeModelID = savedModelIDs.contains(active) ? active : Self.defaultModelID
    }

    // MARK: - Model management

    func selectModel(_ id: String) {
        guard id != activeModelID else { return }
        activeModelID = id
        dropSession()
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

    // MARK: - Inference

    func generate(
        systemPrompt: String? = nil,
        history: [Chat.Message] = [],
        userMessage: String,
        onStatus: @escaping @Sendable (String) -> Void,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        activeTask?.cancel()
        let modelID = activeModelID
        activeTask = Task {
            log("Starting: \(userMessage.prefix(30))")
            do {
                onStatus("[initializing...]")
                // Local strong ref: keeps ModelContainer alive even if selectModel() fires
                // mid-task and drops loader.state. Prevents the scheduler teardown race
                // that caused SIGSEGV in mlx::core::detail::CompilerCache::find.
                let model = try await loader.container(modelID: modelID) { _ in }
                log("Container ready.")

                if session == nil || (systemPrompt != nil && systemPrompt != lastSystemPrompt) {
                    lastSystemPrompt = systemPrompt
                    session = ChatSession(
                        model,
                        instructions: systemPrompt,
                        history: history,
                        generateParameters: GenerateParameters(temperature: NovaConfig.temperature)
                    )
                    log("New session, \(history.count) history turns.")
                }

                // Local ref: prevents session = nil from dropping it mid-stream.
                guard let localSession = session, !Task.isCancelled else { onComplete(); return }
                guard !userMessage.isEmpty else { onStatus("[error: empty prompt]"); onComplete(); return }

                onStatus("[thinking...]")
                let stream = localSession.streamResponse(to: userMessage)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await token in stream {
                            guard !Task.isCancelled else { break }
                            onToken(token)
                        }
                        await self.log("Stream complete.")
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: NovaConfig.generationTimeoutSeconds * 1_000_000_000)
                        throw NSError(domain: "Nova", code: 408,
                                      userInfo: [NSLocalizedDescriptionKey: "inference timed out"])
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch {
                log("Error: \(error.localizedDescription)")
                onStatus("[error: \(error.localizedDescription)]")
            }
            onComplete()
        }
    }

    func cancel() { activeTask?.cancel() }

    func dropSession() {
        activeTask?.cancel()
        session = nil
        lastSystemPrompt = nil
    }

    private func log(_ message: String) {
        let line = "[MLX] [\(Date())] \(message)\n"
        print(line)
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat.safeguardian/tui.log")
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else { try? data.write(to: url) }
    }
}
