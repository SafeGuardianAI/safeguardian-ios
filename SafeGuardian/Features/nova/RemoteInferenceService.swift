//
// RemoteInferenceService.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

private struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
        let finish_reason: String?
    }
    let choices: [Choice]
}

/// AgentLanguageProvider that streams from any OpenAI-compatible endpoint
/// (Ollama, LM Studio, vLLM, OpenAI, etc.) using the /v1/chat/completions
/// server-sent events protocol.
@Observable @MainActor
final class RemoteInferenceService: AgentLanguageProvider {
    static let shared = RemoteInferenceService()

    private static let urlKey   = "remote.provider.url"
    private static let modelKey = "remote.provider.model"
    private static let keyKey   = "remote.provider.apikey"

    let id          = "remote"
    var displayName: String { modelID.isEmpty ? "remote (unconfigured)" : "remote (\(modelID))" }
    var activeModelID: String { modelID }
    var isLoading   = false
    var isModelLoaded: Bool { !baseURL.isEmpty && !modelID.isEmpty }
    var capabilities: AgentProviderCapabilities {
        AgentProviderCapabilities(requiresNetwork: true, modelCapabilities: nil)
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

    private var currentTask: Task<Void, Never>?

    private init() {
        baseURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        modelID = UserDefaults.standard.string(forKey: Self.modelKey) ?? ""
        apiKey  = UserDefaults.standard.string(forKey: Self.keyKey) ?? ""
    }

    func generate(input: AgentPromptInput) -> AsyncStream<AgentGenerationEvent> {
        let url    = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model  = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key    = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = input.decorated(modelID: model)

        return AsyncStream { continuation in
            guard !url.isEmpty, !model.isEmpty else {
                continuation.yield(.failure("remote provider not configured — set URL and model in settings"))
                continuation.finish()
                return
            }
            let base = url.hasSuffix("/") ? url : url + "/"
            guard let endpoint = URL(string: base + "v1/chat/completions") else {
                continuation.yield(.failure("invalid URL: \(url)"))
                continuation.finish()
                return
            }

            self.currentTask = Task {
                var request        = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !key.isEmpty {
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                }
                var messages: [[String: Any]] = [
                    ["role": "system", "content": input.systemPrompt]
                ]
                for turn in input.history {
                    messages.append(["role": turn.role.rawValue, "content": turn.content])
                }
                messages.append(["role": "user", "content": prompt])
                let body: [String: Any] = [
                    "model": model,
                    "stream": true,
                    "messages": messages
                ]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.yield(.failure("invalid response from remote endpoint"))
                        continuation.finish()
                        return
                    }
                    guard http.statusCode == 200 else {
                        continuation.yield(.failure("remote endpoint returned HTTP \(http.statusCode)"))
                        continuation.finish()
                        return
                    }

                    var tokenCount = 0
                    let start = Date()

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data),
                              let content = chunk.choices.first?.delta.content,
                              !content.isEmpty
                        else { continue }
                        continuation.yield(.token(content))
                        tokenCount += 1
                    }

                    let elapsedMs = Date().timeIntervalSince(start) * 1000
                    continuation.yield(.stats(AgentGenerationStats(
                        promptTokens: 0, generationTokens: tokenCount,
                        promptMs: 0, generateMs: elapsedMs
                    )))
                    continuation.yield(.complete)
                } catch {
                    if !Task.isCancelled {
                        continuation.yield(.failure("connection error: \(error.localizedDescription)"))
                    }
                }
                continuation.finish()
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}
