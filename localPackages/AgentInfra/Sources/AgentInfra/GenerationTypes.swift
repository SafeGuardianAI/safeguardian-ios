// GenerationTypes.swift
// AgentInfra
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Per-model capability flags. Add an entry to modelCapabilities(for:) when
/// onboarding a new model. The inference layer reads these at runtime so
/// switching models requires no changes outside this file.
public struct ModelCapabilities: Sendable {
    public let hasThinkingMode: Bool
    public let noThinkSuffix: String?
    public let supportsToolCalling: Bool
    public let supportsVision: Bool

    public init(
        hasThinkingMode: Bool, noThinkSuffix: String?,
        supportsToolCalling: Bool, supportsVision: Bool
    ) {
        self.hasThinkingMode = hasThinkingMode
        self.noThinkSuffix = noThinkSuffix
        self.supportsToolCalling = supportsToolCalling
        self.supportsVision = supportsVision
    }
}

/// Provider-agnostic generation performance stats.
public struct AgentGenerationStats: Sendable {
    public let promptTokens: Int
    public let generationTokens: Int
    public let promptMs: Double
    public let generateMs: Double
    public var tokensPerSecond: Double {
        generateMs > 0 ? Double(generationTokens) / (generateMs / 1000) : 0
    }
    public var promptTokensPerSecond: Double {
        promptMs > 0 ? Double(promptTokens) / (promptMs / 1000) : 0
    }

    public init(
        promptTokens: Int, generationTokens: Int,
        promptMs: Double, generateMs: Double
    ) {
        self.promptTokens = promptTokens; self.generationTokens = generationTokens
        self.promptMs = promptMs; self.generateMs = generateMs
    }
}

/// Events emitted by an AgentLanguageProvider during a single generation.
public enum AgentGenerationEvent: Sendable {
    case status(String)
    case token(String)
    case stats(AgentGenerationStats)
    case complete
    case failure(String)
}

/// Returns capability flags for a given HuggingFace model ID.
/// Pattern-matched against the lowercased ID; most specific match wins.
public func modelCapabilities(for modelID: String) -> ModelCapabilities {
    let id = modelID.lowercased()
    // 1.7b added: Qwen3-1.7B is the smallest Qwen3 with a working function-call template.
    let isLargeEnough = ["1.7b","2b","3b","4b","7b","8b","9b","14b","27b","32b","72b"]
        .contains { id.contains($0) }
    let isVision = id.contains("-vl") || id.contains("vision") || id.contains("llava")
    if id.contains("qwen3") || id.contains("qwq") {
        return ModelCapabilities(hasThinkingMode: true, noThinkSuffix: " /no_think",
                                 supportsToolCalling: isLargeEnough, supportsVision: isVision)
    }
    // Qwen2.5-Instruct ships a function-calling chat template at all sizes, but the
    // 0.5B variant cannot reliably follow the format in practice. 1.5B is the
    // smallest size that produces consistent, parseable tool calls.
    if id.contains("qwen2.5") || id.contains("qwen2_5") {
        let isLargeEnough = ["1.5b","2b","3b","4b","7b","8b","14b","32b","72b"]
            .contains { id.contains($0) }
        return ModelCapabilities(hasThinkingMode: false, noThinkSuffix: nil,
                                 supportsToolCalling: isLargeEnough, supportsVision: isVision)
    }
    if id.contains("deepseek-r1") {
        return ModelCapabilities(hasThinkingMode: true, noThinkSuffix: nil,
                                 supportsToolCalling: isLargeEnough, supportsVision: isVision)
    }
    if id.contains("gemma") {
        let toolCapable = ["4b","7b","8b","9b","27b"].contains { id.contains($0) }
        return ModelCapabilities(hasThinkingMode: false, noThinkSuffix: nil,
                                 supportsToolCalling: toolCapable, supportsVision: isVision)
    }
    return ModelCapabilities(hasThinkingMode: false, noThinkSuffix: nil,
                             supportsToolCalling: false, supportsVision: isVision)
}
