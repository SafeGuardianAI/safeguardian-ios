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

    // MARK: - Transport State

    weak var delegate: SafeGuardianDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?
    var localAgentIDs: [String] = []

    let identity: ReticulumIdentity

    #if os(iOS)
    let bleInterface: ReticulumBLEInterface
    #endif

    private let noiseService: NoiseEncryptionService

    // peer hash (hex) → (announce, CBPeripheral)
    #if os(iOS)
    private var connectedPeers: [PeerID: (ReticulumAnnounce, CBPeripheral)] = [:]
    #endif
    private var peerNicknames: [PeerID: String] = [:]

    private let peerSubject = CurrentValueSubject<[TransportPeerSnapshot], Never>([])
    private var announceTimer: Timer?
    private var _myNickname: String

    // MARK: - Init

    init(identity: ReticulumIdentity, keychain: KeychainManagerProtocol) {
        self.identity  = identity
        self.noiseService = NoiseEncryptionService(keychain: keychain)
        self._myNickname = UserDefaults.standard.string(forKey: "bitchat.nickname") ?? "anon"

        #if os(iOS)
        self.bleInterface = ReticulumBLEInterface()
        #endif

        #if os(iOS)
        wireBLECallbacks()
        #endif
    }

    // MARK: - BLE Callbacks

    #if os(iOS)
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
        }
    }
    #endif

    // MARK: - Packet Handling

    #if os(iOS)
    private func handleInboundPacket(_ data: Data, from peripheral: CBPeripheral) {
        guard let packet = ReticulumDataPacket.decode(data) else { return }
        switch packet.header.packetType {
        case .announce:
            guard let announce = ReticulumAnnounce.decode(packet.payload) else { return }
            let peerID = PeerID(hexData: announce.destinationHash)
            connectedPeers[peerID] = (announce, peripheral)
            emitPeerSnapshots()
            delegate?.didConnectToPeer(peerID)
        case .data:
            guard let lxmf = LXMFMessage.decode(packet.payload) else { return }
            let senderID = PeerID(hexData: lxmf.source)
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
                lastSeen: Date()
            )
        }
        peerSubject.send(snapshots)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.peerEventsDelegate?.didUpdatePeerSnapshots(snapshots)
        }
    }
    #endif
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
        #if os(iOS)
        bleInterface.start()
        #endif
        announceTimer = Timer.scheduledTimer(
            withTimeInterval: ReticulumConfig.reticulumAnnounceInterval,
            repeats: true
        ) { [weak self] _ in self?.broadcastAnnounce() }
        announceTimer?.fire()
    }

    func stopServices() {
        announceTimer?.invalidate()
        announceTimer = nil
        #if os(iOS)
        bleInterface.stop()
        #endif
    }

    func emergencyDisconnectAll() {
        stopServices()
        #if os(iOS)
        connectedPeers.removeAll()
        #endif
        peerNicknames.removeAll()
        peerSubject.send([])
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool {
        #if os(iOS)
        return connectedPeers[peerID] != nil
        #else
        return false
        #endif
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
        #if os(iOS)
        bleInterface.broadcast(packet.encode())
        #endif
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID,
                            recipientNickname: String, messageID: String) {
        #if os(iOS)
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
        #endif
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {}

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}

    func sendBroadcastAnnounce() { broadcastAnnounce() }

    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {}

    func triggerHandshake(with peerID: PeerID) {}

    func getFingerprint(for peerID: PeerID) -> String? { nil }

    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }

    func getNoiseService() -> NoiseEncryptionService { noiseService }

    // MARK: - Private helpers

    private func broadcastAnnounce() {
        guard let nickData = _myNickname.data(using: .utf8) else { return }
        // Embed nickname as appData by rebuilding with appData set.
        // ReticulumAnnounce is a value type; rebuild with appData.
        guard let signed = try? ReticulumAnnounce.build(identity: identity, appData: nickData) else { return }
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
        #if os(iOS)
        bleInterface.broadcast(packet.encode())
        #endif
    }
}
