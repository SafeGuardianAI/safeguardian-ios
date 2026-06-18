import AgentInfra
import BitFoundation
import Combine
import Foundation

// SGClient is the top-level SafeGuardian SDK facade. It owns the entity and task
// managers, the triage engine, and the envelope handler, and wires them to a
// MultiTransportManager. Callers interact with SGClient rather than directly with
// the transport or envelope layers.
//
// Instantiate once at app launch after the MultiTransportManager is created:
//
//   let sgClient = SGClient(transport: multiTransportManager)
//   multiTransportManager.sgEnvelopeHandler = sgClient.envelopeHandler
//
// The sgEnvelopeHandler assignment is not done inside SGClient.init because
// MultiTransportManager may be set up before the view hierarchy is ready.
final class SGClient {

    // MARK: - Subsystems

    let entityManager = SGEntityManager()
    let triageEngine: SGTriageEngine
    let envelopeHandler = SGEnvelopeHandler()

    private weak var transport: MultiTransportManager?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(transport: MultiTransportManager, triageProfile: TriageProfile = .tccc) {
        self.transport = transport
        self.triageEngine = SGTriageEngine(profile: triageProfile)
        wireEnvelopeHandler()
    }

    private func wireEnvelopeHandler() {
        envelopeHandler.onEntity = { [weak self] payload, peerID in
            self?.entityManager.receive(payload, from: peerID)
        }
        envelopeHandler.onTriage = { [weak self] payload, peerID in
            self?.entityManager.receive(payload, from: peerID)
        }
        envelopeHandler.onAgentMsg = { payload, _ in
            _ = payload  // agent-to-agent messages handled by AgentConversationEngine
        }
    }

    // MARK: - Entity API

    var entityPublisher: AnyPublisher<[SGEntity], Never> {
        entityManager.entityPublisher
    }

    func publishEntity(_ entity: SGEntity) {
        guard let sourceId = sourceIdData() else { return }
        let envelope = entityManager.envelope(for: entity, sourceId: sourceId)
        transport?.sendSGEnvelope(envelope)
    }

    // MARK: - Agent State API

    func publishStateTick(_ tick: AgentStateTick) {
        guard let sourceId = sourceIdData(),
              let payload = encodeStateTick(tick) else { return }
        let envelope = SGEnvelope.build(
            priority: priority(for: tick),
            payloadType: .stateTick,
            sourceId: sourceId,
            payload: payload
        )
        transport?.sendSGEnvelope(envelope)
    }

    // MARK: - Triage API

    func classifyTriage(_ label: String) -> MessagePriority {
        triageEngine.classify(label)
    }

    func classifyDeclaration(_ declaration: String) -> MessagePriority {
        triageEngine.classifyDeclaration(declaration)
    }

    func setTriageProfile(_ profile: TriageProfile) {
        triageEngine.setProfile(profile)
    }

    // MARK: - Transport introspection

    func availableTransportLinks() -> [SGTransportLink] {
        guard let transport else { return [] }
        return transport.currentPeerSnapshots()
            .reduce(into: [LinkType: SGTransportLink]()) { acc, snap in
                if acc[snap.linkType] == nil {
                    acc[snap.linkType] = SGTransportLink(
                        linkType: snap.linkType,
                        estimatedBandwidthBps: snap.estimatedBandwidthBps,
                        peerCount: 1
                    )
                } else {
                    acc[snap.linkType]?.peerCount += 1
                }
            }
            .values
            .sorted { $0.estimatedBandwidthBps > $1.estimatedBandwidthBps }
    }

    // MARK: - Private

    private func sourceIdData() -> Data? {
        guard let transport else { return nil }
        let hex = transport.myPeerID.id
        var data = Data(capacity: 8)
        var idx = hex.startIndex
        for _ in 0..<8 {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            let byte = UInt8(hex[idx..<next], radix: 16) ?? 0
            data.append(byte)
            idx = next
            if idx >= hex.endIndex { break }
        }
        return data.count == 8 ? data : Data(repeating: 0, count: 8)
    }

    private func encodeStateTick(_ tick: AgentStateTick) -> Data? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try? encoder.encode(tick)
    }

    private func priority(for tick: AgentStateTick) -> MessagePriority {
        switch tick.medicalStatus {
        case .critical: return .immediate
        case .serious: return .delayed
        case .minor: return .minimal
        case .uninjured, .unknown: return .routine
        }
    }
}

// MARK: - SGTransportLink

struct SGTransportLink {
    let linkType: LinkType
    let estimatedBandwidthBps: Int
    var peerCount: Int
}
