import BitFoundation
import Combine
import CoreBluetooth
import Foundation

// MultiTransportManager presents a single Transport to the app while multiplexing
// across BLEService, ReticulumTransport, and any future transports added to the array.
//
// Inbound: each child transport's delegate is set to this manager. Arriving events
// pass through a shared MessageDeduplicator before being forwarded to the app-level
// SafeGuardianDelegate, so the same message arriving via BLE and Reticulum is
// delivered exactly once.
//
// Outbound: broadcast messages go to the primary (BLEService). Directed messages
// route to whichever transport has the destination peer connected. SGEnvelopes
// fan out across links when priority or payload type requires resilient routing.
//
// Peer snapshots are merged across all transports, deduplicating by peerID with
// the most-recently-seen snapshot winning when a peer is visible on multiple links.
final class MultiTransportManager: @unchecked Sendable {

    // MARK: - Transport protocol state

    weak var delegate: SafeGuardianDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    // Set at app launch to receive decoded SGEnvelope packets.
    var sgEnvelopeHandler: SGEnvelopeHandler?

    // Optional LAN gateway for command-post WiFi scenarios.
    // Set after init; starts automatically when assigned.
    var lanGateway: LANGatewayTransport? {
        didSet {
            lanGateway?.onEnvelopeReceived = { [weak self] envelope in
                self?.handleLANEnvelope(envelope)
            }
            lanGateway?.start()
        }
    }
    var localAgentIDs: [String] = [] {
        didSet { transports.forEach { $0.localAgentIDs = localAgentIDs } }
    }

    // MARK: - Internal state

    private let transports: [any Transport]
    private var primary: any Transport { transports[0] }

    private let deduplicator = MessageDeduplicator()
    private let lock = NSLock()
    private var peerSnapshotsByID: [PeerID: TransportPeerSnapshot] = [:]
    private let peerSubject = CurrentValueSubject<[TransportPeerSnapshot], Never>([])
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(transports: [any Transport]) {
        precondition(!transports.isEmpty, "MultiTransportManager requires at least one transport")
        self.transports = transports
        for t in transports {
            t.delegate = self
            t.peerEventsDelegate = self
        }
        for t in transports {
            t.peerSnapshotPublisher
                .sink { [weak self] snapshots in self?.mergePeerSnapshots(snapshots) }
                .store(in: &cancellables)
        }
    }

    // MARK: - Peer snapshot merging

    private func mergePeerSnapshots(_ snapshots: [TransportPeerSnapshot]) {
        lock.lock()
        for snapshot in snapshots {
            if let existing = peerSnapshotsByID[snapshot.peerID] {
                if snapshot.lastSeen >= existing.lastSeen {
                    peerSnapshotsByID[snapshot.peerID] = snapshot
                }
            } else {
                peerSnapshotsByID[snapshot.peerID] = snapshot
            }
        }
        let merged = Array(peerSnapshotsByID.values)
        lock.unlock()
        peerSubject.send(merged)
        DispatchQueue.main.async { [weak self] in
            self?.peerEventsDelegate?.didUpdatePeerSnapshots(merged)
        }
    }
}

// MARK: - Transport conformance

