// GenerationSettingsStore.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import AgentRuntime
import Foundation

/// Per-model user overrides for generation sampling — temperature and a response-length
/// cap. Keyed by model ID rather than a single global pair: different model families
/// warrant different defaults (see ModelCapabilities.defaultTemperature), and switching
/// models should not clobber the dial you'd already set for another one.
///
/// A model's own real context window (from its downloaded config.json, see
/// ModelDownloadManager.contextWindowSize) is the ceiling on maxResponseTokens — a user
/// can only dial that down, never past what the model file itself supports.
@Observable @MainActor
final class GenerationSettingsStore {
    static let shared = GenerationSettingsStore()

    private static let storageKey = "nova.generationSettings"

    private struct Overrides: Codable, Equatable {
        var temperature: Double?
        var maxResponseTokens: Int?
    }

    private var overrides: [String: Overrides] {
        didSet { persist() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Overrides].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// The temperature to actually generate with: the user's override for this model if
    /// they've set one, else that model family's own recommended default — never a single
    /// fixed value shared across every model.
    func temperature(for modelID: String) -> Double {
        overrides[modelID]?.temperature ?? modelCapabilities(for: modelID).defaultTemperature
    }

    func hasTemperatureOverride(for modelID: String) -> Bool {
        overrides[modelID]?.temperature != nil
    }

    func setTemperature(_ value: Double?, for modelID: String) {
        var o = overrides[modelID] ?? Overrides()
        o.temperature = value
        overrides[modelID] = o
    }

    /// The response-length cap to generate with, if any — nil means let the model use as
    /// much of its context window as a turn needs. `contextWindow`, when known, clamps a
    /// stored value down (never up), so an override saved while one model was active can't
    /// exceed a different, smaller model's real max_position_embeddings after a switch.
    func maxResponseTokens(for modelID: String, contextWindow: Int?) -> Int? {
        guard let stored = overrides[modelID]?.maxResponseTokens else { return nil }
        guard let contextWindow else { return stored }
        return min(stored, contextWindow)
    }

    func setMaxResponseTokens(_ value: Int?, for modelID: String) {
        var o = overrides[modelID] ?? Overrides()
        o.maxResponseTokens = value
        overrides[modelID] = o
    }

    func resetToDefaults(for modelID: String) {
        overrides.removeValue(forKey: modelID)
    }
}
