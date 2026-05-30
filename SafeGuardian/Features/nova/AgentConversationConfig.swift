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
    /// Return nil to disable tools for this agent regardless of provider capability.
    let toolRegistry: (@MainActor (any AgentContext) -> AgentToolRegistry?)?
}
