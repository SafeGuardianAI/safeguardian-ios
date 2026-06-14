// AgentInputBar.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import SwiftUI
import WhisperInfra
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Compose bar for agent DM threads. Tap mic to start Whisper transcription into the
/// text field; tap again (or send) to stop. The send button is disabled while the
/// agent is generating a response.
struct AgentInputBar: View {
    @Binding var text: String
    let onSend: () -> Void

    @ObservedObject private var engine = AgentConversationEngine.shared

    @State private var session: AgentVoiceSession? = nil
    @State private var isRecording = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6
    @State private var audioLevel: Float = 0

    var body: some View {
        VStack(spacing: 0) {
            if engine.isRunning {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Nova is thinking...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            HStack(alignment: .center, spacing: 8) {
                micButton

                ZStack(alignment: .leading) {
                    TextField("Message Nova...", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .monospaced))
                        .lineLimit(1...4)
                        .submitLabel(.send)
                        .onSubmit { sendIfReady() }
                        .opacity(isRecording ? 0 : 1)
                    if isRecording {
                        AgentWaveformView(audioLevel: audioLevel)
                            .frame(height: 36)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.sgSystemBackground.opacity(0.7))
                )
                .frame(maxWidth: .infinity)

                sendButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var micButton: some View {
        ZStack {
            if isRecording {
                Circle()
                    .stroke(Color.red.opacity(pulseOpacity), lineWidth: 3)
                    .scaleEffect(pulseScale)
                    .frame(width: 44, height: 44)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulseScale)
            }
            Button(action: toggleRecording) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.red : Color.sgSecondarySystemBackground)
                        .frame(width: 36, height: 36)
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16))
                        .foregroundColor(isRecording ? .white : .primary)
                }
            }
            .disabled(engine.isRunning)
        }
        .onChange(of: isRecording) { _, recording in
            pulseScale   = recording ? 1.25 : 1.0
            pulseOpacity = recording ? 0.0  : 0.6
        }
    }

    private var sendButton: some View {
        let ready = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !engine.isRunning
        return Button(action: sendIfReady) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(ready ? .blue : .gray)
        }
        .disabled(!ready)
    }

    private func sendIfReady() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !engine.isRunning else { return }
        stopRecording()
        onSend()
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        let s = AgentVoiceSession(
            onTranscription: { [self] (transcript: String) in
                if !text.isEmpty { text += " " }
                text += transcript
            },
            onAudioLevel: { [self] (level: Float) in audioLevel = level }
        )
        session = s
        isRecording = true
        Task {
            do {
                try await s.start()
            } catch {
                isRecording = false
                audioLevel = 0
                session = nil
            }
        }
    }

    private func stopRecording() {
        session?.stop()
        session = nil
        isRecording = false
        audioLevel = 0
    }
}

private extension Color {
    static var sgSystemBackground: Color {
#if canImport(UIKit)
        Color(UIColor.systemBackground)
#else
        Color(NSColor.windowBackgroundColor)
#endif
    }
    static var sgSecondarySystemBackground: Color {
#if canImport(UIKit)
        Color(UIColor.secondarySystemBackground)
#else
        Color(NSColor.controlBackgroundColor)
#endif
    }
}
