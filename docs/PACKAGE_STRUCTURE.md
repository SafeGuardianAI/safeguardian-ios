# nova-ios Package Structure

The iOS app is composed of one application target (`SafeGuardian`) and six local Swift packages under `localPackages/`. The packages follow a strict dependency order: no package imports another package from this list except where noted. All packages are available to both the iOS and macOS targets unless marked iOS-only.

---

## shared/BitFoundation (referenced as `../../shared/BitFoundation` in Package.swift)

The lowest-level shared types package. Every other package and the main target may import it; it imports nothing from this list. Provides the canonical wire and message types used across all transport and UI layers. Not in `localPackages/` — it lives in the monorepo's `shared/` directory and is shared byte-for-byte between nova-ios and trek-ios.

`SafeGuardianMessage` — the in-memory message model with sender, content, timestamp, delivery status, and optional senderPeerID. Carries an NSCache-backed formatted-text cache keyed by (isDark, isSelf) to avoid redundant AttributedString construction on scroll.

`SafeGuardianPacket` and `SafeGuardianFilePacket` — the BLE binary wire types. `SafeGuardianPacket` encodes to the v2 binary format with type, TTL, sender, nonce, and payload. `SafeGuardianFilePacket` wraps binary file data with a MIME type and filename for mesh file transfer.

`PeerID` — a typed wrapper around a peer identifier string with helpers for geo-DM detection, Nostr public key extraction, geohash channel association, and percent-encoding for deep links.

`GeohashChannel` — a channel discriminant that carries either `.mesh` (the global public channel) or `.location(GeohashChannelInfo)` (a geohash-scoped sub-channel).

Supporting types: `MessageType`, `DeliveryStatus`, `BinaryProtocol`, `BinaryEncodingUtils`, `CompressionUtil`, `MessagePadding`, `FileTransferLimits`, `Geohash`, and extension files for `Data+Hex`, `Data+SHA256`, `String+Ext`.

---

## shared/BitLogger (referenced as `../../shared/BitLogger` in Package.swift)

Thin secure logging wrapper. Exports `SecureLogger` which routes through `OSLog` with category-keyed subsystems. Sanitizes sensitive strings (peer IDs, message content) before emission. The `OSLog+Categories` file enumerates all log categories used across the app. Not in `localPackages/` — lives in the monorepo's `shared/` directory alongside BitFoundation.

---

## localPackages/AgentInfra

The agent inference abstraction layer. The main target and any agent feature may import this; it imports BitFoundation.

`AgentLanguageProvider` — the protocol that both `MLXInferenceCoordinator` and `RemoteInferenceService` implement. Defines `generate(input:) -> AsyncStream<AgentGenerationEvent>`, `isModelLoaded`, `isLoading`, `activeModelID`, and `capabilities`.

`AgentPromptInput` — the value type passed to `generate`. Carries `text: String`, `imageData: [Data]` (populated for vision requests), `history: [ConversationTurn]`, `systemPrompt: String`, `toolRegistry: (any Sendable)?`, `threadID: String?`, `tick: NovaStateTick?`, and `isMeshQuery: Bool`.

`AgentGenerationEvent` — the stream element enum: `.status(String)`, `.token(String)`, `.stats(AgentGenerationStats)`, `.toolCall(name:String, callID:String, args:String)`, `.complete`, `.failure(String)`.

`ConversationTurn` and `ContextCompressor` — history representation and windowing. `ContextCompressor.compactIfNeeded` keeps the most recent N turns within a token budget by dropping old turns from the front.

`PromptBudgetService` — computes `recommendedTurnCount` for a given model ID based on its context window.

`AgentTranscriptionProvider` — protocol implemented by `SpeechInferenceCoordinator` (WhisperInfra) to allow the agent layer to trigger transcription without importing WhisperInfra directly.

Gates (`AgentGate`, `AgentGateRegistry`, `BatteryGate`) — pre-inference checks. `BatteryGate` blocks inference below 5% battery with the device unplugged. Additional gates can be registered without touching the engine.

`GenerationTypes` — `ModelCapabilities` struct (hasThinkingMode, noThinkSuffix, supportsToolCalling, supportsVision) and `modelCapabilities(for:)` which maps known model IDs to their flags.

