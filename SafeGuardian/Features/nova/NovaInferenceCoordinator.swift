import Foundation
import MLX
import MLXLMCommon

@MainActor final class NovaInferenceCoordinator {
    private let loader: MLXModelLoader
    private let sessionPool = NovaSessionPool()
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
        prompt: String,
        tick: NovaStateTick?
    ) -> AsyncStream<NovaGenerationEvent> {
        if pendingRelease {
            return AsyncStream { c in c.yield(.status("[model releasing]")); c.finish() }
        }
        activeTask?.cancel()
        rescheduleIdleTimer()
        let decorated = decoratePrompt(prompt, tick: tick, modelID: modelID)
        let key = NovaSessionPool.Key(
            modelID: modelID,
            promptHash: NovaConfig.stableSystemPrompt.hashValue
        )
        return AsyncStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("[initializing...]"))
                    let model = try await loader.container(modelID: modelID) { progress in
                        continuation.yield(.status("[downloading: \(Int(progress * 100))%]"))
                    }
                    guard !Task.isCancelled else { continuation.finish(); return }
                    let session = sessionPool.session(
                        for: key, container: model, systemPrompt: NovaConfig.stableSystemPrompt
                    )
                    guard !decorated.isEmpty, !Task.isCancelled else {
                        continuation.yield(.status("[error: empty prompt]"))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.status("[thinking...]"))
                    let stream = session.streamResponse(to: decorated)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await token in stream {
                                guard !Task.isCancelled else { break }
                                continuation.yield(.token(token))
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

    private func decoratePrompt(_ prompt: String, tick: NovaStateTick?, modelID: String) -> String {
        let caps = NovaConfig.capabilities(for: modelID)
        var result = prompt
        if let tick {
            let battery = Int(tick.batteryPct * 100)
            let loc = String(format: "%.4f,%.4f", tick.lat, tick.lon)
            result = "[state: battery \(battery)%, loc \(loc), \(tick.peerCount) peers] \(result)"
        }
        if let suffix = caps.noThinkSuffix {
            result += suffix
        }
        return result
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
