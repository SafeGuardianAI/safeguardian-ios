# Nova Agent Tools

Nova's tool registry is built in `SafeGuardian/Features/nova/Tools/` and wired in `AgentToolRegistry+AllTools.swift`. Tools are only injected into the model when the active model reports `supportsToolCalling: true` in `GenerationTypes.modelCapabilities(for:)`. As of June 2026 this requires Qwen2.5 ≥ 1.5B or Qwen3 ≥ 1.7B; the 0.5B variants do not reliably follow function-calling format.

Each tool is a file in `Tools/` containing one `AgentToolEntry` extension. The registry collects them in `AgentToolRegistry+AllTools.swift`. Adding a new tool means creating one file and adding one line to that registry — nothing else changes.

---

## Device tools

These tools read or modify the state of the local device. None require mesh connectivity.

### get_status
Device state and connected peer list in one call. Preferred over calling `get_device_state` and `list_peers` separately.
Parameters: none.

### get_device_state
Returns battery level, location confidence, peer count, and transport tier.
Parameters: none.

### get_full_status
Device state, peer list, storage, and RAM in one call. Use before recommending or initiating a model download.
Parameters: none.

### get_storage
Returns available device storage. Check before recommending a model download.
Parameters: none.

### get_memory
Returns available device RAM. Check before loading a large model.
Parameters: none.

### get_mesh_load
Returns mesh packet rate, peer count, saturation percentage, and the current tick interval and TTL. High saturation means the mesh is congested; reduce tick frequency and TTL to conserve bandwidth. Low saturation means spare capacity exists.
Parameters: none.

### set_tick_interval
Sets Nova's state tick broadcast interval in seconds (clamped 30–300). Higher interval means fewer ticks and less mesh bandwidth consumed. Only reduce the interval when saturation is low and fresher state is operationally necessary.
Parameters: `interval_seconds` (string) — seconds between ticks.

### set_message_ttl
Sets the hop limit for Nova's outgoing mesh ticks (clamped 3–7). Lower TTL means fewer relay hops and less total mesh bandwidth. Use lower values in dense meshes or when saturated; only raise TTL in sparse meshes where peers cannot be reached in fewer hops.
Parameters: `ttl` (string) — hop limit.

---

## Mesh tools

These tools operate on the BLE mesh: discovering peers, routing messages, and coordinating incidents.

### list_peers
Returns the peer IDs of devices currently connected on the BLE mesh. Use these IDs with `send_agent_message` or `broadcast_to_agents`.
Parameters: none.

### send_agent_message
Sends a private message to a named agent on a specific peer device. The message is routed to that agent and never shown in the human chat.
Parameters: `agent_id` (string) — target agent, e.g. `nova` or `trek`; `content` (string) — message text; `peer_id` (string) — recipient peer ID from `list_peers`.

### broadcast_to_agents
Sends a message to a named agent on all currently connected peer devices simultaneously.
Parameters: `agent_id` (string) — target agent on each peer, e.g. `nova`; `content` (string) — message text.

### request_peer_location
Requests the current GPS location from a specific peer. The peer sees a consent prompt. Returns `lat,lon accuracy:Xm`, or `denied` / `unavailable` if they decline or have GPS off.
Parameters: `peer_id` (string) — peer ID from `list_peers`.

### request_mesh_topology
Returns the local mesh topology: this device's direct peers and each of their peer lists, giving a two-hop view of the network.
Parameters: none.

### claim_incident
Registers this Nova agent as the active responder for an incident so other agents on the mesh know it is being handled.
Parameters: `incident_id` (string) — incident identifier from the incident report or EIDO record; `agent_id` (string) — this agent's callsign.

### release_incident
Releases a previously claimed incident so other agents can take it.
Parameters: `incident_id` (string); `agent_id` (string) — must match the original claimant.

### flood_alert
Broadcasts a life-safety alert at maximum TTL (7 hops) to every reachable device on the mesh. This is the highest-priority outbound action available.
Parameters: `message` (string) — alert text, keep under 200 chars, include location if known; `alert_type` (string) — one of `evacuation`, `structural_collapse`, `mass_casualty`, `hazmat`, `other_lifesafety`.

