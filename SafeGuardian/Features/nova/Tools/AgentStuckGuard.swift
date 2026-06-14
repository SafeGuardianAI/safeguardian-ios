// AgentStuckGuard.swift
// SafeGuardian
//
// Tracks consecutive failures per tool within a single inference session.
// When a tool fails FAILURE_THRESHOLD times in a row, nudge() returns a
// recovery hint appended to the next tool result so the model sees the
// failure context in its reasoning without a separate user-turn injection.

import Foundation

// MARK: - AgentStuckGuard

/// @unchecked Sendable: mutation occurs sequentially inside the dispatch closure
/// (MLXLMCommon dispatches tool calls one at a time), so no concurrent write risk.
final class AgentStuckGuard: @unchecked Sendable {
    private static let failureThreshold = 3

    private static let errorMarkers: [String] = [
        "\"error\":", "\"success\":false", "\"success\": false",
        "exit code:", "no such file", "command not found",
        "permission denied", "failed:", "unknown action",
    ]

    nonisolated(unsafe) private var consecutiveFailures: [String: Int] = [:]

    func record(_ name: String, result: String) {
        let lower = result.lowercased()
        let isError = Self.errorMarkers.contains { lower.contains($0) }
        consecutiveFailures[name] = isError ? (consecutiveFailures[name] ?? 0) + 1 : 0
    }

    /// Returns a nudge string to append to the tool result, or nil if the tool is healthy.
    func nudge(for name: String) -> String? {
        let count = consecutiveFailures[name] ?? 0
        guard count >= Self.failureThreshold else { return nil }
        return "[GUIDE: \"\(name)\" has failed \(count) times consecutively. Try a different approach or call task_complete if the task cannot proceed.]"
    }
}
