// AgentTranscriptionProvider.swift
// AgentInfra
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// The speech-to-text backend protocol. Any provider — WhisperKit, on-device
/// SFSpeechRecognizer, or a remote API — implements this and is injected into
/// VoiceReportSession. Nova, Trek, and any future voice-enabled agent share this contract.
///
/// Accepts raw 16 kHz mono PCM samples because that is the format Whisper
/// expects and the format every practical STT backend can consume after resampling.
@MainActor
public protocol AgentTranscriptionProvider: AnyObject {
    /// True once the model is loaded and ready to accept audio.
    var isReady: Bool { get }

    /// Initiates model loading if it has not begun. Safe to call multiple times.
    func load() async throws

    /// Transcribes a 16 kHz mono PCM sample buffer and returns the text result.
    /// Returns nil on silence, failed decode, or if the model is not yet loaded.
    func transcribe(audioSamples: [Float]) async -> String?
}
