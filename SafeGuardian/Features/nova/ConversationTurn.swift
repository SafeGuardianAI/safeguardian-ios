// ConversationTurn.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// A single completed turn in a conversation, provider-agnostic.
/// Assembled by the agent layer and consumed by each inference provider.
struct ConversationTurn: Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }
    let role: Role
    let content: String
}
