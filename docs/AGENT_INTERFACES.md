# SafeGuardian Agent Interface Specification

Language-agnostic interface definitions for the Nova/Trek/Apex agent layer.
Implement these contracts on each platform (iOS Swift, Android Kotlin, Linux Python, macOS Swift)
so the agent runtime behaves identically regardless of skin. Pseudocode notation — map
to idiomatic types in each target language.

---

## AgentGenerationEvent

Events emitted by an inference provider during a single generation call.
The consumer processes them sequentially in a single loop.

    enum AgentGenerationEvent:
        status(text: string)          -- human-readable loading/init status
        token(text: string)           -- one decoded token from the model
        stats(AgentGenerationStats)   -- emitted once, after last token, before complete
        complete                      -- generation finished normally
        failure(reason: string)       -- generation failed; no complete follows

## AgentGenerationStats

Provider-reported performance metrics for one generation call.

    struct AgentGenerationStats:
        promptTokens:      int      -- tokens consumed by the prompt
        generationTokens:  int      -- tokens produced
        promptMs:          float    -- time to process prompt in milliseconds
        generateMs:        float    -- time to generate output in milliseconds
        tokensPerSecond:   float    -- generationTokens / (generateMs / 1000)
        promptTPS:         float    -- promptTokens / (promptMs / 1000)

## ModelCapabilities

Flags describing what a specific model ID supports.

    struct ModelCapabilities:
        hasThinkingMode:     bool         -- model produces <think>...</think> blocks
        noThinkSuffix:       string|null  -- append to user message to suppress thinking
        supportsToolCalling: bool         -- model reliably emits tool call JSON (>=3B params)

## AgentProviderCapabilities

Flags describing the provider itself (transport, network dependency).

    struct AgentProviderCapabilities:
        requiresNetwork:   bool
        modelCapabilities: ModelCapabilities|null  -- null until a model is loaded

## AgentPromptInput

Input to a single inference call.

    struct ConversationTurn:
        role:    "user" | "assistant"
        content: string

    struct AgentPromptInput:
        text:         string
        tick:         NovaStateTick|null
        systemPrompt: string                  -- composed at call time: base prompt + optional user personalization blurb
        history:      list<ConversationTurn>  -- windowed prior turns, oldest first; excludes current user message
                                              -- assembled by the agent layer, capped at NovaConfig.historyWindowSize
        toolRegistry: AgentToolRegistry|null  -- null when model does not support tools
        isMeshQuery:  bool                    -- true when prompt originated from a remote peer via AgentMeshRouting

## AgentGateContext

Lightweight value type assembled at call time, passed to every pre-inference gate.
Contains only what gates need — no access to the full AgentContext.

    struct AgentGateContext:
        prompt:      string
        tick:        NovaStateTick|null
        isMeshQuery: bool    -- false for local @agent queries; mesh gates must not fire for local queries
        modelID:     string

## AgentGate

A pure synchronous predicate evaluated before provider.generate() is called.
Must complete in microseconds — no async, no model calls, no network access.
If any gate returns false, handle() returns immediately without touching the
inference stack.

    interface AgentGate:
        name:   string    -- used in diagnostics and gate skip logging
        passes(context: AgentGateContext) -> bool

## AgentGateRegistry

Evaluates all registered gates against a context. Returns true only if all pass.
standard() returns the default set; callers may also construct a custom registry.

    struct AgentGateRegistry:
        gates: list<AgentGate>
        shouldHandle(context: AgentGateContext) -> bool  -- allSatisfy { $0.passes(context) }

        static standard() -> AgentGateRegistry

Standard gates:

- BatteryGate: passes when tick.batteryPct >= threshold, or when isMeshQuery == false
- CapabilityGate: passes when device capability flags cover the request type (future)

## AgentLanguageProvider

The single interface for all inference backends (MLX, Ollama, OpenAI, Anthropic, etc.).

    interface AgentLanguageProvider:
        id:           string   -- e.g. "mlx", "ollama", "openai"
        displayName:  string
        capabilities: AgentProviderCapabilities
        isLoading:    bool
        isModelLoaded: bool

        generate(input: AgentPromptInput) -> Stream<AgentGenerationEvent>
        cancel() -> void

