// ContextCompressor.swift
// AgentInfra
//
// Reduces history size before it is assembled into a prompt. Two strategies:
//
//  microcompact  — replaces old assistant turn bodies with "[cleared]",
//                  preserving role structure for models that need it.
//  compress      — truncates long bodies in old turns beyond keepRecent.
//  compressAsync — macOS 26+: uses LanguageModelSession to summarize old
//                  turns into one paragraph instead of truncating them.
//
// estimateTokens applies a UTF-8 byte count / 4 heuristic. Foundation Models
// does not expose a public token counting API; the estimate underestimates by
// at most ~15% for English, which is acceptable as a compact trigger.

import Foundation
#if os(macOS)
import FoundationModels
#endif

// MARK: - Public surface

public enum ContextCompressor {

    /// Conservative token estimate: UTF-8 byte count / 4.
    /// Safe to call from any isolation context; no async required.
    public static func estimateTokens(in turns: [ConversationTurn]) -> Int {
        turns.reduce(0) { $0 + $1.content.utf8.count / 4 }
    }

    /// Returns true when the estimated token count meets or exceeds the threshold.
    public static func shouldCompact(_ turns: [ConversationTurn], threshold: Int) -> Bool {
        estimateTokens(in: turns) >= threshold
    }

    /// Replaces old assistant turn bodies with "[cleared]", keeping the last
    /// `keepRecent` turns intact. Preserves user turns so the model retains
    /// conversational context.
    public static func microcompact(_ turns: [ConversationTurn], keepRecent: Int = 4) -> [ConversationTurn] {
        guard turns.count > keepRecent else { return turns }
        let cutoff = turns.count - keepRecent
        return turns.enumerated().map { i, turn in
            guard i < cutoff, turn.role == .assistant else { return turn }
            return ConversationTurn(role: turn.role, content: "[cleared]")
        }
    }

    /// Truncates long bodies in old turns to `maxBodyLength` characters,
    /// keeping the tail (most recent content) of each affected turn.
    public static func compress(
        _ turns: [ConversationTurn],
        keepRecent: Int = 4,
        maxBodyLength: Int = 400
    ) -> [ConversationTurn] {
        guard turns.count > keepRecent else { return turns }
        let cutoff = turns.count - keepRecent
        return turns.enumerated().map { i, turn in
            guard i < cutoff, turn.content.count > maxBodyLength else { return turn }
            return ConversationTurn(role: turn.role, content: String(turn.content.suffix(maxBodyLength)))
        }
    }

    /// Apply both microcompact then compress when shouldCompact is true.
    /// The combined pass is the recommended call site in the engine.
    public static func compactIfNeeded(
        _ turns: [ConversationTurn],
        threshold: Int,
        keepRecent: Int = 4
    ) -> [ConversationTurn] {
        guard shouldCompact(turns, threshold: threshold) else { return turns }
        return compress(microcompact(turns, keepRecent: keepRecent), keepRecent: keepRecent)
    }

#if os(macOS)
    /// macOS 26+: Summarizes old turns via LanguageModelSession rather than
    /// truncating them. Falls back to compactIfNeeded when Foundation Models is
    /// unavailable or when summarization times out (2-second hard cap).
    ///
    /// Condensing preserves semantic content that truncation discards — useful
    /// for long-running agent sessions where early context informs later decisions.
    @available(macOS 26, *)
    public static func compressAsync(
        _ turns: [ConversationTurn],
        threshold: Int,
        keepRecent: Int = 4
    ) async -> [ConversationTurn] {
        guard shouldCompact(turns, threshold: threshold) else { return turns }
        guard case .available = SystemLanguageModel.default.availability else {
            return compactIfNeeded(turns, threshold: threshold, keepRecent: keepRecent)
        }
        let cutoff = turns.count - keepRecent
        guard cutoff > 0 else { return turns }
        let old = turns.prefix(cutoff)
        let recent = Array(turns.suffix(keepRecent))
        let transcript = old.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
        do {
            let session = LanguageModelSession(
                instructions: "Summarize the conversation into one concise paragraph. Return only the summary."
            )
            let summary = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await session.respond(to: transcript).content }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw CancellationError()
                }
                guard let result = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return result
            }
            let contextTurn = ConversationTurn(role: .user, content: "[Prior context: \(summary)]")
            return [contextTurn] + recent
        } catch {
            return compactIfNeeded(turns, threshold: threshold, keepRecent: keepRecent)
        }
    }
#endif
}
