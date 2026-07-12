//
// RemoteInferenceService.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import AgentInfra
import AnyLanguageModelKit
import Foundation

/// AgentLanguageProvider that streams from any OpenAI-compatible endpoint
/// (Ollama, LM Studio, vLLM, OpenAI, etc.) through AnyLanguageModel's
/// OpenAILanguageModel backend against /v1/chat/completions.
///
/// Tool calling runs inside LanguageModelSession's own resolution loop:
/// tools bridged via AgentToolRegistry.asLanguageModelTools() route every
/// call back through the registry's dispatch closure, so the DispatchGuard
/// iteration cap, approval gate, and MCP routing apply unchanged.
@Observable @MainActor
final class RemoteInferenceService: AgentLanguageProvider {
    static let shared = RemoteInferenceService()

    private static let urlKey         = "remote.provider.url"
    private static let modelKey       = "remote.provider.model"
    private static let keyKey         = "remote.provider.apikey"
    private static let toolsEnabledKey = "remote.provider.toolsEnabled"

    let id = "remote"
    var displayName: String { modelID.isEmpty ? "remote (unconfigured)" : "remote (\(modelID))" }
    var activeModelID: String { modelID }
    var isLoading = false
    var isModelLoaded: Bool { !baseURL.isEmpty && !modelID.isEmpty }

    var capabilities: AgentProviderCapabilities {
        let caps: ModelCapabilities? = toolsEnabled
            ? ModelCapabilities(hasThinkingMode: false, noThinkSuffix: nil, supportsToolCalling: true, supportsVision: false)
            : nil
        return AgentProviderCapabilities(requiresNetwork: true, modelCapabilities: caps)
    }

    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.urlKey) }
    }
    var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: Self.modelKey) }
    }
    var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Self.keyKey) }
    }
    var toolsEnabled: Bool {
        didSet { UserDefaults.standard.set(toolsEnabled, forKey: Self.toolsEnabledKey) }
    }

    private var currentTask: Task<Void, Never>?

    private init() {
        baseURL      = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        modelID      = UserDefaults.standard.string(forKey: Self.modelKey) ?? ""
        apiKey       = UserDefaults.standard.string(forKey: Self.keyKey) ?? ""
        toolsEnabled = UserDefaults.standard.bool(forKey: Self.toolsEnabledKey)
    }

    func generate(input: AgentPromptInput) -> AsyncStream<AgentGenerationEvent> {
        let url   = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key   = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = input.decorated(modelID: model)
        let toolsEnabled = self.toolsEnabled

        return AsyncStream { continuation in
            guard !url.isEmpty, !model.isEmpty else {
                continuation.yield(.failure("remote provider not configured — set URL and model in settings"))
                continuation.finish()
                return
            }
            // OpenAILanguageModel appends "chat/completions"; the stored URL is the server root.
            let base = url.hasSuffix("/") ? url : url + "/"
            guard let endpoint = URL(string: base + "v1") else {
                continuation.yield(.failure("invalid URL: \(url)"))
                continuation.finish()
                return
            }

            let backend = OpenAILanguageModel(baseURL: endpoint, apiKey: key, model: model)
            let tools: [any AnyLanguageModelKit.Tool] = toolsEnabled
                ? (input.toolRegistry as? AgentToolRegistry)?.asLanguageModelTools() ?? []
                : []
            // A fresh session per call, seeded from history — the remote endpoint
            // holds no state between requests, matching the previous wire behavior.
            let session = LanguageModelSession(
                model: backend, tools: tools,
                transcript: .seeded(systemPrompt: input.systemPrompt, history: input.history)
            )
            let images = input.imageData.map { Transcript.ImageSegment(data: $0, mimeType: "image/jpeg") }

            self.currentTask = Task { @MainActor in
                let start = Date()
                let stream = images.isEmpty
                    ? session.streamResponse(to: prompt)
                    : session.streamResponse(to: prompt, images: images)
                await AgentProviderStreaming.drain(stream, into: continuation, beforeComplete: {
                    let elapsedMs = Date().timeIntervalSince(start) * 1000
                    continuation.yield(.stats(AgentGenerationStats(
                        promptTokens: 0,
                        generationTokens: 0,
                        promptMs: 0,
                        generateMs: elapsedMs
                    )))
                })
                continuation.finish()
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}
