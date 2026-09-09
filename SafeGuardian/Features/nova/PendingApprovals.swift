// PendingApprovals.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation
import Observation

/// Owns the decision state for tool-call approval requests, keyed by the same
/// opaque token AgentContextProxy.requestApproval(for:) generates. This is
/// state only — it does not append the approval-card message to a transcript
/// (ChatViewModel+Agents.swift does that, since it already has the full
/// AgentContext at the registration call site) and it does not decide which
/// tools reach this at all (AgentToolEntry.requiresConfirmation, declared per
/// tool at its own definition site, decides that). A card's live state — pending/approved/denied —
/// is read directly from `entries` by NovaBubble/ApprovalMessageView, so
/// resolving a decision here is sufficient to update the UI with no separate
/// message-content mutation needed.
@MainActor
@Observable
final class PendingApprovals {
    static let shared = PendingApprovals()

    enum State: Equatable {
        case pending, approved, denied
    }

    struct Entry: Equatable {
        let toolName: String
        /// Sorted-key JSON of the actual call arguments, shown verbatim in the approval
        /// card so the human approves this concrete call, not the tool category in the abstract.
        let argumentSummary: String
        /// Overrides the card's derived "Nova wants to <tool>" phrasing for requests that
        /// aren't Nova asking to run one of its own tools — e.g. a peer's agent asking this
        /// device for something, where the ask belongs to them, not to Nova.
        var promptTitle: String?
        var state: State
    }

    private(set) var entries: [String: Entry] = [:]
    private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]

    private init() {}

    func register(
        token: String, toolName: String, argumentSummary: String, promptTitle: String? = nil,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        entries[token] = Entry(toolName: toolName, argumentSummary: argumentSummary, promptTitle: promptTitle, state: .pending)
        continuations[token] = continuation
    }

    func entry(forToken token: String) -> Entry? {
        entries[token]
    }

    func resolve(_ token: String, approved: Bool) {
        guard var entry = entries[token] else { return }
        entry.state = approved ? .approved : .denied
        entries[token] = entry
        continuations.removeValue(forKey: token)?.resume(returning: approved)
    }
}
