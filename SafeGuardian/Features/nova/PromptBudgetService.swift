// PromptBudgetService.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Tracks per-model prompt token usage and context window sizes to produce
/// adaptive history turn recommendations. The engine calls record() after each
/// generation and recommendedTurnCount() before assembling history, replacing
/// the fixed NovaConfig.historyWindowSize ceiling with one that reacts to
/// actual measured token consumption.
actor PromptBudgetService {
    static let shared = PromptBudgetService()
    private init() {}

    private struct ModelState {
        var contextWindowSize: Int
        var lastPromptTokenCount: Int = 0
        var lastHistoryTurnCount: Int = 0
    }

    private var states: [String: ModelState] = [:]

    // 80% of the context window is the target prompt ceiling.
    // 512 tokens are held back for the model's generated response.
    private static let targetUtilization: Double = 0.80
    private static let generationReserve: Int = 512
    // Safe default for Qwen2.5 and Qwen3 family models.
    private static let defaultContextWindow: Int = 32_768

    // MARK: - Registration

    /// Called when a model finishes loading. Reads the context window size from
    /// the cached config.json; falls back to the default if unavailable.
    func register(modelID: String) async {
        let size = await MainActor.run {
            ModelDownloadManager.shared.contextWindowSize(modelID: modelID)
        } ?? Self.defaultContextWindow
        var s = states[modelID] ?? ModelState(contextWindowSize: size)
        s.contextWindowSize = size
        states[modelID] = s
    }

    // MARK: - Feedback

    /// Called after each completed generation with the reported prompt token count
    /// and the number of history turns that were included in that prompt.
    func record(modelID: String, promptTokens: Int, historyTurnCount: Int) {
        guard promptTokens > 0 else { return }
        var s = states[modelID] ?? ModelState(contextWindowSize: Self.defaultContextWindow)
        s.lastPromptTokenCount = promptTokens
        s.lastHistoryTurnCount = historyTurnCount
        states[modelID] = s
    }

    // MARK: - Recommendation

    /// Returns the number of history turns to include in the next call.
    /// Scales proportionally below the budget ceiling when the last prompt
    /// exceeded the target utilization; otherwise returns the window maximum.
    func recommendedTurnCount(modelID: String) -> Int {
        guard let s = states[modelID], s.lastPromptTokenCount > 0 else {
            return NovaConfig.historyWindowSize
        }
        let budget = Int(Double(s.contextWindowSize) * Self.targetUtilization)
            - Self.generationReserve
        guard s.lastPromptTokenCount > budget else {
            return NovaConfig.historyWindowSize
        }
        // Scale down proportionally: if last prompt was over budget,
        // reduce history turns by the same ratio.
        let fraction = Double(budget) / Double(s.lastPromptTokenCount)
        return max(1, min(NovaConfig.historyWindowSize,
                          Int(Double(s.lastHistoryTurnCount) * fraction)))
    }
}
