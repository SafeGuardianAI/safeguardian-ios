import BitFoundation
import Combine
import CoreBluetooth
import Foundation

// Transport conformance backed by the Reticulum mesh protocol.
// Owns a ReticulumIdentity (stable Reticulum address derived from Ed25519 keys)
// and a ReticulumBLEInterface (CoreBluetooth adapter speaking the RNode UART service).
// Inbound ANNOUNCE packets register peers; inbound DATA packets decode as LXMF messages
// and are delivered to the SafeGuardianDelegate, making this transport a drop-in
// replacement for BLEService at the ChatViewModel injection point.
final class ReticulumTransport: @unchecked Sendable {
    private static let sgEnvelopeTitle = "sg-envelope"

    // MARK: - Transport State

    weak var delegate: SafeGuardianDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?
    var localAgentIDs: [String] = []

    let identity: ReticulumIdentity

    let bleInterface: ReticulumBLEInterface
    let toolRouter: LXMFToolRouter

    private let noiseService: NoiseEncryptionService

    private var connectedPeers: [PeerID: (ReticulumAnnounce, CBPeripheral)] = [:]
    private var peerNicknames: [PeerID: String] = [:]

    private let peerSubject = CurrentValueSubject<[TransportPeerSnapshot], Never>([])
    private var announceTimer: Timer?
    private var _myNickname: String

    // MARK: - Init

    init(identity: ReticulumIdentity, keychain: KeychainManagerProtocol) {
        self.identity  = identity
        self.noiseService = NoiseEncryptionService(keychain: keychain)
        self._myNickname = UserDefaults.standard.string(forKey: "bitchat.nickname") ?? "anon"

        self.bleInterface = ReticulumBLEInterface()
        self.toolRouter = LXMFToolRouter(identity: identity)
        wireBLECallbacks()
        MeshAgentRegistry.shared.toolRouter = toolRouter
        MeshAgentRegistry.shared.localDestinationHash = identity.destinationHash.hexEncodedString()
    }

    // MARK: - BLE Callbacks

    private func wireBLECallbacks() {
        bleInterface.onPacket = { [weak self] data, peripheral in
            self?.handleInboundPacket(data, from: peripheral)
        }
        bleInterface.onPeerConnected = { [weak self] peerID, _ in
            self?.delegate?.didConnectToPeer(peerID)
        }
        bleInterface.onPeerDisconnected = { [weak self] peerID in
            self?.connectedPeers.removeValue(forKey: peerID)
            self?.peerNicknames.removeValue(forKey: peerID)
            self?.delegate?.didDisconnectFromPeer(peerID)
            self?.emitPeerSnapshots()
            MeshAgentRegistry.shared.remove(peerID: peerID)
        }
        toolRouter.sendDirected = { [weak self] destHash, lxmfPayload in
            guard let self else { return }
            let peerID = PeerID(hexData: destHash)
            if let (_, peripheral) = connectedPeers[peerID] {
                let packet = ReticulumDataPacket.directed(to: destHash, payload: lxmfPayload)
                bleInterface.send(packet.encode(), to: peripheral)
            } else {
                let packet = ReticulumDataPacket.broadcast(payload: lxmfPayload, identity: identity)
                bleInterface.broadcast(packet.encode())
            }
        }
    }

    // MARK: - Packet Handling

    private func handleInboundPacket(_ data: Data, from peripheral: CBPeripheral) {
        guard let packet = ReticulumDataPacket.decode(data) else { return }
        switch packet.header.packetType {
        case .announce:
            guard let announce = ReticulumAnnounce.decode(packet.payload) else { return }
            let peerID = PeerID(hexData: announce.destinationHash)
            connectedPeers[peerID] = (announce, peripheral)
            if !announce.appData.isEmpty,
               let agentPeer = ReticulumAgentPeer.decode(
                   peerID: peerID, destinationHash: announce.destinationHash, appData: announce.appData) {
                MeshAgentRegistry.shared.register(agentPeer)
            }
            emitPeerSnapshots()
            delegate?.didConnectToPeer(peerID)
        case .data:
            guard let lxmf = LXMFMessage.decode(packet.payload) else { return }
            let senderID = PeerID(hexData: lxmf.source)
            let titleStr = String(data: lxmf.title, encoding: .utf8) ?? ""
            if titleStr.hasPrefix("tool_response:") {
                toolRouter.handleResponse(title: titleStr, content: lxmf.content)
                return
            }
            if lxmf.title == Data(Self.sgEnvelopeTitle.utf8),
               let envelope = SGEnvelope.decode(lxmf.content) {
                delegate?.didReceiveSGEnvelope(envelope, from: senderID)
                return
            }
            let nickname = peerNicknames[senderID] ?? senderID.id.prefix(8).description
            let isPrivate = lxmf.destination != Data(repeating: 0, count: 16)
            let content = String(data: lxmf.content, encoding: .utf8) ?? ""
            let ts = Date(timeIntervalSince1970: Double(lxmf.timestamp) / 1000.0)
            if isPrivate {
                delegate?.didReceiveNoisePayload(
                    from: senderID, type: .privateMessage,
                    payload: lxmf.content, timestamp: ts
                )
            } else {
                delegate?.didReceivePublicMessage(
                    from: senderID, nickname: nickname,
                    content: content, timestamp: ts, messageID: nil
                )
            }
        default:
            break
        }
    }

