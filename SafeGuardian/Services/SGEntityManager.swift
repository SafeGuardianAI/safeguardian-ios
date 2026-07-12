import SafeGuardianMesh
import BitFoundation
import Combine
import Foundation

// SGEntityManager maintains a live entity store keyed by entity ID.
// Incoming SGEnvelope entity payloads are decoded, merged by version
// (higher version wins), and published via entityPublisher.
//
// Wire-up: SGClient sets SGEnvelopeHandler.onEntity to call receive(_:from:).
final class SGEntityManager {

    private var store: [String: SGEntity] = [:]
    private let lock = NSLock()

    private let subject = CurrentValueSubject<[SGEntity], Never>([])
    var entityPublisher: AnyPublisher<[SGEntity], Never> { subject.eraseToAnyPublisher() }

    var allEntities: [SGEntity] { subject.value }

    func entity(id: String) -> SGEntity? {
        lock.lock()
        defer { lock.unlock() }
        return store[id]
    }

    func receive(_ payload: Data, from peerID: PeerID) {
        guard let decoded = try? JSONDecoder().decode(SGEntityPayload.self, from: payload),
              let entity = decoded.toEntity() else { return }
        lock.lock()
        if let existing = store[entity.id], existing.version >= entity.version {
            lock.unlock()
            return  // stale update
        }
        store[entity.id] = entity
        let snapshot = Array(store.values)
        lock.unlock()
        subject.send(snapshot)
    }

    func removeEntity(id: String) {
        lock.lock()
        store.removeValue(forKey: id)
        let snapshot = Array(store.values)
        lock.unlock()
        subject.send(snapshot)
    }

    // Build and return a publish-ready SGEnvelope for a given entity.
    func envelope(for entity: SGEntity, tenantHash: Data = SGEnvelope.defaultTenantHash) -> SGEnvelope {
        let payload = SGEntityPayload(
            id: entity.id,
            entityType: entity.entityType,
            priority: entity.priority.rawValue,
            timestamp: entity.timestamp.timeIntervalSince1970,
            sourceId: entity.sourceId,
            version: entity.version,
            fields: [:]
        )
        let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
        return SGEnvelope.build(
            priority: entity.priority,
            payloadType: .entity,
            payload: payloadData,
            tenantHash: tenantHash
        )
    }
}
