import SafeGuardianMesh
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

    weak var transport: MultiTransportManager?
    private var lanGateway: LANGatewayTransport?
    private var cancellables = Set<AnyCancellable>()

    // Envelopes arriving from the LAN gateway have no mesh peer; they carry
    // this sentinel so downstream consumers can distinguish the source.
    static let gatewayPeerID = PeerID(str: "lan-gateway")

    // MARK: - Init

    init(transport: MultiTransportManager, triageProfile: TriageProfile = .tccc) {
        self.transport = transport
        self.triageEngine = SGTriageEngine(profile: triageProfile)
        wireEnvelopeHandler()
        reloadGatewayFromDefaults()
    }

    // MARK: - LAN Gateway

    // (Re)starts the UDP gateway link from persisted config. Called at init and
    // again whenever the operator changes the gateway host in settings.
    func reloadGatewayFromDefaults() {
        lanGateway?.stop()
        lanGateway = nil
        guard let config = LANGatewayTransport.Config.fromUserDefaults() else { return }
        let gateway = LANGatewayTransport(config: config)
        gateway.onEnvelopeReceived = { [weak self] envelope in
            self?.envelopeHandler.handle(envelope, from: Self.gatewayPeerID)
        }
        gateway.start()
        lanGateway = gateway
    }

    // Every outbound envelope fans out to the mesh and, when provisioned, to the
    // APEX UDP gateway so the ops store sees field state without a bridge hop.
    private func send(_ envelope: SGEnvelope) {
        transport?.sendSGEnvelope(envelope)
        lanGateway?.send(envelope)
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
        let envelope = entityManager.envelope(for: entity, tenantHash: TenantIdentity.tenantHash)
        send(envelope)
    }

    // MARK: - Agent State API

    func publishStateTick(_ tick: AgentStateTick) {
        guard let payload = encodeStateTick(tick) else { return }
        let envelope = SGEnvelope.build(
            priority: priority(for: tick),
            payloadType: .stateTick,
            payload: payload,
            tenantHash: TenantIdentity.tenantHash
        )
        send(envelope)
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

    // MARK: - Private

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
