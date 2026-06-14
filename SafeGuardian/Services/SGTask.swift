import Foundation

// SGTask represents a mission task issued from APEX to a Trek agent (or between agents).
// Status updates carry a monotonically incrementing version; stale updates are dropped.
struct SGTask {
    let id: String
    let assigneeId: String       // entity ID of the receiving agent
    let taskType: String         // "medevac" | "investigate" | "extract" | "salute" | ...
    let priority: MessagePriority
    let timestamp: Date
    let parameters: Data         // JSON-encoded task-specific parameters
    var statusVersion: Int = 0
    var status: SGTaskStatusValue = .pending
}

enum SGTaskStatusValue: String, Codable {
    case pending, executing, done, cancelled, failed
}

// Received by an agent via SGTaskManager.listenAsAgent when a task is assigned or cancelled.
struct SGAgentRequest {
    let task: SGTask
    let isCancel: Bool
}

// Wire payload for payloadType = .task
struct SGTaskPayload: Codable {
    let id: String
    let assigneeId: String
    let taskType: String
    let priority: UInt8
    let timestamp: TimeInterval
    let parameters: Data

    func toTask() -> SGTask? {
        guard let prio = MessagePriority(rawValue: priority) else { return nil }
        return SGTask(
            id: id,
            assigneeId: assigneeId,
            taskType: taskType,
            priority: prio,
            timestamp: Date(timeIntervalSince1970: timestamp),
            parameters: parameters
        )
    }
}

// Wire payload for payloadType = .taskStatus
struct SGTaskStatusPayload: Codable {
    let taskId: String
    let status: SGTaskStatusValue
    let version: Int
    let timestamp: TimeInterval
}
