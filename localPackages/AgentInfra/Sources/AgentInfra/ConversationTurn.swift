// ConversationTurn.swift
// AgentInfra
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// A single completed turn in a conversation, provider-agnostic.
/// Assembled by the agent layer and consumed by each inference provider.
public struct ConversationTurn: Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}
