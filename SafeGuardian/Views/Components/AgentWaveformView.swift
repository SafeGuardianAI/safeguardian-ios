import SafeGuardianMesh
// AgentWaveformView.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import SwiftUI

/// Animated waveform shown inside the AgentInputBar text field area while Whisper is recording.
/// Bar heights respond to live RMS audio level from AgentVoiceSession.
struct AgentWaveformView: View {
    let audioLevel: Float

    private let barCount = 26

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { c, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let barW = size.width / CGFloat(barCount + 1)
                let base  = size.height * 0.12
                let range = size.height * 0.76
                let lvl   = CGFloat(max(0.04, audioLevel))

                for i in 0..<barCount {
                    let phase = Double(i) * 0.45 + t * 5.5
                    let wave  = CGFloat((sin(phase) + 1) * 0.5)
                    let h     = base + range * lvl * wave
                    let x     = barW * CGFloat(i + 1)
                    let rect  = CGRect(
                        x: x - barW * 0.32,
                        y: (size.height - h) / 2,
                        width: barW * 0.64,
                        height: h
                    )
                    let path  = Path(roundedRect: rect, cornerRadius: barW * 0.32)
                    let alpha = 0.55 + 0.45 * wave * lvl
                    c.fill(path, with: .color(Color.red.opacity(alpha)))
                }
            }
        }
    }
}