## AgentToolEntry

A single tool the model can call.

    struct AgentToolEntry:
        name:        string
        description: string
        parameters:  list<ToolParameter>
        handler:     async (arguments: map<string, JSONValue>, context: AgentContextProxy) -> string

## DispatchGuard

Counts tool dispatches within one generation session. When the cap is reached,
the dispatch closure returns a terminal error string so the model stops looping
rather than running indefinitely. Sequential dispatch (MLXLMCommon awaits each
result before calling the next) means the counter needs no lock.

    class DispatchGuard:
        next() -> bool   -- increments counter; returns false when cap is exceeded

Cap is NovaConfig.maxToolIterations (8). Embedded in AgentToolRegistry.build.

## StatusCallback

Accumulates tool names called during a session and fires a MainActor status
update for each so the UI can show "get_device_state..." rather than a static
spinner. calledToolNames is read at completion and logged by ConversationLogger.

    class StatusCallback:
        calledToolNames: list<string>          -- populated in dispatch order
        notify(toolName: string) -> async void -- updates UI, appends name

## AgentToolRegistry

A resolved, ready-to-use tool set. Build one per inference call.
The dispatch closure embeds DispatchGuard, StatusCallback, and approval gate.

    struct AgentToolRegistry:
        specs:    list<ToolSpec>
        dispatch: async (ToolCall) -> string

    static build(
        agentID, context, deviceTools, meshTools,
        onStatus: StatusCallback|null,
        approvalCheck: (string -> bool)|null,
        maxIterations: int = NovaConfig.maxToolIterations
    ) -> AgentToolRegistry

## AgentContextProxy

Bridges @MainActor-isolated AgentContext into @Sendable tool dispatch closures.
All MainActor state access routes through MainActor.run.

    interface AgentContextProxy:
        meshPeerIDs() -> async set<PeerID>
        deviceTick()  -> async NovaStateTick|null
        sendMesh(toAgentID: string, content: string, peerID: PeerID) -> async void
            -- fire-and-forget; reply goes to human DM thread
        requestFromAgent(agentID: string, content: string, peerID: PeerID) -> async string
            -- correlated request; suspends until [AGENT_REPLY:..:{requestID}] arrives
        requestFromPeer(type: string, peerID: PeerID) -> async string
            -- Pattern 1 structured request; suspends until [REQUEST_RESPONSE:...] arrives
        requestApproval(for toolName: string) -> async bool
            -- suspends via CheckedContinuation until host context resumes it;
            -- safe from any isolation context; approval UI wired on AgentContext

## AgentMeshRouting

Wire formats for agent-directed messages over the BLE mesh. Three distinct
interaction patterns share this routing layer and each carries its own prefix.
The receiving device inspects the prefix to determine whether to route to an
agent, surface a consent prompt, or continue an existing agent session.

### Pattern 1 — Structured Peer Request (no inference, explicit consent)

A typed RPC for data or actions that require human approval on the receiver.
No model runs on the receiving side. The receiver shows a system-level permission
prompt; if approved, it returns a structured response. The initiating agent
receives the result as a tool call return value.

    send:    "[REQUEST:{type}:{requestID}] {params JSON}"
    reply:   "[REQUEST_RESPONSE:{requestID}] {result JSON | "denied"}"

    example: "[REQUEST:location:abc123] {}"
    example: "[REQUEST_RESPONSE:abc123] {"lat":37.33,"lon":-122.03}"

### Pattern 2 — Agent One-Shot Query (inference on receiver, stateless)

A question routed to a named agent on the receiving device. The receiving agent
runs inference once and replies. No shared session state. Pre-inference gates
on the receiver determine whether inference runs at all (battery, capability).

Two sub-forms exist depending on whether the sender expects a correlated reply:

Fire-and-forget (human initiates, reply shown in human DM thread):

    format:  "[AGENT:{agentID}] {content}"
    reply:   "[AGENT_REPLY:{agentID}] {content}"
    example: "[AGENT:nova] what is structural status at sector 4?"

