// Agent.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import BitFoundation
import Foundation

/// A concrete AgentProcessor defined entirely by its AgentConversationConfig.
/// All behavior is provided by the AgentProcessor protocol extension.
/// New agents are static instances on this type — no new class required.
@MainActor
struct Agent: AgentProcessor {
    let conversationConfig: AgentConversationConfig
}

extension Agent {
    static let nova = Agent(conversationConfig: AgentConversationConfig(
        agentID: "nova",
        displayName: "Nova",
        peerID: PeerID(str: "nova-local"),
        triggerPrefix: "@nova",
        systemPrompt: {
            NovaConfig.buildSystemPrompt(
                personalization: NovaPersonalizationStore.shared.blurb.isEmpty
                    ? nil : NovaPersonalizationStore.shared.blurb
            )
        },
        toolRegistry: { context in
            AgentToolRegistry.standard(agentID: "nova", context: context)
        }
    ))
}
