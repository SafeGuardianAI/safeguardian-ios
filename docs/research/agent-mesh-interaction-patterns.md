# Agent Mesh Interaction Patterns

Three structurally distinct interaction patterns emerge from the mesh use cases.
They differ in whether inference runs on the receiving side, whether human consent
is required, and whether multiple turns of agent exchange are needed. Each pattern
maps to different wire format requirements, different consent models, and different
what-runs-where guarantees.

---

## Pattern 1: Structured Peer Request (no inference, explicit consent)

The initiating device wants a specific piece of data or action from a peer.
The receiving side does not need to reason about the request — it just needs to
expose the data if the user approves. No model runs on either side for the
request/response cycle itself. This is typed RPC over the mesh with a human
consent gate at the receiver.

Examples: request a peer's current GPS location, request a device status
snapshot, request a file.

Wire format: a new prefix intercepted before the agent layer at the receiver.
The receiver's app intercepts it, surfaces a system-level permission prompt
(not a chat message), and if approved returns a structured response to the
initiator. The initiating device's agent can trigger this via a tool call
(e.g. `request_location(peerID:)`) whose result is the approved data or a
refusal string.

    [REQUEST:{type}:{requestID}] {optional parameters as JSON}
    [REQUEST_RESPONSE:{requestID}] {result JSON or "denied"}

Consent model: explicit per-request human approval on the receiving side.
No inference runs on the receiver. The initiator's agent receives the result
as a tool call return value and can reason about it.

Implementation priority: highest — does not require agent-to-agent infrastructure,
can be built on top of the existing AgentContext.sendMeshMessage path, and is
immediately useful for location/status sharing use cases.

---

## Pattern 2: Agent One-Shot Query (inference on receiver, no session)

The initiating device's agent sends a question to a specific peer's agent.
The receiving agent runs inference and replies once. No shared session state.
This is already partially built via the [AGENT:{agentID}] wire prefix and
the replyTo parameter in AgentProcessor.handle().

The gate system (see below) governs whether the receiving agent actually runs
inference. A receiver that is low on battery, has no relevant capability, or
fails any other pre-inference gate should return nothing — never run inference
and discard the result, which wastes power and tokens.

Consent model: implicit — the initiating human triggered it. No UI shown on
the receiving side beyond the agent's reply appearing in the Nova thread.

---

## Pattern 3: Agent-to-Agent Multi-Turn Session (inference on both sides, shared context)

Both agents participate in a multi-turn exchange without requiring a human
to intervene at each turn. Examples: coordinating a joint status report,
planning a route together using each device's local sensor data, negotiating
a handoff.

This requires a session concept: a shared thread ID that both agents use to
route their turns into the same context window. Without it, agent A has no
way to continue from where agent B left off because there is no shared state.

Wire format extension needed:

    [AGENT_SESSION:{sessionID}:{agentID}] {content}

The receiving agent maintains per-session conversation history separate from
the human Nova thread. Sessions have a maximum turn count and idle timeout
to prevent runaway inference loops. The human can see the session transcript
and interrupt or cancel a running session.

Consent model: session initiation requires explicit approval on the receiving
side (a one-time consent prompt for the session, not per-turn). Per-turn
consent would make the multi-turn pattern unusable.

Implementation priority: lowest — requires the most new infrastructure
(session state, per-session history, wire format, consent UI) and the
Pattern 1 and 2 use cases cover most immediate needs.

---

## Pre-Inference Gate System

Both Pattern 2 and Pattern 3 require the receiving agent to decide whether
to run inference at all before paying the compute cost. The current implementation
had a battery threshold hardcoded directly in `NovaAgent.handle()` and a
post-inference sentinel (SKIP) that burned tokens to decide not to reply.
That approach has been superseded: `AgentGateRegistry` and `BatteryGate` now
evaluate gates before `provider.generate()` is called.

The correct architecture is a gate protocol evaluated before provider.generate()
is called. Every gate is a pure synchronous predicate on AgentGateContext — no
async, no model calls, O(1) evaluation from already-known device state.

    struct AgentGateContext:
        prompt:       string
        tick:         NovaStateTick|null
        isMeshQuery:  bool      -- false for local @nova queries
        modelID:      string

    interface AgentGate:
        name:    string    -- for logging/diagnostics
        passes(context: AgentGateContext) -> bool

    struct AgentGateRegistry:
        gates: list<AgentGate>
        shouldHandle(context: AgentGateContext) -> bool  -- allSatisfy

Standard gates registered by default:

- BatteryGate: passes when batteryPct >= threshold, or when isMeshQuery is false
  (local queries always served regardless of battery)
- CapabilityGate: passes when the requested capability (derived from prompt or
  message type) is advertised in the local device's capability flags

Local (@nova) queries bypass mesh gates entirely — isMeshQuery == false means
no gate can silently drop a user's own query.

To add a new gate: create one file in Features/nova/Gates/, implement AgentGate,
add it to AgentGateRegistry.standard(). No other files change.

The SkipReply tool and SKIP sentinel in the current code are planned for removal
once the gate system is in place. They are a temporary bridge.

---

## Capability Advertising

Semantic relevance filtering belongs on the sender side, not the receiver.
The announce packet already carries agentIDs. Extending it to carry capability
domains (e.g. has-location, has-structural-sensors, battery-ok) lets the
initiating agent route only to peers whose advertised capabilities match the
query type. Receivers that lack the capability are never contacted and never
need to gate-check. The sender side can make this determination for free
using already-received announce data.

This interacts with Pattern 1 directly: a request_location tool call should
check peer capability flags before issuing the REQUEST wire message, so the
human is never shown a consent prompt for a peer that has location disabled.