Correlated request (agent-to-agent, reply resumes a tool call continuation):

    format:  "[AGENT:{agentID}:{requestID}] {content}"
    reply:   "[AGENT_REPLY:{agentID}:{requestID}] {content}"
    example: "[AGENT:nova:a3f9b2c1] summarise your sensor log"

    When requestID is present on the reply, the receiving device checks
    pendingAgentReplies[requestID]. If a continuation is waiting, it is resumed
    with the reply content as the tool call return value and the message is never
    shown in the human UI. If no continuation exists (sender disconnected etc.),
    the reply falls through to the DM thread.

    parse(raw: string) -> (agentID: string, content: string, requestID: string|null)|null
    format(agentID: string, content: string, requestID: string|null) -> string

On the receiver, inference runs silently for mesh queries (no placeholder in the
local agent thread). The reply is sent back only to the originating peer.

### Pattern 3 — Agent Session (inference on both sides, shared context)

A multi-turn agent-to-agent exchange. Both sides maintain per-session
conversation history keyed by sessionID. Sessions have a maximum turn count
and idle timeout. Session initiation requires one-time human approval on the
receiving side; subsequent turns do not.

    format:  "[AGENT_SESSION:{sessionID}:{agentID}] {content}"
    example: "[AGENT_SESSION:s7f2a:nova] I have northern sector structural data."

    Session history is stored separately from the human Nova thread and is
    not displayed in the chat UI unless the human explicitly opens the session
    transcript view.

## AgentContext

Interface through which an agent interacts with the application. On iOS this is
satisfied by ChatViewModel; on Android by a ViewModel; on headless Linux by a
session object. Only expose what agents actually need.

    interface AgentContext:
        nickname:     string
        privateChats: map<PeerID, list<Message>>
        deviceTick:   NovaStateTick|null
        selectedGeohash: string|null
        meshPeerIDs:  set<PeerID>

        addLocalMessage(content: string) -> void
        addAgentLocalMessage(content: string, to: PeerID) -> void
        addResponse(sender: string, content: string, privatePeerID: PeerID|null) -> Message
        removeResponse(response: Message, from: PeerID) -> void
        notifyChange() -> void
        sendMeshMessage(agentID: string, content: string, to: PeerID, requestID: string|null) -> void
        sendMeshReply(agentID: string, content: string, to: PeerID, requestID: string|null) -> void
        broadcastAgentMessage(agentID: string, content: string) -> void
        sendPeerRequest(type: string, requestID: string, to: PeerID) -> void
        registerPeerRequestContinuation(requestID: string, continuation) -> void
        registerAgentReplyContinuation(requestID: string, continuation) -> void
        registerToolApprovalContinuation(token: string, continuation) -> void
            -- store continuation keyed by token; resume with bool to approve/deny;
            -- current impl auto-approves; swap body to show UI when ready

## AgentConversationConfig

Everything specific to one agent. The single value a conformer must supply.
All identity properties and behavior are derived from this by the protocol extension.

    struct AgentConversationConfig:
        agentID:      string
        displayName:  string
        peerID:       PeerID
        triggerPrefix: string
        systemPrompt: () -> string
            -- evaluated at call time; may safely read MainActor-isolated state
        toolRegistry: ((AgentContext, StatusCallback, (string->bool)|null) -> AgentToolRegistry|null)|null
            -- receives engine-created StatusCallback and approvalRequired predicate
        approvalRequired: (string -> bool)|null
            -- return true for tool names that require human approval before executing;
            -- nil means all tools auto-approved; suspension uses CheckedContinuation
        shouldSendResponse: (string -> bool)|null
            -- evaluated against final visible output; return false to suppress response
            -- and remove placeholder cleanly; nil means always send

## AgentConversationEngine

Singleton that owns all generic agent execution mechanics: gate evaluation,
history assembly (budget-aware via PromptBudgetService), AgentPromptInput
construction, stream processing (think-tag draining gated on hasThinkingMode),
tool loop controls, mesh reply routing, and ConversationLogger.

