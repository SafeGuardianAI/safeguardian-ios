# SafeGuardian iOS - Project Instructions

## Architecture & State
- **Projection Model**: `ChatViewModel.messages` is a visible projection, not the source of truth.
- **Source of Truth**: The real state lives in `PublicTimelineStore` (for mesh/location channels) and `privateChats` (for DMs).
- **Message Injection Mechanics**:
    - `addPublicSystemMessage(_:)` appends to the store and calls `refreshVisibleMessages()`, which overwrites the visible projection wholesale.
    - `addLocalPrivateSystemMessage(_:to:)` appends to `privateChats` and relies on `objectWillChange.send()` for reactive UI updates.
    - `addLocalMessage(_:)` appends directly to the projection and is ephemeral (lost on channel switch).

## Core vs. Extension Preservation

The bitchat-originated files are the upstream merge surface. Minimizing diffs in them keeps cherry-picks and rebases tractable. The rules:

- **Never add new methods or properties directly to core bitchat files** (`ChatViewModel.swift`, `PrivateChatManager.swift`, `GeohashParticipantTracker.swift`, `BLEService.swift`, `NoiseProtocol.swift`, `BinaryProtocol.swift`, etc.). All SafeGuardian-specific logic must live in extension files (`ChatViewModel+Nova.swift`, `ChatViewModel+AgentContext.swift`, etc.) or new SafeGuardian-owned files.
- **Never add `@MainActor` or change concurrency isolation on upstream classes.** Upstream may add code with different isolation assumptions and the merge will conflict or silently break. `PrivateChatManager` is NOT `@MainActor` — do not annotate it as such.
- **Never widen access modifiers on upstream symbols without a live caller.** Changing `private` to `internal` on a property that nothing external reads is a pointless upstream diff. Only loosen access when a concrete SafeGuardian call site actually requires it, and note the reason in a comment.
- The only acceptable changes to a core bitchat file are: (a) a single wired-up call site for a new SafeGuardian feature, and (b) the minimum stored-property and init wiring that Swift extensions cannot express.
- **SafeGuardian Extensions**: The 150-line modularity rule and architectural refactors (like the Command Registry) apply ONLY to SafeGuardian-specific additions (e.g., Nova features, WorldGraph integration, QR verification, and newly created UI components).

## Agent System (Nova / AgentProcessor)

The agent abstraction lives in `SafeGuardian/Protocols/AgentProcessor.swift`. `AgentContext` is the restricted interface agents use to interact with `ChatViewModel`. `ChatViewModel` conforms to it via `ChatViewModel+AgentContext.swift`.

When adding or modifying agents:
- `AgentContext.notifyChange()` maps to `objectWillChange.send()`. Do NOT name any protocol method `objectWillChange` — that shadows the `ObservableObject` publisher and breaks conformance.
- `ChatViewModel.sendMessage` is responsible for recording the user's turn in `privateChats[NovaAgent.novaPeerID]` before calling `novaAgent.handle`. The agent itself only appends the response via `context.addResponse`. Never delete this user-turn recording step or multi-turn history and the DM view will break.
- `NovaAgent` receives the prompt already stripped of the `@nova ` trigger prefix. The double-strip logic in `handle` is harmless but unnecessary; do not add additional stripping layers.

## Nova / MLX Inference Guardrails

The current Nova inference path is `MLXInferenceService` -> `NovaInferenceCoordinator` -> `MLXModelLoader` + `NovaSessionPool`. Do not restore older notes that built inference directly inside `ChatViewModel+Nova`.

- Use `ChatSession.streamResponse(to:)` for text generation. Do not use direct `container.perform` generation for chat unless there is a specific lower-level MLX task and the Sendable/cancellation behavior has been reviewed.
- Runtime state such as battery, GPS, geohash, peer count, or transport tier must not be part of the stable system prompt. Inject it as per-turn context in the user prompt so `ChatSession` reuse and KV cache behavior stay stable.
- Do not use `Memory.cacheLimit`. The MLX API is `MLX.GPU.set(cacheLimit:)`; prefer an active/idle memory policy over one global cache limit when changing this area.
- Treat model loading, session reuse, and model release as lifecycle-sensitive code. A model container must not be invalidated while inference is still unwinding; cancellation should be awaited before dropping sessions or containers.
- `MLXModelLoader` must be keyed by model ID before adding richer model switching. Returning a loaded container for a different requested model is a correctness bug.
- `NovaAgent` token streaming should avoid per-token main-thread churn where practical. Keep the O(1) `<think>...</think>` drain, but batch UI updates if generation volume grows.

## Package Integration

Xcode project package edits are fragile. Before editing `SafeGuardian.xcodeproj/project.pbxproj`, check for duplicate package object IDs and stale product comments.

- `swift-transformers` exposes the package product `Transformers`; `Tokenizers` is an importable module, not the product name to add to the target.
- If evaluating AnyLanguageModel, do not try to add Swift package traits directly to the Xcode target. Xcode does not provide a first-class traits UI. Use a local Swift 6.1 shim package that depends on AnyLanguageModel with the required traits, then add that local package to the app target.
- Keep `safeguardian-ios/Package.swift`, Xcode deployment targets, and MLX requirements aligned. MLX and `@Observable` require macOS 14 in this project path.

## IPC / TUI Socket Host

`SafeGuardianIPCHost` manages the Unix socket at `~/Library/Application Support/chat.safeguardian/tui.sock` (macOS only). Each connected client gets its own `AnyCancellable` set stored in `clientCancellables[socket]`, which is removed in `closeClient`. Never store subscriptions in a single shared `cancellables` set — doing so causes subscriptions to accumulate across connections and double-fire events for every subsequent client.

## macOS Build

The Tor xcframework (`libarti_bitchat.a`) ships arm64 only. Any macOS `xcodebuild` invocation must include `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` or the linker will fail trying to find an x86_64 slice. The Justfile `build` and `dev-run` recipes already include these flags. Do not remove them.

## Conventions
- **Naming**: Always use `SafeGuardian` prefix for types (e.g., `SafeGuardianMessage`, `SafeGuardianPacket`) and file paths. Avoid legacy `Bitchat` or `bitchat` naming in new code or documentation.
- **Test Harness**: Use `MockBLEService` in `SafeGuardianTests/Mocks/` for integration testing. Always call `MockBLEService.resetTestBus()` in `setUp()`.
- **Refactoring & Modularity**: When splitting files to adhere to the 150-line limit:
    - Proactively promote `private` or `fileprivate` symbols used across files to `internal` (by removing the access modifier).
    - Move extensions to the home file of the type they extend (e.g., `ChannelID` extensions should live in `LocationChannel.swift`).
    - Always run a build immediately after splitting files to verify module-wide visibility.
