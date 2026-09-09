// AgentAccountability.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import BitFoundation
import Foundation

/// The one on-disk accountability trail for consequential Nova executions —
/// both locally-issued model tool calls (AgentTool.swift) and inbound mesh
/// tool calls (wired onto MeshAgentRegistry.shared.toolRouter in
/// ChatViewModel). Not gated `#if DEBUG`: this is an audit log, not a
/// fine-tuning artifact, so it runs in Release the same as Debug — see
/// ConversationLogger for the actually-debug-only training-data logger this
/// is not a replacement for.
enum AgentAccountability {
    static let log: AccountabilityLog? = {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("chat.safeguardian", isDirectory: true)
        return try? AccountabilityLog(directory: dir)
    }()
}
