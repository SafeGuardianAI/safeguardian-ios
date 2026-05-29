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

    struct AgentPromptInput:
        text:         string
        tick:         NovaStateTick|null
        toolRegistry: AgentToolRegistry|null  -- null when model does not support tools

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

## AgentToolRegistry

A resolved, ready-to-use tool set. Created once per generation call while the
agent context is available; passed through the provider chain into the session.

    struct AgentToolRegistry:
        specs:    list<ToolSpec>       -- JSON schema objects understood by the model
        dispatch: async (ToolCall) -> string  -- routes to the correct handler

## AgentContextProxy

Provides safe async access to MainActor (or platform-equivalent UI-thread-isolated)
agent context from within a background inference task. On each platform this is the
bridge between the inference thread and the UI/application thread.

    interface AgentContextProxy:
        meshPeerIDs() -> async set<PeerID>
        deviceTick()  -> async NovaStateTick|null
        sendMesh(toAgentID: string, content: string, peerID: PeerID) -> async void

## AgentMeshRouting

Wire format for agent-to-agent private messages over the BLE mesh.
Content prefix that allows the receiving device to route the message to a
local agent instead of displaying it in the human UI.

    format:  "[AGENT:{agentID}] {content}"
    example: "[AGENT:nova] what is structural status at sector 4?"

    parse(raw: string) -> (agentID: string, content: string)|null
    format(agentID: string, content: string) -> string

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
        notifyChange() -> void
        sendMeshMessage(agentID: string, content: string, to: PeerID) -> void

## AgentProcessor

The agent itself. One per agent type (Nova, Trek) per device.

    interface AgentProcessor:
        agentID:       string   -- "nova", "trek"
        displayName:   string   -- "Nova", "Trek"
        triggerPrefix: string   -- "@nova", "@trek"
        peerID:        PeerID   -- local address for this agent's private thread

        shouldHandle(message: string) -> bool
        handle(prompt: string, context: AgentContext) -> void

## ModelDownloadManager

Cache introspection and management for on-device model files.
Does not initiate downloads — downloads happen on first inference.

    interface ModelDownloadManager:
        cachedModelIDs()                       -> list<string>
        cachedSize(modelID: string)            -> int|null        -- bytes, null if not cached
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
            agentThread:    list<Message>,
            systemPrompt:   string,
            agentSenderID:  string,
            providerID:     string,
            tick:           NovaStateTick|null,
            startedAt:      datetime,
            thinkingContent: string|null,
            stats:          AgentGenerationStats|null
        ) -> void

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