extension MultiTransportManager: Transport {

    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        peerSubject.eraseToAnyPublisher()
    }

    func currentPeerSnapshots() -> [TransportPeerSnapshot] {
        peerSubject.value
    }

    var myPeerID: PeerID { primary.myPeerID }
    var myNickname: String { primary.myNickname }

    func setNickname(_ nickname: String) {
        transports.forEach { $0.setNickname(nickname) }
    }

    func startServices() {
        transports.forEach { $0.startServices() }
    }

    func stopServices() {
        transports.forEach { $0.stopServices() }
    }

    func emergencyDisconnectAll() {
        transports.forEach { $0.emergencyDisconnectAll() }
        lock.lock()
        peerSnapshotsByID.removeAll()
        lock.unlock()
        peerSubject.send([])
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool {
        transports.contains { $0.isPeerConnected(peerID) }
    }

    func isPeerReachable(_ peerID: PeerID) -> Bool {
        transports.contains { $0.isPeerReachable(peerID) }
    }

    func peerNickname(peerID: PeerID) -> String? {
        transports.lazy.compactMap { $0.peerNickname(peerID: peerID) }.first
    }

    func getPeerNicknames() -> [PeerID: String] {
        // Merge all transports; primary wins on conflict.
        var merged: [PeerID: String] = [:]
        for t in transports.reversed() {
            merged.merge(t.getPeerNicknames()) { _, new in new }
        }
        return merged
    }

    func getPeersWithAgent(_ agentID: String) -> [PeerID] {
        Array(Set(transports.flatMap { $0.getPeersWithAgent(agentID) }))
    }

    // Broadcast: primary transport only in Phase 1.
    // Phase 2 will dispatch immediate-priority SGEnvelopes across all links.
    func sendMessage(_ content: String, mentions: [String]) {
        primary.sendMessage(content, mentions: mentions)
    }

    func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        primary.sendMessage(content, mentions: mentions, messageID: messageID, timestamp: timestamp)
    }

    // Directed: route to whichever transport has the peer connected.
    private func transport(for peerID: PeerID) -> any Transport {
        transports.first { $0.isPeerConnected(peerID) } ?? primary
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        transport(for: peerID).sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        transport(for: peerID).sendReadReceipt(receipt, to: peerID)
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        transport(for: peerID).sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
    }

    func sendBroadcastAnnounce() {
        transports.forEach { $0.sendBroadcastAnnounce() }
    }

    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
        transport(for: peerID).sendDeliveryAck(for: messageID, to: peerID)
    }

    func sendFileBroadcast(_ packet: SafeGuardianFilePacket, transferId: String) {
        primary.sendFileBroadcast(packet, transferId: transferId)
    }

    func sendFilePrivate(_ packet: SafeGuardianFilePacket, to peerID: PeerID, transferId: String) {
        transport(for: peerID).sendFilePrivate(packet, to: peerID, transferId: transferId)
    }

    func cancelTransfer(_ transferId: String) {
        transports.forEach { $0.cancelTransfer(transferId) }
    }

    func getFingerprint(for peerID: PeerID) -> String? {
        transports.lazy.compactMap { $0.getFingerprint(for: peerID) }.first
    }

    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState {
        primary.getNoiseSessionState(for: peerID)
    }

    func triggerHandshake(with peerID: PeerID) {
        primary.triggerHandshake(with: peerID)
    }

    func getNoiseService() -> NoiseEncryptionService {
        primary.getNoiseService()
    }

    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        primary.sendVerifyChallenge(to: peerID, noiseKeyHex: noiseKeyHex, nonceA: nonceA)
    }

    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        primary.sendVerifyResponse(to: peerID, noiseKeyHex: noiseKeyHex, nonceA: nonceA)
    }

    func acceptPendingFile(id: String) -> URL? {
        primary.acceptPendingFile(id: id)
    }

    func declinePendingFile(id: String) {
        primary.declinePendingFile(id: id)
    }

    func negotiatedMTU(for peerID: PeerID) -> Int {
        transport(for: peerID).negotiatedMTU(for: peerID)
    }

    func lastKnownRSSI(for peerID: PeerID) -> Int? {
        transports.lazy.compactMap { $0.lastKnownRSSI(for: peerID) }.first
    }

    func meshPacketRate() -> Double {
        transports.reduce(0.0) { $0 + $1.meshPacketRate() }
    }

    // Broadcast an SGEnvelope.
    // Immediate-priority and state ticks fire on registered mesh transports + LAN.
    // Other priorities use primary (BLE) + LAN gateway if available.
    func sendSGEnvelope(_ envelope: SGEnvelope) {
        if envelope.priority == .immediate || envelope.payloadType == .stateTick {
            transports.forEach { $0.sendSGEnvelope(envelope) }
        } else {
            primary.sendSGEnvelope(envelope)
        }
        lanGateway?.send(envelope)
    }

    private func handleLANEnvelope(_ envelope: SGEnvelope) {
        guard !deduplicator.isDuplicate(envelope.messageIdString) else { return }
        sgEnvelopeHandler?.handle(envelope, from: PeerID(str: "gateway"))
        delegate?.didReceiveSGEnvelope(envelope, from: PeerID(str: "gateway"))
    }

    func getCurrentBluetoothState() -> CBManagerState {
        transports.lazy.compactMap { t -> CBManagerState? in
            let s = t.getCurrentBluetoothState()
            return s != .unknown ? s : nil
        }.first ?? .unknown
    }
}

// MARK: - SafeGuardianDelegate (receives events from child transports)

extension MultiTransportManager: SafeGuardianDelegate {

    func didReceiveMessage(_ message: SafeGuardianMessage) {
        guard !deduplicator.isDuplicate(message.id) else { return }
        delegate?.didReceiveMessage(message)
    }

    func didConnectToPeer(_ peerID: PeerID) {
        delegate?.didConnectToPeer(peerID)
    }

    func didDisconnectFromPeer(_ peerID: PeerID) {
        // Only propagate if the peer is gone from every transport.
        let stillConnected = transports.contains { $0.isPeerConnected(peerID) }
        guard !stillConnected else { return }
        lock.lock()
        peerSnapshotsByID.removeValue(forKey: peerID)
        let merged = Array(peerSnapshotsByID.values)
        lock.unlock()
        peerSubject.send(merged)
        delegate?.didDisconnectFromPeer(peerID)
    }

    func didUpdatePeerList(_ peers: [PeerID]) {
        // Handled via peerSnapshotPublisher merging; suppress to avoid double-update.
    }

    func isFavorite(fingerprint: String) -> Bool {
        delegate?.isFavorite(fingerprint: fingerprint) ?? false
    }

    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        delegate?.didUpdateMessageDeliveryStatus(messageID, status: status)
    }

    func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {
        let key = "\(peerID.id)-\(type.rawValue)-\(Int(timestamp.timeIntervalSince1970 * 1000))"
        guard !deduplicator.isDuplicate(key) else { return }
        delegate?.didReceiveNoisePayload(from: peerID, type: type, payload: payload, timestamp: timestamp)
    }

    func didUpdateBluetoothState(_ state: CBManagerState) {
        delegate?.didUpdateBluetoothState(state)
    }

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String,
                                 timestamp: Date, messageID: String?) {
        let key = messageID ?? "\(peerID.id)-\(content.hashValue)-\(Int(timestamp.timeIntervalSince1970 * 1000))"
        guard !deduplicator.isDuplicate(key) else { return }
        delegate?.didReceivePublicMessage(from: peerID, nickname: nickname, content: content,
                                          timestamp: timestamp, messageID: messageID)
    }

    func didReceiveSGEnvelope(_ envelope: SGEnvelope, from peerID: PeerID) {
        guard !deduplicator.isDuplicate(envelope.messageIdString) else { return }
        sgEnvelopeHandler?.handle(envelope, from: peerID)
        delegate?.didReceiveSGEnvelope(envelope, from: peerID)
    }
}

// MARK: - TransportPeerEventsDelegate (receives peer events from child transports)

extension MultiTransportManager: TransportPeerEventsDelegate {
    @MainActor func didUpdatePeerSnapshots(_ peers: [TransportPeerSnapshot]) {
        mergePeerSnapshots(peers)
    }
}
