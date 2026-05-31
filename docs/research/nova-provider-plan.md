# Nova Provider Abstraction — Implementation Plan (HISTORICAL)

> This document reflects the pre-implementation design. Current code uses `AgentLanguageProvider`, `AgentGenerationEvent`, `MLXInferenceCoordinator`, and `MLXSessionPool`. References to `NovaLanguageProvider`, `NovaGenerationEvent`, `NovaInferenceCoordinator`, `NovaSessionPool`, and `NovaAgent` are superseded.

Date: 2026-05-28

## What AnyLanguageModel Actually Is

HuggingFace/mattt package. Drop-in replacement for Apple's Foundation Models framework. Core types: `LanguageModel` protocol, `LanguageModelSession`, `Prompt`, `GenerationOptions`. Uses Swift 6.1 package traits to gate heavy backends (MLX, CoreML, Llama) so the base package ships only cloud providers over URLSession.

Key finding: AnyLanguageModel's MLX trait depends on `swift-transformers >= 1.0.0`. Our project pins `swift-transformers 0.1.24`. These are incompatible. Pulling AnyLanguageModel with the MLX trait would require a transformers upgrade and likely break things. The cloud providers (Ollama, OpenAI, Anthropic, Gemini) do not need the MLX trait — they are pure URLSession. We can integrate those without the version conflict.

We do not adopt AnyLanguageModel's types as our internal contract. We define our own `NovaLanguageProvider` protocol whose output is `AsyncStream<NovaGenerationEvent>` (already done). AnyLanguageModel-backed adapters are one provider implementation among several, sitting behind that boundary.

## Internal Contract (Already Partly Done)

`NovaGenerationEvent` is already defined in `NovaConfig.swift`. `NovaInferenceCoordinator.generate()` already returns `AsyncStream<NovaGenerationEvent>`. `NovaAgent` already consumes it in one Task.

What is not yet done: the provider protocol boundary, the registry, and the prompt input type.

## Steps

### Step 1 — NovaLanguageProvider protocol + NovaPromptInput
Add `Features/nova/NovaLanguageProvider.swift`.

```swift
struct NovaPromptInput: Sendable {
    var text: String
    var tick: NovaStateTick?
}

struct NovaProviderCapabilities: Sendable {
    let requiresNetwork: Bool
}

@MainActor
protocol NovaLanguageProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var capabilities: NovaProviderCapabilities { get }
    var isLoading: Bool { get }
    var isModelLoaded: Bool { get }
    func generate(input: NovaPromptInput) -> AsyncStream<NovaGenerationEvent>
    func cancel()
}
```

No other files change. Verify build.

### Step 2 — MLXInferenceService conforms to NovaLanguageProvider
Add conformance to `MLXInferenceService`. Change `generate(prompt:tick:)` to `generate(input: NovaPromptInput)`. Move `decoratePrompt` out of `NovaInferenceCoordinator` into `MLXInferenceService.generate()` at the call site (it already lives there effectively). Add `id`, `displayName`, `capabilities` properties.

One file changes: `MLXInferenceService.swift`. Verify build.

### Step 3 — NovaProviderRegistry
Add `Features/nova/NovaProviderRegistry.swift`. `@Observable @MainActor` singleton that holds `activeProvider: any NovaLanguageProvider`, initialized to `MLXInferenceService.shared`.

No other files change. Verify build.

### Step 4 — NovaAgent uses registry
Change `NovaAgent.handle()` to call `NovaProviderRegistry.shared.activeProvider.generate(input:)` instead of `MLXInferenceService.shared.generate(prompt:tick:)`. Construct `NovaPromptInput` at the call site.

One file changes: `NovaAgent.swift`. Verify build.

### Step 5 — OllamaNovaProvider (first new provider)
Add `Features/nova/OllamaNovaProvider.swift`. Pure URLSession, no trait needed, no dependency conflict. Uses Server-Sent Events for streaming. This validates the provider abstraction works end-to-end before touching AnyLanguageModel.

New file only. Verify build.

### Step 6 — Provider settings UI
Add provider picker to AppInfoView (or a new NovaSettingsView). Shows available providers, model ID input, base URL for Ollama, API key for cloud providers. Keys go in Keychain via `KeychainManager`. Non-secret config (provider kind, model ID, base URL, active provider ID) goes in UserDefaults.

### Step 7 — AnyLanguageModel cloud providers (deferred)
Once Ollama works and the pattern is stable, add AnyLanguageModel as a dependency without the MLX trait. Use it only for `OllamaLanguageModel`, `OpenAILanguageModel`, `AnthropicLanguageModel`, `GeminiLanguageModel`. These are pure URLSession internally. No `swift-transformers` conflict.

If the MLX trait is needed later (AnyLanguageModel's `MLXLanguageModel` vs our own), handle that as a `NovaLanguageKit` shim package per the research doc's recommendation.

## What Does Not Change

- `MLXModelLoader` — stays as-is, owned by `MLXInferenceService`
- `NovaSessionPool` — stays as-is, owned by `NovaInferenceCoordinator`
- `NovaBroadcaster` — untouched
- `NovaStateTick` — untouched
- `AgentProcessor` / `AgentContext` — untouched
- IPC host — untouched
- Command system — untouched
- Everything in bitchat origin — untouched

## Current State (2026-05-28)

All types renamed to agnostic names: `AgentGenerationEvent`, `AgentGenerationStats`, `AgentPromptInput`, `AgentProviderCapabilities`, `AgentLanguageProvider`, `AgentProviderRegistry`, `MLXInferenceCoordinator`, `MLXSessionPool`, `ConversationLogger`.

Steps 1–4 complete. `MLXInferenceService` conforms to `AgentLanguageProvider`. `NovaAgent` routes through `AgentProviderRegistry.shared.activeProvider`. Per-token Task flood eliminated — one `Task { @MainActor in for await }` consumes the stream.

`AgentGenerationEvent` has a `.stats(AgentGenerationStats)` case. `MLXInferenceCoordinator` uses `ChatSession.streamDetails(to:images:videos:)` to receive `Generation.info` at completion, mapping it to `AgentGenerationStats` (prompt/generation token counts, prompt/generate milliseconds, tokens per second).

`NovaAgent.drain()` (renamed from `drainVisible`) returns `(visible, thinking, remainder)`, accumulating `<think>...</think>` content in `NovaStreamState.thinking` rather than discarding it.

`ConversationLogger` writes to `dev/conversations.jsonl`. Each entry: full multi-turn thread, optional top-level `"thinking"` field, and `metadata` with `prompt_tokens`, `generation_tokens`, `prompt_ms`, `generate_ms`, `tokens_per_sec`, `prompt_tokens_per_sec`, `battery_pct`, `peer_count`, `duration_ms`. Format toggleable between OpenAI JSONL and ShareGPT via `/log format`. All gated `#if DEBUG`.

`scripts/check_agent_names.sh` enforces no agent names in infrastructure files or types. Runs in `just check`.

Step 5 (OllamaNovaProvider) is next.