### publish_state_tick
Forces the next StateTick broadcast to fire within 2 seconds rather than waiting for the next scheduled interval.
Parameters: `reason` (string) — brief description of why an immediate tick is needed.

### open_peer_session
Opens a coordination session with a specific peer's Nova agent. Use when a single exchange is not enough — capability negotiation, rendezvous planning, or multi-turn resource coordination. Returns a `session_id` on success.
Parameters: `peer_id` (string) — peer ID from `list_peers`; `purpose` (string) — brief description of the coordination goal.

### peer_session_request
Sends one message on an established peer session and waits for the peer's reply. Use this for each turn of a negotiation after `open_peer_session`.
Parameters: `session_id` (string) — from `open_peer_session`; `content` (string) — message, question, counter-proposal, or confirmation.

### close_peer_session
Closes an open peer session when coordination is complete or no longer needed. Notifies the peer so they can clean up their end.
Parameters: `session_id` (string) — session to close.

---

## Tool dispatch internals

Tool specs are passed to `MLXLMCommon.ChatSession` via the `tools:` and `toolDispatch:` parameters in `MLXSessionPool`. The `ChatSession` calls `toolDispatch` internally when the model emits a tool call, injects the result as a continuation turn, and resumes generation. The engine receives `.toolCall` events as informational notifications only — it does not re-invoke dispatch. The iteration cap (`NovaConfig.maxToolIterations = 8`) is enforced inside the dispatch closure via `DispatchGuard`; when reached, the closure returns a terminal error message that tells the model to stop and produce a final answer.

Tool calls are logged in DEBUG builds through `ConversationLogger` with the called tool names recorded on each session turn.

---

## Input modalities

Nova accepts three distinct input channels that all converge on the same `AgentConversationEngine.handle(prompt:image:...)` entry point.

### Text

The default path. The user types in the Nova DM composer and submits via the send button or Return. The text reaches `ChatViewModel.sendMessage`, which strips the trigger prefix (`@nova`) if present, constructs a display turn in `privateChats[threadPeerID]`, and calls `agent.handle(prompt:image:nil:...)`.

### Voice (Whisper STT)

Holding the microphone button in the Nova DM records audio via `VoiceRecordingViewModel` and `VoiceRecorder`. On release, `ContentView.transcribeAndSendToAgent(at:)` intercepts the completed recording URL instead of routing to `ChatViewModel.sendVoiceNote` (which sends a BLE file transfer). The function opens the M4A file with `AVAudioFile`, reads it into an `AVAudioPCMBuffer` at the file's native sample rate, takes channel 0 as mono float samples, downsamples to 16 kHz with `SpeechInferenceCoordinator.downsample(_:from:)`, and calls `SpeechInferenceCoordinator.shared.transcribe(audioSamples:)`. The resulting string is placed into the message composer and sent as a normal text turn. In stub mode (no Whisper model downloaded) `transcribe` returns nil and the recording is silently discarded. Run `scripts/fetch_whisper.sh` to activate real inference.

### Vision (image attachment)

The camera icon in the Nova DM composer opens `ImagePickerView`. The selected or captured `UIImage` is stored as `ChatViewModel.pendingAgentImage`. A 56×56 thumbnail appears above the input bar as a preview. On send, `ChatViewModel.sendMessage` captures the pending image, encodes it as JPEG at 0.8 quality, and passes the `Data` to `agent.handle(prompt:image:imageData:...)`. `AgentConversationEngine` places it in `AgentPromptInput.imageData` as `[Data]`.

For the on-device MLX path, `MLXInferenceCoordinator` converts each `Data` to a `CIImage` and passes it in the `images:` array to `MLXLMCommon.ChatSession.streamDetails`. This requires a vision-capable model (e.g. `mlx-community/Qwen2-VL-2B-Instruct-4bit`); text-only models will ignore the image array.

For the remote path, `RemoteInferenceService` builds the user message as a multipart content array following the OpenAI vision message format: a `{"type":"text","text":prompt}` part followed by one `{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}` part per image. Any OpenAI-compatible vision endpoint (Ollama with llava/qwen-vl, vLLM, OpenAI GPT-4o) will accept this without configuration changes on the endpoint side.
