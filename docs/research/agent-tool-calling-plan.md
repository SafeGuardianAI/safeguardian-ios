# Agent Tool Calling — Implementation Plan

Date: 2026-05-28

## Architecture

MLXLMCommon's ChatSession already accepts `tools: [ToolSpec]?` and
`toolDispatch: (@Sendable (ToolCall) async throws -> String)?`. ToolCall carries
`function.name: String` and `function.arguments: [String: JSONValue]`.
The dispatch closure is called from ChatSession's internal non-MainActor Task,
so MainActor access inside it requires `await MainActor.run {}`.

Bridge: `AgentContextProxy` is `@unchecked Sendable` with a `@MainActor` init.
It captures context accessors as `@MainActor` closures and exposes them as async
methods using `MainActor.run`. This is safe because we control the threading model
and every access goes through the MainActor.

Flow:
  NovaAgent.handle() [@MainActor]
    → builds AgentToolRegistry(agentID:context:) if model supports tools
    → puts registry in AgentPromptInput.toolRegistry
    → MLXInferenceCoordinator.generate(modelID:input:)
    → MLXSessionPool.session(for:container:systemPrompt:toolRegistry:)
    → ChatSession(..., tools: registry.specs, toolDispatch: registry.dispatch)
    → ChatSession calls toolDispatch from internal task
    → dispatch uses MainActor.run to call context methods

## File Structure

New:
  SafeGuardian/Features/nova/Tools/
    AgentTool.swift           — AgentContextProxy, AgentToolRegistry
    DeviceTools.swift         — storage, RAM, device state tools
    MeshTools.swift           — list_peers, send_agent_message, broadcast_to_agents
  SafeGuardian/Features/nova/Downloads/
    ModelDownloadManager.swift — HF download wrapper with storage pre-check

Modified:
  NovaConfig.swift            — add supportsToolCalling to ModelCapabilities
  AgentLanguageProvider.swift — add modelCapabilities to protocol, toolRegistry to AgentPromptInput
  MLXInferenceService.swift   — implement modelCapabilities
  MLXSessionPool.swift        — accept toolRegistry, pass to ChatSession
  MLXInferenceCoordinator.swift — thread toolRegistry from input to session
  NovaAgent.swift             — build and attach toolRegistry if supported

## Tools

Device (pure — no context):
  get_storage()            → available_bytes, total_bytes, model_cache_bytes
  get_memory()             → available_bytes, total_bytes (os_proc_available_memory)

Device (context-dependent):
  get_device_state()       → battery_pct, location_confidence, peer_count, transport_tier

Mesh (context-dependent):
  list_peers()             → [{id, nickname}] of connected BLE peers
  send_agent_message(agent_id, content, peer_id)   → targeted agent DM
  broadcast_to_agents(agent_id, content)           → sends to all connected peers

## ModelDownloadManager

Wraps LLMModelFactory.shared.loadContainer (already used by MLXModelLoader).
Adds: pre-download storage check, download-only path (no inference), list cached,
evict cached. Storage check estimates model size from a known size table (HF
metadata fetch is async and slow; table is good enough for pre-check).

## Capability Gating

ModelCapabilities gains supportsToolCalling: Bool.
Qwen2.5 >= 3B: true. Qwen2.5-0.5B/1.5B: false (too small for reliable tool calls).
Qwen3 >= 4B: true. DeepSeek-R1 distills >= 7B: true.
Default: false.

AgentProviderCapabilities gains modelCapabilities: ModelCapabilities so NovaAgent
can check tool support without knowing the model ID string.
