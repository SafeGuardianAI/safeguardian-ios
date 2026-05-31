// AgentThreadStore.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import BitFoundation
import Foundation

/// Manages named conversation threads per agent. Each thread is a distinct key
/// in privateChats so messages from different conversations never intermingle.
/// The "local" thread ID maps to the original "nova-local" PeerID so existing
/// conversations survive the upgrade without migration.
@Observable @MainActor
final class AgentThreadStore {
    static let shared = AgentThreadStore()
    static let defaultThreadID = "local"

    struct Thread: Codable, Identifiable {
        let id: String
        let agentID: String
        let createdAt: Date
        var title: String

        var peerID: PeerID { PeerID(str: "\(agentID)-\(id)") }
    }

    private(set) var threadsByAgent: [String: [Thread]] = [:]
    private(set) var activeIDByAgent: [String: String] = [:]

    private static let storageKey = "agentThreadStore.v1"

    private init() {
        load()
        ensureDefaultThread(for: "nova")
    }

    // MARK: - Queries

    func threads(for agentID: String) -> [Thread] {
        threadsByAgent[agentID] ?? []
    }

    func activeThread(for agentID: String) -> Thread? {
        let id = activeIDByAgent[agentID] ?? Self.defaultThreadID
        return threadsByAgent[agentID]?.first { $0.id == id }
    }

    func activePeerID(for agentID: String) -> PeerID {
        activeThread(for: agentID)?.peerID ?? PeerID(str: "\(agentID)-\(Self.defaultThreadID)")
    }

    /// Returns the agentID that owns this peerID, or nil if it is not a thread peerID.
    func agentID(for peerID: PeerID) -> String? {
        for (aid, list) in threadsByAgent {
            if list.contains(where: { $0.peerID == peerID }) { return aid }
        }
        return nil
    }

    func isThreadPeerID(_ peerID: PeerID) -> Bool {
        agentID(for: peerID) != nil
    }

    func thread(for peerID: PeerID) -> Thread? {
        for list in threadsByAgent.values {
            if let t = list.first(where: { $0.peerID == peerID }) { return t }
        }
        return nil
    }

    // MARK: - Mutations

    @discardableResult
    func newThread(for agentID: String) -> Thread {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased())
        let t = Thread(id: id, agentID: agentID, createdAt: Date(), title: "New conversation")
        threadsByAgent[agentID, default: []].insert(t, at: 0)
        activeIDByAgent[agentID] = id
        save()
        return t
    }

    func switchToThread(_ id: String, agentID: String) {
        guard threadsByAgent[agentID]?.contains(where: { $0.id == id }) == true else { return }
        activeIDByAgent[agentID] = id
        save()
    }

    func updateTitle(_ title: String, threadID: String, agentID: String) {
        guard let idx = threadsByAgent[agentID]?.firstIndex(where: { $0.id == threadID }) else { return }
        let capped = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        guard !capped.isEmpty else { return }
        threadsByAgent[agentID]![idx].title = capped
        save()
    }

    func deleteThread(_ id: String, agentID: String) {
        guard let list = threadsByAgent[agentID], list.count > 1 else { return }
        threadsByAgent[agentID]!.removeAll { $0.id == id }
        if activeIDByAgent[agentID] == id {
            activeIDByAgent[agentID] = threadsByAgent[agentID]?.first?.id ?? Self.defaultThreadID
        }
        save()
    }

    // MARK: - Persistence

    private func ensureDefaultThread(for agentID: String) {
        if threadsByAgent[agentID] == nil || threadsByAgent[agentID]!.isEmpty {
            let t = Thread(id: Self.defaultThreadID, agentID: agentID,
                           createdAt: .distantPast, title: agentID.capitalized)
            threadsByAgent[agentID] = [t]
            activeIDByAgent[agentID] = Self.defaultThreadID
            save()
        }
        if activeIDByAgent[agentID] == nil {
            activeIDByAgent[agentID] = threadsByAgent[agentID]?.first?.id
            save()
        }
    }

    private struct Payload: Codable {
        let threads: [String: [Thread]]
        let activeIDs: [String: String]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(
            Payload(threads: threadsByAgent, activeIDs: activeIDByAgent)
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        threadsByAgent = payload.threads
        activeIDByAgent = payload.activeIDs
    }
}
