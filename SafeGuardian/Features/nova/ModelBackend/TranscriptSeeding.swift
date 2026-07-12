//
// TranscriptSeeding.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import AgentInfra
import AnyLanguageModelKit

extension Transcript {
    /// Builds a session-seeding transcript from a system prompt and prior
    /// conversation turns, shared by every AnyLanguageModel-backed provider.
    static func seeded(systemPrompt: String, history: [ConversationTurn]) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: systemPrompt))], toolDefinitions: []))
        ]
        for turn in history {
            switch turn.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: turn.content))])))
            case .assistant:
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: turn.content))])))
            }
        }
        return Transcript(entries: entries)
    }

    /// Reconstructs conversation history from a live session's transcript — the
    /// inverse of `.seeded`. Tool call/output entries carry no ConversationTurn
    /// representation (the UI-level history never showed them either — see
    /// AgentConversationEngine.buildHistory, which only reads visible message
    /// text), so they're skipped rather than folded into surrounding turns.
    var conversationTurns: [ConversationTurn] {
        entries.compactMap { entry in
            switch entry {
            case .prompt(let prompt):
                return ConversationTurn(role: .user, content: Self.text(from: prompt.segments))
            case .response(let response):
                return ConversationTurn(role: .assistant, content: Self.text(from: response.segments))
            case .instructions, .toolCalls, .toolOutput:
                return nil
            }
        }
    }

    private static func text(from segments: [Transcript.Segment]) -> String {
        segments.compactMap { if case .text(let t) = $0 { return t.content }; return nil }.joined()
    }
}
