// AgentConversationConfig.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import BitFoundation
import Foundation

/// Captures everything that is specific to one agent: its identity and the
/// two decisions it makes at call time — what system prompt to compose and
/// whether to supply a tool registry. Everything else (gate evaluation,
/// history assembly, stream processing, logging) belongs to AgentConversationEngine.
struct AgentConversationConfig: Sendable {
    let agentID: String
    let displayName: String
    let peerID: PeerID
    let triggerPrefix: String

    /// Called at each handle invocation to compose the full system prompt.
    /// Evaluated on MainActor so it may safely read MainActor-isolated state.
    let systemPrompt: @MainActor () -> String

    /// Called only when the active provider's modelCapabilities.supportsToolCalling == true.
    /// Receives the engine-created StatusCallback and the agent's approvalRequired predicate
    /// so each provider can wire them into AgentToolRegistry.build.
    let toolRegistry: (@MainActor (any AgentContext, StatusCallback, (@Sendable (String) -> Bool)?) -> AgentToolRegistry?)?

    /// Return true for a tool name to require human approval before that tool executes.
    /// nil means all tools are auto-approved. The suspension mechanism is safe (CheckedContinuation);
    /// the approval UI is wired separately on AgentContext.
    let approvalRequired: (@Sendable (String) -> Bool)?

    /// Return false to suppress the final response — removes the placeholder and skips mesh reply.
    /// Evaluated against the final visible output text. nil means always send.
    let shouldSendResponse: (@Sendable (String) -> Bool)?
}
