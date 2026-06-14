// PromptBudgetService.swift
// AgentInfra
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Tracks per-model prompt token usage to produce adaptive history turn recommendations.
/// The engine calls record() after each generation and recommendedTurnCount() before
/// assembling history, replacing a fixed ceiling with one that reacts to measured usage.
public actor PromptBudgetService {
    public static let shared = PromptBudgetService()
    private init() {}

    public static let defaultWindowSize: Int = 10
    private static let targetUtilization: Double = 0.80
    private static let generationReserve: Int = 512
    private static let defaultContextWindow: Int = 32_768

    // Known context window sizes for models that cannot self-report via token usage.
    // Foundation Models has a fixed 4096-token window (input + output combined).
    private static let knownContextWindows: [String: Int] = [
        "apple/on-device": 4_096,
    ]

    private struct ModelState {
        var contextWindowSize: Int
        var lastPromptTokenCount: Int = 0
        var lastHistoryTurnCount: Int = 0
    }

    private var states: [String: ModelState] = [:]

    public func register(modelID: String, contextWindowSize: Int) {
        var s = states[modelID] ?? ModelState(contextWindowSize: contextWindowSize)
        s.contextWindowSize = contextWindowSize
        states[modelID] = s
    }

    public func register(modelID: String) {
        if states[modelID] == nil {
            let window = Self.knownContextWindows[modelID] ?? Self.defaultContextWindow
            states[modelID] = ModelState(contextWindowSize: window)
        }
    }

    public func record(modelID: String, promptTokens: Int, historyTurnCount: Int) {
        guard promptTokens > 0 else { return }
        var s = states[modelID] ?? ModelState(contextWindowSize: Self.defaultContextWindow)
        s.lastPromptTokenCount = promptTokens
        s.lastHistoryTurnCount = historyTurnCount
        states[modelID] = s
    }

    public func recommendedTurnCount(modelID: String) -> Int {
        guard let s = states[modelID], s.lastPromptTokenCount > 0 else {
            return Self.defaultWindowSize
        }
        let budget = Int(Double(s.contextWindowSize) * Self.targetUtilization)
            - Self.generationReserve
        guard s.lastPromptTokenCount > budget else { return Self.defaultWindowSize }
        let fraction = Double(budget) / Double(s.lastPromptTokenCount)
        return max(1, min(Self.defaultWindowSize,
                          Int(Double(s.lastHistoryTurnCount) * fraction)))
    }
}
