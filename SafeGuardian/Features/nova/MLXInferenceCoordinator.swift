import Foundation
import MLX
import MLXLMCommon

@MainActor final class MLXInferenceCoordinator {
    private let loader: MLXModelLoader
    private let sessionPool = MLXSessionPool()
    private var activeTask: Task<Void, Never>?
    private var pendingRelease = false
    private var idleWork: DispatchWorkItem?

    var isLoading: Bool { loader.isLoading }
    var downloadProgress: Double { loader.downloadProgress }
    var isModelLoaded: Bool { loader.isLoaded }

    init(loader: MLXModelLoader) {
        self.loader = loader
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let limitGB = max(1, min(totalGB / 10, 4))
        MLX.GPU.set(cacheLimit: limitGB * 1_073_741_824)
    }

    func generate(
        modelID: String,
        input: AgentPromptInput
    ) -> AsyncStream<AgentGenerationEvent> {
        if pendingRelease {
            return AsyncStream { c in c.yield(.status("[model releasing]")); c.finish() }
        }
        activeTask?.cancel()
        rescheduleIdleTimer()
        let decorated = input.decorated(modelID: modelID)
        // historyOffset encodes how far the window has slid: when it changes,
        // the pool creates a new ChatSession seeded from the windowed history.
        let historyOffset = max(0, input.history.count - NovaConfig.historyWindowSize)
        let key = MLXSessionPool.Key(
            modelID: modelID,
            promptHash: input.systemPrompt.hashValue,
            historyOffset: historyOffset
        )
        let chatHistory: [Chat.Message] = input.history.map {
            $0.role == .assistant ? .assistant($0.content) : .user($0.content)
        }
        return AsyncStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("[initializing...]"))
                    let dm = await MainActor.run { ModelDownloadManager.shared }
                    let isCached = await MainActor.run { dm.cachedSize(modelID: modelID) != nil }
                    if !isCached {
                        let hasSpace = await MainActor.run { dm.hasStorageForDownload(modelID: modelID) }
                        if !hasSpace {
                            let needed = await MainActor.run { dm.patternEstimate(modelID: modelID) }
                            let avail = DeviceMetrics.availableStorageBytes()
                            let neededGB = String(format: "%.1f", Double(needed) / 1_073_741_824)
                            let availGB = String(format: "%.1f", Double(avail) / 1_073_741_824)
                            continuation.yield(.failure("not enough storage: need ~\(neededGB) GB, \(availGB) GB free"))
                            continuation.finish()
                            return
                        }
                    }
                    let model = try await loader.container(modelID: modelID) { progress in
                        continuation.yield(.status("[downloading: \(Int(progress * 100))%]"))
                    }
                    guard !Task.isCancelled else { continuation.finish(); return }
                    let session = sessionPool.session(
                        for: key, container: model, systemPrompt: input.systemPrompt,
                        history: chatHistory, toolRegistry: input.toolRegistry
                    )
                    guard !decorated.isEmpty, !Task.isCancelled else {
                        continuation.yield(.status("[error: empty prompt]"))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.status("[thinking...]"))
                    let stream = session.streamDetails(to: decorated, images: [], videos: [])
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await generation in stream {
                                guard !Task.isCancelled else { break }
                                switch generation {
                                case .chunk(let text):
                                    continuation.yield(.token(text))
                                case .info(let info):
                                    continuation.yield(.stats(AgentGenerationStats(
                                        promptTokens: info.promptTokenCount,
                                        generationTokens: info.generationTokenCount,
                                        promptMs: info.promptTime * 1000,
                                        generateMs: info.generateTime * 1000
                                    )))
                                case .toolCall:
                                    break
                                }
                            }
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: NovaConfig.generationTimeoutSeconds * 1_000_000_000)
                            throw NSError(domain: "Nova", code: 408,
                                          userInfo: [NSLocalizedDescriptionKey: "inference timed out"])
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                    continuation.yield(.complete)
                } catch {
                    log("Error: \(error.localizedDescription)")
                    continuation.yield(.failure(error.localizedDescription))
                }
                continuation.finish()
            }
            activeTask = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancel() { activeTask?.cancel() }

    func cancelAndClearSessions() {
        activeTask?.cancel()
        sessionPool.invalidateAll()
    }

    func releaseModel() async {
        pendingRelease = true
        idleWork?.cancel()
        activeTask?.cancel()
        await activeTask?.value
        pendingRelease = false
        sessionPool.invalidateAll()
        loader.invalidate()
        log("Model released (idle timeout).")
    }

    private func rescheduleIdleTimer() {
        idleWork?.cancel()
        idleWork = DispatchWorkItem { [weak self] in
            Task { await self?.releaseModel() }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NovaConfig.idleTimeoutSeconds,
            execute: idleWork!
        )
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
