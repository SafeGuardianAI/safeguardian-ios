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
        tick: NovaStateTick?,
        onStatus: @escaping @Sendable (String) -> Void,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        guard !pendingRelease else { onStatus("[model releasing]"); onComplete(); return }
        activeTask?.cancel()
        rescheduleIdleTimer()
        let decorated = decoratePrompt(prompt, tick: tick)
        let key = NovaSessionPool.Key(
            modelID: modelID,
            promptHash: NovaConfig.stableSystemPrompt.hashValue
        )
        activeTask = Task {
            do {
                onStatus("[initializing...]")
                let model = try await loader.container(modelID: modelID) { progress in
                    onStatus("[downloading: \(Int(progress * 100))%]")
                }
                guard !Task.isCancelled else { onComplete(); return }

                let session = sessionPool.session(
                    for: key, container: model, systemPrompt: NovaConfig.stableSystemPrompt
                )
                guard !decorated.isEmpty, !Task.isCancelled else {
                    onStatus("[error: empty prompt]"); onComplete(); return
                }
                onStatus("[thinking...]")
                let stream = session.streamResponse(to: decorated)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await token in stream {
                            guard !Task.isCancelled else { break }
                            onToken(token)
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
            } catch {
                log("Error: \(error.localizedDescription)")
                onStatus("[error: \(error.localizedDescription)]")
            }
            onComplete()
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

    private func decoratePrompt(_ prompt: String, tick: NovaStateTick?) -> String {
        // /no_think suppresses Qwen3 chain-of-thought blocks; without it every turn
        // after the first enters thinking mode and the visible output is empty.
        let noThink = " /no_think"
        guard let tick else { return prompt + noThink }
        let battery = Int(tick.batteryPct * 100)
        let loc = String(format: "%.4f,%.4f", tick.lat, tick.lon)
        return "[state: battery \(battery)%, loc \(loc), \(tick.peerCount) peers] \(prompt)\(noThink)"
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