    private func emitPeerSnapshots() {
        let snapshots: [TransportPeerSnapshot] = connectedPeers.map { (peerID, pair) in
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: peerNicknames[peerID] ?? peerID.id.prefix(8).description,
                isConnected: true,
                noisePublicKey: Data(pair.0.signingPublicKey),
                lastSeen: Date(),
                linkType: .reticulum,
                estimatedBandwidthBps: 2_000  // LoRa SF7 practical throughput
            )
        }
        peerSubject.send(snapshots)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.peerEventsDelegate?.didUpdatePeerSnapshots(snapshots)
        }
    }
}

// MARK: - Transport Conformance

extension ReticulumTransport: Transport {

    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        peerSubject.eraseToAnyPublisher()
    }

    func currentPeerSnapshots() -> [TransportPeerSnapshot] {
        peerSubject.value
    }

    var myPeerID: PeerID { identity.peerID }

    var myNickname: String { _myNickname }

    func setNickname(_ nickname: String) {
        _myNickname = nickname
        UserDefaults.standard.set(nickname, forKey: "bitchat.nickname")
    }

    func startServices() {
        bleInterface.start()
        announceTimer = Timer.scheduledTimer(
            withTimeInterval: ReticulumConfig.reticulumAnnounceInterval,
            repeats: true
        ) { [weak self] _ in self?.broadcastAnnounce() }
        announceTimer?.fire()
    }

    func stopServices() {
        announceTimer?.invalidate()
        announceTimer = nil
        bleInterface.stop()
    }

    func emergencyDisconnectAll() {
        stopServices()
        connectedPeers.removeAll()
        peerNicknames.removeAll()
        peerSubject.send([])
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool {
        connectedPeers[peerID] != nil
    }

    func isPeerReachable(_ peerID: PeerID) -> Bool { isPeerConnected(peerID) }

    func peerNickname(peerID: PeerID) -> String? { peerNicknames[peerID] }

    func getPeerNicknames() -> [PeerID: String] { peerNicknames }

    func sendMessage(_ content: String, mentions: [String]) {
        guard let lxmf = try? LXMFMessage.build(
            from: identity,
            to: Data(repeating: 0, count: 16),
            content: content
        ) else { return }
        let packet = ReticulumDataPacket.broadcast(payload: lxmf.encode(), identity: identity)
        bleInterface.broadcast(packet.encode())
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID,
                            recipientNickname: String, messageID: String) {
        guard let (announce, peripheral) = connectedPeers[peerID],
              let lxmf = try? LXMFMessage.build(
                from: identity,
                to: announce.destinationHash,
                content: content
              ) else { return }
        let packet = ReticulumDataPacket.directed(
            to: announce.destinationHash,
            payload: lxmf.encode()
        )
        bleInterface.send(packet.encode(), to: peripheral)
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {}

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}

    func sendBroadcastAnnounce() { broadcastAnnounce() }

    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {}

    func sendSGEnvelope(_ envelope: SGEnvelope) {
        guard let lxmf = try? LXMFMessage.build(
            from: identity,
            to: Data(repeating: 0, count: 16),
            content: envelope.encode(),
            title: Self.sgEnvelopeTitle
        ) else { return }
        let packet = ReticulumDataPacket.broadcast(payload: lxmf.encode(), identity: identity)
        bleInterface.broadcast(packet.encode())
    }

    func triggerHandshake(with peerID: PeerID) {}

    func getFingerprint(for peerID: PeerID) -> String? { nil }

    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }

    func getNoiseService() -> NoiseEncryptionService { noiseService }

    // MARK: - Private helpers

    private func broadcastAnnounce() {
        // Emit structured JSON so peer agents can discover this node via the
        // FieldMesh announce protocol. caps is empty until agent-callable tools are added.
        let appDataObj: [String: Any] = ["type": "nova", "caps": [String]()]
        guard let appDataJSON = try? JSONSerialization.data(withJSONObject: appDataObj, options: .sortedKeys),
              let signed = try? ReticulumAnnounce.build(identity: identity, appData: appDataJSON) else { return }
        let header = ReticulumPacketHeader(
            ifac: false, headerType: 0, contextFlags: 0,
            propagation: .broadcast, destinationType: .single,
            packetType: .announce, hops: 0
        )
        let packet = ReticulumDataPacket(
            header: header,
            destinationHash: identity.destinationHash,
            context: 0,
            payload: signed.encode()
        )
        bleInterface.broadcast(packet.encode())
    }
}
