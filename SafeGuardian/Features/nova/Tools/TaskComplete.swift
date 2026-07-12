import SafeGuardianMesh
// TaskComplete.swift
// SafeGuardian
//
// AgentTaskRecord stores the summary set by a task_complete tool call so that
// AgentConversationEngine can use it at .complete time instead of whatever
// text the model chose to echo back. The record is per-inference-call — created
// in AgentToolRegistry.build and carried alongside the registry.

import Foundation
import AgentInfra

// MARK: - AgentTaskRecord

/// Shared mutable state for a single inference call, captured by the dispatch
/// closure and read by AgentConversationEngine at stream completion.
/// @unchecked Sendable: mutation always precedes the MainActor read at .complete.
final class AgentTaskRecord: @unchecked Sendable {
    nonisolated(unsafe) private(set) var taskCompleteSummary: String? = nil

    func record(summary: String) {
        taskCompleteSummary = summary
    }
}

// MARK: - Tool entry

extension AgentToolEntry {
    static func taskComplete(record: AgentTaskRecord) -> AgentToolEntry {
        make(
            name: "task_complete",
            description: "Signal that you have finished this task. Call this when you have completed all required actions. Include a concise summary of what was accomplished.",
            parameters: [
                .required("summary", type: .string, description: "Concise summary of what was accomplished.")
            ]
        ) { args, _ in
            let summary: String
            if case .string(let s) = args["summary"] { summary = s } else { summary = "Task complete." }
            record.record(summary: summary)
            return #"{"status":"complete"}"#
        }
    }
}
