//
// RemoteInferenceService.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation
import MLXLMCommon

// MARK: - SSE decoding types

private struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let tool_calls: [ToolCallChunk]?
        }
        struct ToolCallChunk: Decodable {
            let index: Int
            let id: String?
            struct Function: Decodable {
                let name: String?
                let arguments: String?
            }
            let function: Function?
        }
        let delta: Delta
        let finish_reason: String?
    }
    let choices: [Choice]
    let usage: Usage?

    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }
}

// Accumulates streaming tool call fragments keyed by index.
private struct AccumulatedCall {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""
}

/// AgentLanguageProvider that streams from any OpenAI-compatible endpoint
/// (Ollama, LM Studio, vLLM, OpenAI, etc.) using /v1/chat/completions SSE.
///
/// Supports multi-turn tool calling: when the model responds with
/// finish_reason "tool_calls", the service dispatches each call via
/// AgentToolRegistry, appends the results in the correct wire format
/// (assistant + tool_calls message first, then tool result messages),
/// and re-enters the loop. The DispatchGuard embedded in the registry
/// enforces the maxToolIterations cap.
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
            ? ModelCapabilities(hasThinkingMode: false, noThinkSuffix: nil, supportsToolCalling: true)
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
                // Seed message history — grows with tool results on each loop iteration.
                var messages: [[String: Any]] = [
                    ["role": "system", "content": input.systemPrompt]
                ]
                for turn in input.history {
                    messages.append(["role": turn.role.rawValue, "content": turn.content])
                }
                messages.append(["role": "user", "content": prompt])

                var totalTokens = 0
                var promptTokens = 0
                let start = Date()

                loop: while !Task.isCancelled {
                    var reqBody: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "stream_options": ["include_usage": true],
                        "messages": messages
                    ]
                    if let registry = input.toolRegistry, !registry.specs.isEmpty {
                        reqBody["tools"] = registry.specs
                        reqBody["tool_choice"] = "auto"
                    }

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !key.isEmpty {
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try? JSONSerialization.data(withJSONObject: reqBody)

                    do {
                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            continuation.yield(.failure("invalid response from remote endpoint"))
                            break loop
                        }
                        guard http.statusCode == 200 else {
                            continuation.yield(.failure("remote endpoint returned HTTP \(http.statusCode)"))
                            break loop
                        }

                        var pending: [Int: AccumulatedCall] = [:]
                        var finishReason: String? = nil
                        var assistantText = ""

                        for try await line in bytes.lines {
                            if Task.isCancelled { break loop }
                            guard line.hasPrefix("data: ") else { continue }
                            let payload = String(line.dropFirst(6))
                            if payload == "[DONE]" { break }
                            guard let data = payload.data(using: .utf8),
                                  let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data),
                                  let choice = chunk.choices.first
                            else {
                                // Usage-only chunk (no choices) — extract token counts
                                if let data = payload.data(using: .utf8),
                                   let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data) {
                                    promptTokens = chunk.usage?.prompt_tokens ?? promptTokens
                                    totalTokens  = chunk.usage?.completion_tokens ?? totalTokens
                                }
                                continue
                            }

                            if let reason = choice.finish_reason { finishReason = reason }

                            if let content = choice.delta.content, !content.isEmpty {
                                assistantText += content
                                continuation.yield(.token(content))
                                totalTokens += 1
                            }

                            for tc in choice.delta.tool_calls ?? [] {
                                var acc = pending[tc.index] ?? AccumulatedCall()
                                if let id = tc.id, !id.isEmpty { acc.id = id }
                                acc.name      += tc.function?.name      ?? ""
                                acc.arguments += tc.function?.arguments ?? ""
                                pending[tc.index] = acc
                            }
                        }

                        // Tool calls: correct wire format requires the assistant message
                        // containing tool_calls to precede the tool result messages.
                        // Skipping it causes 400 errors on strict endpoints.
                        if finishReason == "tool_calls", !pending.isEmpty,
                           let registry = input.toolRegistry
                        {
                            let ordered = pending.sorted { $0.key < $1.key }.map { $0.value }

                            // 1. Append assistant message with tool_calls
                            var assistantMsg: [String: Any] = [
                                "role": "assistant",
                                "tool_calls": ordered.map { acc -> [String: Any] in
                                    ["id": acc.id, "type": "function",
                                     "function": ["name": acc.name, "arguments": acc.arguments]]
                                }
                            ]
                            assistantMsg["content"] = assistantText.isEmpty ? NSNull() : assistantText
                            messages.append(assistantMsg)

                            // 2. Dispatch each call and append tool result
                            for acc in ordered {
                                if Task.isCancelled { break loop }
                                let argData = acc.arguments.data(using: .utf8) ?? Data()
                                let argDict = (try? JSONDecoder().decode([String: JSONValue].self, from: argData)) ?? [:]
                                let toolCall = ToolCall(function: .init(name: acc.name, arguments: argDict))
                                let result = (try? await registry.dispatch(toolCall))
                                    ?? #"{"error":"dispatch_failed","tool":"\#(acc.name)"}"#
                                messages.append([
                                    "role": "tool",
                                    "tool_call_id": acc.id,
                                    "content": result
                                ])
                            }
                            // Re-enter loop with updated message history.
                            continue loop
                        }

                    } catch {
                        if !Task.isCancelled {
                            continuation.yield(.failure("connection error: \(error.localizedDescription)"))
                        }
                        break loop
                    }

                    // Normal stop — exit loop.
                    break loop
                }

                let elapsedMs = Date().timeIntervalSince(start) * 1000
                continuation.yield(.stats(AgentGenerationStats(
                    promptTokens: promptTokens,
                    generationTokens: totalTokens,
                    promptMs: 0,
                    generateMs: elapsedMs
                )))
                continuation.yield(.complete)
                continuation.finish()
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}
