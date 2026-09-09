// ApprovalRequestMessage.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// A sentinel embedded as an ordinary SafeGuardianMessage's content, detected by
/// NovaBubble to render an approval card in place of plain text. The token is
/// the same opaque value AgentContextProxy.requestApproval(for:) generates —
/// there is exactly one identifier for a pending decision end to end, from the
/// tool-call continuation through to the message that represents it in chat.
nonisolated enum ApprovalRequestMessage {
    private static let prefix = "nova:approval:"

    static func content(for token: String) -> String {
        "\(prefix)\(token)"
    }

    static func token(in content: String) -> String? {
        guard content.hasPrefix(prefix) else { return nil }
        return String(content.dropFirst(prefix.count))
    }
}
