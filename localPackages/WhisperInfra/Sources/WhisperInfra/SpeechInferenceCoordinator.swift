//
//  SpeechInferenceCoordinator.swift
//  WhisperInfra
//
//  MainActor coordinator that manages the WhisperContext lifecycle and exposes
//  AgentTranscriptionProvider to nova-ios and trek-ios. Parallel to
//  MLXInferenceCoordinator in nova-ios: same load/unload lifecycle, same
//  MainActor isolation pattern, same async/await surface.
//
//  Audio path: AVAudioEngine PCM buffers (native sample rate)
//    → downsample to 16 kHz mono Float32
//    → WhisperContext.transcribeSync (on background queue)
//    → transcript string returned to caller
//

import AgentInfra
import Foundation

@MainActor
public final class SpeechInferenceCoordinator: AgentTranscriptionProvider, ObservableObject {

    public nonisolated(unsafe) static let shared = SpeechInferenceCoordinator()
    nonisolated private init() {}

    @Published public private(set) var isReady = false
    @Published public private(set) var isLoading = false

    private var ctx: WhisperContext?
    private var loadedModelID: WhisperModelManager.ModelDescriptor?

    // MARK: - AgentTranscriptionProvider

    public func load() async throws {
        // Auto-select the best model this device can sustain at real-time latency.
        try await load(model: WhisperModelManager.shared.recommendedModel())
    }

    public func transcribe(audioSamples: [Float]) async -> String? {
        guard let ctx else { return nil }
        let start = Date()
        let text = await Task.detached(priority: .userInitiated) {
            ctx.transcribeSync(samples: audioSamples).joined(separator: " ")
        }.value
        let elapsedMs = -start.timeIntervalSinceNow * 1000
        let audioSeconds = Double(audioSamples.count) / 16_000.0

        if let modelID = loadedModelID, audioSeconds > 0.5 {
            let result = WhisperModelManager.BenchmarkResult(
                modelID: modelID.id,
                tokensPerSecond: 0,
                transcriptionMs: elapsedMs,
                audioSeconds: audioSeconds,
                realTimeFactor: elapsedMs / (audioSeconds * 1000)
            )
            WhisperModelManager.shared.recordBenchmark(result)
        }

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Model loading

    public func load(model: WhisperModelManager.ModelDescriptor) async throws {
        guard loadedModelID?.id != model.id else { return }
        isLoading = true
        isReady = false
        ctx = nil
        defer { isLoading = false }

        let manager = WhisperModelManager.shared
        if !manager.isDownloaded(model) {
            try await manager.download(model)
        }
        guard let url = manager.localURL(for: model) else {
            throw SpeechInferenceError.modelFileNotFound(model.remoteFilename)
        }

        let context = try await Task.detached(priority: .userInitiated) {
            WhisperContext(modelURL: url)
        }.value
        guard let context else {
            throw SpeechInferenceError.contextInitFailed
        }

        ctx = context
        loadedModelID = model
        isReady = true
    }

    public func unload() {
        ctx = nil
        loadedModelID = nil
        isReady = false
    }

    // MARK: - Audio format conversion

    /// Converts AVAudioEngine PCM samples at any sample rate to 16 kHz mono Float32
    /// using linear interpolation. The caller feeds the result into transcribe(audioSamples:).
    public static func downsample(_ samples: [Float], from inputRate: Double) -> [Float] {
        let targetRate = 16_000.0
        guard inputRate > 0, !samples.isEmpty else { return [] }
        if inputRate == targetRate { return samples }

        let ratio = inputRate / targetRate
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcPos = Double(i) * ratio
            let srcIdx = Int(srcPos)
            let frac   = Float(srcPos - Double(srcIdx))
            let a = samples[min(srcIdx,     samples.count - 1)]
            let b = samples[min(srcIdx + 1, samples.count - 1)]
            output[i] = a + frac * (b - a)
        }
        return output
    }
}

public enum SpeechInferenceError: Error {
    case modelFileNotFound(String)
    case contextInitFailed
}