---

## localPackages/WhisperInfra

On-device Whisper speech-to-text. Imports nothing from this list. iOS and macOS targets both include it, but in stub mode by default (no model file present). Run `scripts/fetch_whisper.sh` to download the model binary and activate real inference.

`SpeechInferenceCoordinator` — the public entry point. `transcribe(audioSamples:[Float]) async -> String?` runs whisper on 16 kHz mono float samples. `downsample(_:from:) -> [Float]` is a static utility that linearly resamples an arbitrary-rate mono float buffer to 16 kHz for feeding into whisper. Conforms to `AgentTranscriptionProvider`.

`WhisperModelManager` — manages model file download, caching, and device-appropriate model selection (`tiny`, `base`, `small` tiers based on available RAM). Records benchmarks per run.

`WhisperContext` — wraps the C++ whisper.cpp inference context. `transcribeSync(samples:[Float]) -> [String]` is synchronous and called from a background queue by `SpeechInferenceCoordinator`.

---

## localPackages/FieldMesh — REMOVED

This package has been removed from the project. It is not referenced in `Package.swift` and the `localPackages/FieldMesh/` directory no longer exists. The active Reticulum implementation is the pure-Swift hand-rolled stack at `shared/SafeGuardianMesh/`, consumed via `path: "../../shared/SafeGuardianMesh"` in Package.swift.

---

## localPackages/Arti

Pre-built Tor integration via the `arti-bitchat` Rust XCFramework. Not rebuilt from source in this repo; the `libarti_bitchat.a` binary is checked in directly. Provides `TorManager` (circuit lifecycle), `TorURLSession` (a URLSession-compatible HTTP client routed through Tor), and `TorNotifications` (circuit status observation).

---

## Main target: SafeGuardian/

The application target organized into functional feature directories.

`Features/nova/` — the Nova agent. `AgentConversationEngine` is the central `@MainActor` class that owns gate evaluation, history assembly, `AgentPromptInput` construction, stream event processing, and conversation logging. `MLXInferenceCoordinator` implements `AgentLanguageProvider` via `MLXLMCommon.ChatSession`. `RemoteInferenceService` implements `AgentLanguageProvider` via OpenAI-compatible SSE streaming. `AgentProviderRegistry` holds the active provider reference. `Tools/` contains one file per tool; `AgentToolRegistry+AllTools.swift` registers them.

`Features/ReticulumTest/` — `ReticulumTestView` (DEBUG + iOS only) provides a live console for the FieldMesh layer: start/stop node, send LXMF messages by destination hex, view streamed events. Accessible from AppInfoView under the "mesh transport" section.

`Features/voice/` — `VoiceRecorder` (AVAudioRecorder wrapper), `VoiceRecordingViewModel` (state machine for the hold-to-record gesture), `VoiceNotePlaybackController` and `VoiceNotePlaybackCoordinator` (playback of received voice notes from peers).

`Services/BLE/` — `BLEService`: the core Bluetooth LE peripheral and central manager. Handles discovery, packet fragmentation, Noise handshake initiation, and mesh relay.

`Services/Reticulum/` — `ReticulumTransport`: the existing RNode BLE/RF transport using the RNS NUS service UUID. Separate from FieldMesh; requires physical RNode hardware. `MeshAgentRegistry` and `LXMFToolRouter` handle agent-to-agent LXMF tool call routing over the RNode transport.

`Services/Nostr/` — relay connections, subscription management, NIP-04 DM encryption, geohash relay selection.

`ViewModels/ChatViewModel.swift` and `ViewModels/Extensions/` — the primary observable driving all UI state. Extensions split concerns: `ChatViewModel+PrivateChat` handles peer DMs, file transfers, and voice note send; `ChatViewModel+Nostr` handles relay subscriptions; `ChatViewModel+Tor` handles Tor circuit integration.

`Views/ContentView.swift` — root navigation container, message list orchestration, unified composer (text field + camera attachment + mic/send button). The composer routes identically for all chat contexts; agent-specific behavior is expressed through branching on `viewModel.isInAgentDM` inside `sendMessage()` and `transcribeAndSendToAgent(at:)`.
