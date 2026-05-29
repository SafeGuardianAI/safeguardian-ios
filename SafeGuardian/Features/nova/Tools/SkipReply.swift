//
// SkipReply.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

extension AgentToolEntry {
    /// Signals that the agent has nothing useful to contribute to this mesh query.
    /// Calling this tool suppresses the outbound AGENT_REPLY and removes the
    /// placeholder message from the local Nova thread. For use by tool-capable
    /// models (3B+) that can reliably emit structured tool calls.
    static func skipReply() -> AgentToolEntry {
        make(
            name: "skip_reply",
            description: "Call this when you have nothing useful to contribute to the current mesh query. Suppresses the reply entirely — do not generate additional text after calling this.",
            parameters: []
        ) { _, _ in
            // The NovaAgent drain loop detects empty visible output on .complete
            // when replyTo is set and suppresses the reply accordingly.
            return #"{"skipped":true}"#
        }
    }
}
