import SafeGuardianMesh
// AgentVoiceSession.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import AVFoundation
import Foundation
import WhisperInfra

/// Manages AVAudioEngine capture and Whisper transcription for the agent input bar.
/// Silence gap detection (1.5 s) auto-flushes utterances mid-session; `stop()` flushes
/// any remaining buffered audio synchronously before tearing down the engine.
final class AgentVoiceSession {
    private var avEngine: AVAudioEngine?
    private var sampleBuffer: [Float] = []
    private var nativeSampleRate: Double = 44_100
    private var isSpeechActive = false
    private var silenceTimer: Task<Void, Never>?
    private var tapFrameCount = 0
    private let onTranscription: @MainActor (String) -> Void
    private let onAudioLevel: (@MainActor (Float) -> Void)?

    init(
        onTranscription: @escaping @MainActor (String) -> Void,
        onAudioLevel: ((@MainActor (Float) -> Void))? = nil
    ) {
        self.onTranscription = onTranscription
        self.onAudioLevel = onAudioLevel
    }

    @MainActor
    func start() async throws {
        let granted = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        guard granted else { return }

        let coord = SpeechInferenceCoordinator.shared
        if !coord.isReady { try await coord.load() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        nativeSampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: data[0], count: count))
            let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(count))
            tapFrameCount += 1
            if tapFrameCount % 6 == 0, let cb = onAudioLevel {
                let level = min(rms * 8, 1.0)
                Task { @MainActor in cb(level) }
            }
            if rms > 0.01 {
                self.isSpeechActive = true
                self.sampleBuffer.append(contentsOf: samples)
                self.silenceTimer?.cancel()
                self.silenceTimer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled { await self?.flush() }
                }
            } else if self.isSpeechActive {
                self.sampleBuffer.append(contentsOf: samples)
            }
        }
        engine.prepare()
        try engine.start()
        avEngine = engine
    }

    func stop() {
        silenceTimer?.cancel()
        avEngine?.inputNode.removeTap(onBus: 0)
        avEngine?.stop()
        avEngine = nil

        guard isSpeechActive, !sampleBuffer.isEmpty else { return }
        let captured = sampleBuffer
        let rate = nativeSampleRate
        let cb = onTranscription
        sampleBuffer = []
        isSpeechActive = false

        Task {
            let samples = await MainActor.run { SpeechInferenceCoordinator.downsample(captured, from: rate) }
            if let text = await SpeechInferenceCoordinator.shared.transcribe(audioSamples: samples) {
                await cb(text)
            }
        }
    }

    @MainActor
    private func flush() async {
        guard isSpeechActive, !sampleBuffer.isEmpty else { return }
        let captured = sampleBuffer
        sampleBuffer = []
        isSpeechActive = false
        let samples = SpeechInferenceCoordinator.downsample(captured, from: nativeSampleRate)
        if let text = await SpeechInferenceCoordinator.shared.transcribe(audioSamples: samples) {
            onTranscription(text)
        }
    }
}