Tool loop controls built into every call:
- DispatchGuard caps iterations at NovaConfig.maxToolIterations (8)
- StatusCallback updates response.content with the active tool name for UI feedback
- approvalRequired predicate from config gates individual tools via CheckedContinuation
- shouldSendResponse predicate suppresses and removes the response placeholder cleanly

Mesh queries run inference silently — no local placeholder on receiving device.
The reply is sent to the requester only (with optional requestID for agent-to-agent
correlated responses).

    handle(prompt, config, context, replyTo, replyID) -> void

## AgentProcessor

Single-requirement protocol. All identity properties and handle/shouldHandle
are provided by the protocol extension; conformers only implement conversationConfig.

    protocol AgentProcessor:
        conversationConfig: AgentConversationConfig

    -- derived by extension:
        agentID, displayName, peerID, triggerPrefix
        shouldHandle(message: string) -> bool
        handle(prompt, context, replyTo, replyID) -> void

## Agent

Concrete AgentProcessor. New agents are static instances — no subclass needed.

    struct Agent: AgentProcessor:
        conversationConfig: AgentConversationConfig

    Agent.nova  -- the Nova assistant

## PromptBudgetService

Actor that tracks per-model context window sizes and prompt token usage to produce
adaptive history window recommendations. Replaces the fixed historyWindowSize ceiling
with one that reacts to measured token consumption.

    actor PromptBudgetService:
        register(modelID: string) -> async void
            -- called after model loads; reads max_position_embeddings from config.json
        record(modelID: string, promptTokens: int, historyTurnCount: int) -> async void
            -- called after each completed generation
        recommendedTurnCount(modelID: string) -> async int
            -- returns turn count that fits within 80% of context window minus 512-token reserve;
            -- proportionally scales down if last prompt exceeded the budget

## ModelDownloadManager

Cache introspection and management for on-device model files.
Does not initiate downloads — downloads happen on first inference.

    interface ModelDownloadManager:
        cachedModelIDs()                       -> list<string>
        cachedSize(modelID: string)            -> int|null        -- bytes, null if not cached
        contextWindowSize(modelID: string)     -> int|null        -- reads max_position_embeddings from cached config.json
        estimatedDownloadSize(modelID: string) -> int             -- bytes, pattern-matched
        hasStorageForDownload(modelID: string) -> bool            -- 1.2x safety margin
        evict(modelID: string)                 -> void|error

## ConversationLogger (DEBUG only — must not ship in Release)

Appends one JSONL entry per completed agent exchange.
Gate with compile-time debug flag on every platform.

    interface ConversationLogger:
        logFilePath:   string
        logDirPath:    string
        entryCount:    int
        fileSizeString: string
        format:        LogFormat   -- "jsonl" (OpenAI) | "sharegpt"

        record(
            agentThread:     list<Message>,
            systemPrompt:    string,
            agentSenderID:   string,
            providerID:      string,
            tick:            NovaStateTick|null,
            startedAt:       datetime,
            thinkingContent: string|null,
            toolCallNames:   list<string>,   -- tools dispatched in order; empty if none
            stats:           AgentGenerationStats|null
        ) -> void
        -- toolCallNames appear in metadata.tool_calls in the output entry

        clear() -> void

    enum LogFormat: "jsonl" | "sharegpt"

## DeviceTools (pure functions — no context required)

    availableStorageBytes() -> int64
    totalStorageBytes()     -> int64
    availableMemoryBytes()  -> int    -- os_proc_available_memory on iOS; platform equiv elsewhere
    totalMemoryBytes()      -> int

## NovaStateTick

Behavioral state observation broadcast by a Nova agent over the mesh.
Maps to the nova.state_tick ADSP atom schema.

    struct NovaStateTick:
        lat:                 float
        lon:                 float
        locationConfidence:  float   -- 0.0–1.0, decays linearly over 5 minutes
        locationSource:      "gps" | "derived" | "reported"
        medicalStatus:       "unknown" | "uninjured" | "minor" | "serious" | "critical"
        structuralObservations: list<string>
        batteryPct:          float   -- 0.0–1.0
        transportTier:       "ble_coded" | "halow" | "lora" | "tcp"
        peerCount:           int
        tickSequence:        int
        confidenceAtEmit:    float
