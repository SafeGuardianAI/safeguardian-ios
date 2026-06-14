import BitFoundation
import Combine
import Foundation

// SGTaskManager maintains the task store and routes agent-request events.
// It handles two SGEnvelope payload types: .task (new task assignment) and
// .taskStatus (status update with monotonic version counter).
//
// The listenAsAgent stream fires for any task whose assigneeId matches the
// given entity ID, consistent with the Lattice listen_as_agent pattern.
final class SGTaskManager {

    private var tasks: [String: SGTask] = [:]
    private let lock = NSLock()

    // Emits SGAgentRequest whenever a task is assigned or cancelled.
    private let requestSubject = PassthroughSubject<SGAgentRequest, Never>()
    var agentRequestPublisher: AnyPublisher<SGAgentRequest, Never> {
        requestSubject.eraseToAnyPublisher()
    }

    private let taskSubject = CurrentValueSubject<[SGTask], Never>([])
    var taskPublisher: AnyPublisher<[SGTask], Never> { taskSubject.eraseToAnyPublisher() }

    var allTasks: [SGTask] { taskSubject.value }

    // MARK: - Receive from mesh

    func receiveTask(_ payload: Data, from peerID: PeerID) {
        guard let decoded = try? JSONDecoder().decode(SGTaskPayload.self, from: payload),
              var task = decoded.toTask() else { return }
        lock.lock()
        task.statusVersion = 0
        tasks[task.id] = task
        let snapshot = Array(tasks.values)
        lock.unlock()
        taskSubject.send(snapshot)
        requestSubject.send(SGAgentRequest(task: task, isCancel: false))
    }

    func receiveStatus(_ payload: Data, from peerID: PeerID) {
        guard let decoded = try? JSONDecoder().decode(SGTaskStatusPayload.self, from: payload) else { return }
        lock.lock()
        guard var task = tasks[decoded.taskId], decoded.version > task.statusVersion else {
            lock.unlock()
            return  // stale update
        }
        task.status = decoded.status
        task.statusVersion = decoded.version
        tasks[decoded.taskId] = task
        let snapshot = Array(tasks.values)
        lock.unlock()
        taskSubject.send(snapshot)
        if decoded.status == .cancelled {
            requestSubject.send(SGAgentRequest(task: task, isCancel: true))
        }
    }

    // MARK: - Send helpers

    func statusEnvelope(taskId: String, status: SGTaskStatusValue,
                        version: Int, sourceId: Data) -> SGEnvelope? {
        let payload = SGTaskStatusPayload(
            taskId: taskId,
            status: status,
            version: version,
            timestamp: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return SGEnvelope.build(
            priority: .routine,
            payloadType: .taskStatus,
            sourceId: sourceId,
            payload: data
        )
    }

    func taskEnvelope(for task: SGTask, sourceId: Data) -> SGEnvelope? {
        let payload = SGTaskPayload(
            id: task.id,
            assigneeId: task.assigneeId,
            taskType: task.taskType,
            priority: task.priority.rawValue,
            timestamp: task.timestamp.timeIntervalSince1970,
            parameters: task.parameters
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return SGEnvelope.build(
            priority: task.priority,
            payloadType: .task,
            sourceId: sourceId,
            payload: data
        )
    }
}
