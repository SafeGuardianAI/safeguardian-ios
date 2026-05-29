# Nova Provider Abstraction — Implementation Plan

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

## Current State After onToken Fix

`NovaGenerationEvent` is in `NovaConfig.swift`. `NovaInferenceCoordinator.generate()` returns `AsyncStream<NovaGenerationEvent>`. `MLXInferenceService.generate()` returns `AsyncStream<NovaGenerationEvent>`. `NovaAgent.handle()` consumes the stream in one `Task { @MainActor in for await }`. The per-token Task flood is fixed. Steps 1–4 above layer the provider abstraction on top of this.
