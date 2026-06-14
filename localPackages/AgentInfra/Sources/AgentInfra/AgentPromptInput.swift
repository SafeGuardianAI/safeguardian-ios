// AgentPromptInput.swift
// AgentInfra
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// The complete input to a single agent inference call.
/// Assembled by AgentConversationEngine and consumed by each AgentLanguageProvider.
public struct AgentPromptInput: Sendable {
    public var text: String
    public var tick: AgentStateTick?
    public var systemPrompt: String
    /// Windowed prior conversation turns, oldest first.
    /// Excludes the current user message — that is carried by `text`.
    public var history: [ConversationTurn] = []
    public var toolRegistry: (any Sendable)? = nil
    public var isMeshQuery: Bool = false
    public var imageData: [Data] = []
    public var threadID: String = ""

    public init(
        text: String,
        tick: AgentStateTick? = nil,
        systemPrompt: String,
        history: [ConversationTurn] = [],
        toolRegistry: (any Sendable)? = nil,
        isMeshQuery: Bool = false
    ) {
        self.text = text
        self.tick = tick
        self.systemPrompt = systemPrompt
        self.history = history
        self.toolRegistry = toolRegistry
        self.isMeshQuery = isMeshQuery
    }

    /// Decorates the prompt text with device state context and model-specific suffixes.
    public func decorated(modelID: String) -> String {
        let caps = modelCapabilities(for: modelID)
        var result = text
        if let tick {
            let battery = Int(tick.batteryPct * 100)
            let loc = String(format: "%.4f,%.4f", tick.lat, tick.lon)
            result = "[state: battery \(battery)%, loc \(loc), \(tick.peerCount) peers] \(result)"
        }
        if let suffix = caps.noThinkSuffix {
            result += suffix
        }
        return result
    }
}

/// Provider runtime capability flags. Nil modelCapabilities means no model is loaded yet.
public struct AgentProviderCapabilities: Sendable {
    public let requiresNetwork: Bool
    public var modelCapabilities: ModelCapabilities?

    public init(requiresNetwork: Bool, modelCapabilities: ModelCapabilities? = nil) {
        self.requiresNetwork = requiresNetwork
        self.modelCapabilities = modelCapabilities
    }
}
