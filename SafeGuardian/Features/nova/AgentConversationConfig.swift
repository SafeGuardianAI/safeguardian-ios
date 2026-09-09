import SafeGuardianMesh
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
    let systemPrompt: @Sendable @MainActor () -> String

    /// Called only when the active provider's modelCapabilities.supportsToolCalling == true.
    /// Receives the engine-created StatusCallback and the conversation's effective peerID —
    /// so each provider can wire them into AgentToolRegistry.build, and an approval card
    /// lands in the transcript the call actually came from rather than a fixed default
    /// thread. Approval policy is no longer threaded through here: it is declared per tool
    /// on AgentToolEntry.requiresConfirmation, at each tool's own definition site, so a new
    /// consequential tool can't be added without its author deciding whether it needs
    /// human approval before it executes.
    let toolRegistry: (@Sendable @MainActor (any AgentContext, StatusCallback, PeerID) -> AgentToolRegistry?)?

    /// Return false to suppress the final response — removes the placeholder and skips mesh reply.
    /// Evaluated against the final visible output text. nil means always send.
    let shouldSendResponse: (@Sendable (String) -> Bool)?
}
