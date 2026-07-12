# SafeGuardian: Hybrid Multi-Tiered Mesh Architecture

Status: conceptual target architecture, not a current implementation inventory.

| Functional Claim | Status | Code Evidence |
| --- | --- | --- |
| BLE mesh, Noise, Nostr, and SafeGuardian app code exist. | verified | `SafeGuardian/Services/`, `SafeGuardian/Noise/`, `SafeGuardian/Nostr/`, and tests. |
| Nova agent with MLX on-device inference. | verified | `SafeGuardian/Features/nova/MLXInferenceCoordinator.swift`, `AgentConversationEngine.swift`. |
| Nova agent with remote OpenAI-compatible inference. | verified | `SafeGuardian/Features/nova/RemoteInferenceService.swift`. |
| Nova vision input (image → model). | verified | `AgentConversationEngine` passes `imageData` as `[Data]`; `MLXInferenceCoordinator` converts to `CIImage`; `RemoteInferenceService` encodes as base64 data-URI in multipart content array. |
| Nova voice input via Whisper STT. | verified | `ContentView.transcribeAndSendToAgent` decodes AVAudioFile → PCM → `SpeechInferenceCoordinator.transcribe` → `sendMessage`. |
| Reticulum TCP transport via reticulum-rs XCFramework. | removed | `localPackages/FieldMesh/` is no longer present; Package.swift does not reference it. The active Reticulum implementation is the pure-Swift stack in `shared/SafeGuardianMesh/`. |
| Reticulum RNode BLE transport (existing). | verified | `SafeGuardian/Services/Reticulum/ReticulumTransport.swift`, `MeshAgentRegistry.swift`, `LXMFToolRouter.swift`. |
| Whisper STT package. | verified | `localPackages/WhisperInfra/` — `SpeechInferenceCoordinator`, `WhisperModelManager`, `WhisperContext`. Stub mode by default; `scripts/fetch_whisper.sh` activates real inference. |
| Tor integration. | verified | `localPackages/Arti/` — pre-built XCFramework; `TorManager`, `TorURLSession`. |
| UWB/NearbyInteraction routing. | planned | No `NearbyInteraction`/UWB implementation found in source. |
| MultipeerConnectivity burst routing. | planned | No MPC burst transport implementation found. iOS 26 dropped AWDL peer-to-peer without infrastructure. |
| libp2p bridge. | aspirational | No libp2p implementation in this repository. |
| Drone/satellite relay path. | aspirational | No runtime integration found in this repository. |

The claim table above is the authoritative status record. Items marked "planned" or "aspirational" have no implementation in this repository.
