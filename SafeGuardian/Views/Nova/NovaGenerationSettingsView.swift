// NovaGenerationSettingsView.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import AgentRuntime
import SwiftUI

/// Sampling controls for the active on-device model, backed by GenerationSettingsStore
/// — one dial per model ID, not one global pair, since different model families
/// warrant different defaults (see ModelCapabilities.defaultTemperature) and switching
/// models shouldn't clobber a setting you'd already tuned for another one.
///
/// The response-length cap can only be dialed down from the active model's real
/// context window, read from its own downloaded config.json — never up past it.
struct NovaGenerationSettingsView: View {
    @State private var registry = AgentProviderRegistry.shared
    @State private var settings = GenerationSettingsStore.shared
    @State private var expanded = false
    @Environment(\.colorScheme) var colorScheme

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }

    private var modelID: String { registry.activeProvider.activeModelID }

    private var contextWindow: Int? {
        ModelDownloadManager.shared.contextWindowSize(modelID: modelID)
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { settings.temperature(for: modelID) },
            set: { settings.setTemperature($0, for: modelID) }
        )
    }

    private var maxResponseTokensEnabled: Bool {
        settings.maxResponseTokens(for: modelID, contextWindow: contextWindow) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.safeguardianSystem(size: 20))
                    .foregroundColor(textColor)
                    .frame(width: 30)

                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    HStack {
                        Text("generation settings")
                            .font(.safeguardianSystem(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(textColor)
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.safeguardianSystem(size: 11))
                            .foregroundColor(secondaryTextColor)
                    }
                }
                .buttonStyle(.plain)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    // Temperature — always has a value: either the user's override or
                    // this model family's own recommended default (ModelCapabilities).
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("temperature: \(temperatureBinding.wrappedValue, specifier: "%.2f")")
                                .font(.safeguardianSystem(size: 12, design: .monospaced))
                                .foregroundColor(textColor)
                            if settings.hasTemperatureOverride(for: modelID) {
                                Button("reset") { settings.setTemperature(nil, for: modelID) }
                                    .font(.safeguardianSystem(size: 10, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }
                            Spacer()
                        }
                        Slider(value: temperatureBinding, in: 0...1, step: 0.05)
                            .tint(textColor)
                        Text("lower is more predictable and consistent; higher allows more varied phrasing")
                            .font(.safeguardianSystem(size: 10, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                    }

                    // Response length cap — off (nil) means the model may use as much of
                    // its context window as a turn needs, up to contextWindow when known.
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(
                            get: { maxResponseTokensEnabled },
                            set: { on in
                                settings.setMaxResponseTokens(on ? (contextWindow.map { $0 / 4 } ?? 1024) : nil, for: modelID)
                            }
                        )) {
                            Text("cap response length")
                                .font(.safeguardianSystem(size: 12, design: .monospaced))
                                .foregroundColor(textColor)
                        }
                        .tint(textColor)

                        if maxResponseTokensEnabled {
                            let capBinding = Binding<Double>(
                                get: { Double(settings.maxResponseTokens(for: modelID, contextWindow: contextWindow) ?? 1024) },
                                set: { settings.setMaxResponseTokens(Int($0), for: modelID) }
                            )
                            let upperBound = Double(contextWindow ?? 8192)
                            Text("\(Int(capBinding.wrappedValue)) tokens" + (contextWindow.map { " (model max \($0))" } ?? ""))
                                .font(.safeguardianSystem(size: 11, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                            Slider(value: capBinding, in: 64...upperBound, step: 64)
                                .tint(textColor)
                        } else {
                            Text(contextWindow.map { "model max: \($0) tokens" } ?? "no known limit for this model")
                                .font(.safeguardianSystem(size: 10, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                        }
                    }
                }
                .padding(.leading, 42)
            }
        }
    }
}
