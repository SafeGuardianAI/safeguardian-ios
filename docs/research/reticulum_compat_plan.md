# iOS–Android Reticulum Compatibility Plan

The iOS and Android stacks are incompatible at Layer 0. iOS advertises the bitchat GATT service UUID
(F47B5E2D-...) and writes packets using BinaryProtocol framing. Android speaks the Reticulum BLE
interface which has different service UUIDs, different framing, and different addressing. Because the
Helix relay nodes are Reticulum nodes, iOS bitchat packets cannot be relayed through them to Android
at all — iOS is isolated from the shared infrastructure unless it can also speak Reticulum.

The fix is additive. The existing bitchat BLEService stays untouched for iOS-to-iOS compatibility and
open-source interoperability. Reticulum support is a second conforming Transport adapter running in
parallel.

---

## What needs to be built

Four pieces, none touching existing code except the ChatViewModel wiring line.

---

### 1. localPackages/Reticulum/ — Rust xcframework

Same pattern as localPackages/Arti/. The Rust crate exposes a C FFI covering three operations:
Reticulum identity management, Reticulum BLE interface framing, and LXMF message encoding/decoding.

```c
// localPackages/Reticulum/Frameworks/include/reticulum.h

int  rns_identity_create(const char *keystore_path);
int  rns_identity_load(const char *keystore_path);
void rns_identity_get_destination_hash(uint8_t out[10]);  // 80-bit Reticulum dest hash
void rns_identity_get_public_key(uint8_t out[32]);        // Ed25519 public key

int  rns_ble_on_receive(const uint8_t *data, size_t len, const uint8_t link_id[16]);
int  rns_ble_send(const uint8_t link_id[16], const uint8_t *data, size_t len);
void rns_ble_on_link_up(const uint8_t link_id[16]);
void rns_ble_on_link_down(const uint8_t link_id[16]);

typedef struct {
    uint8_t  source[10];
    uint8_t  destination[10];
    uint8_t *content;
    size_t   content_len;
    uint64_t timestamp_ms;
} rns_lxmf_message_t;

int  rns_lxmf_encode(const rns_lxmf_message_t *msg, uint8_t **out, size_t *out_len);
int  rns_lxmf_decode(const uint8_t *data, size_t len, rns_lxmf_message_t *out);
void rns_lxmf_free(rns_lxmf_message_t *msg);

typedef void (*rns_on_lxmf_t)(const rns_lxmf_message_t *msg, void *ctx);
typedef void (*rns_on_send_ble_t)(const uint8_t link_id[16],
                                   const uint8_t *data, size_t len, void *ctx);
void rns_set_callbacks(rns_on_lxmf_t on_lxmf, rns_on_send_ble_t on_send_ble, void *ctx);
```

Build script mirrors Arti/build-ios.sh:
- cargo build --target aarch64-apple-ios --release
- cargo build --target aarch64-apple-ios-sim --release
- xcodebuild -create-xcframework to produce Frameworks/reticulum.xcframework

Swift wrapper:

```swift
// localPackages/Reticulum/Sources/ReticulumNode.swift

import CoreBluetooth

public final class ReticulumNode: NSObject {
    // Reticulum BLE service UUID (from ble-reticulum interface spec — different from bitchat)
    public static let reticulumServiceUUID = CBUUID(string: "...")
    public static let reticulumCharUUID    = CBUUID(string: "...")

    public init(keystorePath: String) {
        rns_identity_load(keystorePath)
        rns_set_callbacks(onLXMF, onSendBLE, Unmanaged.passRetained(self).toOpaque())
    }

    public func didReceive(_ data: Data, from linkID: UUID) {
        data.withUnsafeBytes { buf in
            var id = linkID.uuid
            rns_ble_on_receive(buf.baseAddress, buf.count, &id)
        }
    }

    public func linkUp(_ linkID: UUID) { var id = linkID.uuid; rns_ble_on_link_up(&id) }
    public func linkDown(_ linkID: UUID) { var id = linkID.uuid; rns_ble_on_link_down(&id) }
    public func send(lxmf: LXMFMessage) { ... }

    public var onSendBLE: ((UUID, Data) -> Void)?
    public var onLXMF:    ((LXMFMessage) -> Void)?
}

public struct LXMFMessage {
    public enum Destination { case broadcast; case single(Data) }
    public let destination: Destination
    public let content: Data
    public let timestampMs: UInt64
}
```

---

### 2. SafeGuardian/Services/ReticulumTransport.swift

Conforms to Transport. Runs a second set of CBCentralManager + CBPeripheralManager scanning and
advertising the Reticulum service UUID. Maps LXMF messages to SafeGuardianMessage via ADSP atom
decode. Maps outbound SafeGuardianMessage to LXMF via ADSP atom encode.

```swift
// SafeGuardian/Services/ReticulumTransport.swift

import BitFoundation
import Combine

final class ReticulumTransport: NSObject, Transport {
    private let node: ReticulumNode
    private let bleQueue = DispatchQueue(label: "reticulum.ble", qos: .userInitiated)
    private var centralManager:   CBCentralManager?
    private var peripheralManager: CBPeripheralManager?

    weak var delegate: SafeGuardianDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    private let peerSnapshotSubject = PassthroughSubject<[TransportPeerSnapshot], Never>()
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        peerSnapshotSubject.eraseToAnyPublisher()
    }

    var myPeerID: PeerID    // derived from Reticulum destination hash (10 bytes)
    var myNickname: String = "anon"
    var localAgentIDs: [String] = []
    private var peers: [PeerID: TransportPeerSnapshot] = [:]

    init(node: ReticulumNode) {
        self.node = node
        var hash = Data(count: 10)
        rns_identity_get_destination_hash(&hash)
        self.myPeerID = PeerID(data: hash)
        super.init()
        node.onSendBLE = { [weak self] linkID, data in self?.writeToBLE(linkID: linkID, data: data) }
        node.onLXMF    = { [weak self] message in self?.handleLXMF(message) }
    }

    func startServices() {
        centralManager    = CBCentralManager(delegate: self, queue: bleQueue)
        peripheralManager = CBPeripheralManager(delegate: self, queue: bleQueue)
    }

    func stopServices() {
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
    }

    // Scan for Reticulum BLE nodes — different service UUID from bitchat scan
    private func startScanning() {
        centralManager?.scanForPeripherals(
            withServices: [ReticulumNode.reticulumServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func sendMessage(_ content: String, mentions: [String]) {
        guard let atomBytes = ADSPAtom.wrap(
            type: "comms.message",
            payload: ["content": content, "mentions": mentions],
            signingKey: node.signingPrivateKey, peerID: myPeerID
        ) else { return }
        node.send(lxmf: LXMFMessage(destination: .broadcast, content: atomBytes,
                                    timestampMs: UInt64(Date().timeIntervalSince1970 * 1000)))
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID,
                            recipientNickname: String, messageID: String) {
        guard let dest = reticulumDest(for: peerID),
              let atomBytes = ADSPAtom.wrap(
                  type: "comms.message",
                  payload: ["content": content, "message_id": messageID],
                  signingKey: node.signingPrivateKey, peerID: myPeerID
              ) else { return }
        node.send(lxmf: LXMFMessage(destination: .single(dest), content: atomBytes,
                                    timestampMs: UInt64(Date().timeIntervalSince1970 * 1000)))
    }

    private func handleLXMF(_ message: LXMFMessage) {
        guard let atom = ADSPAtom.verify(message.content,
                                          knownKeys: knownSigningKeys()) else { return }
        let senderPeerID = PeerID(data: Data(atom.sourceID))
        let ts = Date(timeIntervalSince1970: Double(atom.timestamp) / 1000)
        switch atom.atomType {
        case "comms.message":
            let content   = atom.payloadString(key: "content") ?? ""
            let isPrivate = message.destination != .broadcast
            let msg = SafeGuardianMessage(
                sender: peers[senderPeerID]?.nickname ?? "anon",
                content: content, timestamp: ts,
                isRelay: false, originalSender: nil,
                isPrivate: isPrivate, recipientNickname: nil,
                senderPeerID: senderPeerID
            )
            DispatchQueue.main.async { [weak self] in self?.delegate?.didReceiveMessage(msg) }
        case "nova.state_tick":
            break    // forward to Nova agent state handler when implemented
        default:
            break
        }
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool { peers[peerID]?.isConnected ?? false }
    func isPeerReachable(_ peerID: PeerID) -> Bool { peers[peerID] != nil }
    func peerNickname(peerID: PeerID) -> String? { peers[peerID]?.nickname }
    func getPeerNicknames() -> [PeerID: String] { peers.compactMapValues { $0.nickname } }
    func emergencyDisconnectAll() { stopServices(); peers.removeAll() }
    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) {}
    func getNoiseService() -> NoiseEncryptionService { fatalError("Reticulum transport has no Noise service") }
    func setNickname(_ nickname: String) { myNickname = nickname }
    func sendBroadcastAnnounce() { sendMessage("[announce]", mentions: []) }
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {}
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {}
    func currentPeerSnapshots() -> [TransportPeerSnapshot] { Array(peers.values) }
}
```

---

### 3. SafeGuardian/Services/TransportMux.swift

Presents a single Transport to ChatViewModel. Fans out sends to all transports. Routes private
messages to whichever transport owns the destination peer. Merges peer snapshot publishers.

```swift
// SafeGuardian/Services/TransportMux.swift

import BitFoundation
import Combine

final class TransportMux: Transport {
    private let transports: [Transport]
    private var cancellables = Set<AnyCancellable>()
    private let peerSubject  = PassthroughSubject<[TransportPeerSnapshot], Never>()
    private var peersByID:   [PeerID: TransportPeerSnapshot] = [:]

    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        peerSubject.eraseToAnyPublisher()
    }

    init(transports: [Transport]) {
        self.transports = transports
        // merge: subscribe to each transport's snapshot publisher,
        // update the union map, emit merged list
        transports.forEach { transport in
            transport.peerSnapshotPublisher
                .sink { [weak self] snapshots in
                    guard let self else { return }
                    snapshots.forEach { self.peersByID[$0.peerID] = $0 }
                    self.peerSubject.send(Array(self.peersByID.values))
                }
                .store(in: &cancellables)
        }
    }

    weak var delegate: SafeGuardianDelegate? {
        didSet { transports.forEach { $0.delegate = delegate } }
    }
    weak var peerEventsDelegate: TransportPeerEventsDelegate? {
        didSet { transports.forEach { $0.peerEventsDelegate = peerEventsDelegate } }
    }

    var myPeerID: PeerID          { transports[0].myPeerID }
    var myNickname: String {
        get { transports[0].myNickname }
        set { transports.forEach { $0.myNickname = newValue } }
    }
    var localAgentIDs: [String] {
        get { transports[0].localAgentIDs }
        set { transports.forEach { $0.localAgentIDs = newValue } }
    }

    func startServices()       { transports.forEach { $0.startServices() } }
    func stopServices()        { transports.forEach { $0.stopServices() } }
    func emergencyDisconnectAll() { transports.forEach { $0.emergencyDisconnectAll() } }
    func isPeerConnected(_ id: PeerID) -> Bool { transports.contains { $0.isPeerConnected(id) } }
    func isPeerReachable(_ id: PeerID) -> Bool { transports.contains { $0.isPeerReachable(id) } }
    func getPeerNicknames() -> [PeerID: String] {
        transports.reduce(into: [:]) { dict, t in dict.merge(t.getPeerNicknames()) { a, _ in a } }
    }
    func currentPeerSnapshots() -> [TransportPeerSnapshot] { Array(peersByID.values) }

    func sendMessage(_ content: String, mentions: [String]) {
        transports.forEach { $0.sendMessage(content, mentions: mentions) }
    }
    func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        transports.forEach { $0.sendMessage(content, mentions: mentions,
                                            messageID: messageID, timestamp: timestamp) }
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID,
                            recipientNickname: String, messageID: String) {
        // route to the transport that owns this peer; try all on miss
        let owner = transports.first { $0.isPeerReachable(peerID) } ?? transports[0]
        owner.sendPrivateMessage(content, to: peerID,
                                 recipientNickname: recipientNickname, messageID: messageID)
    }

    func setNickname(_ nickname: String) { transports.forEach { $0.setNickname(nickname) } }
    func getFingerprint(for peerID: PeerID) -> String? {
        transports.compactMap { $0.getFingerprint(for: peerID) }.first
    }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState {
        transports.map { $0.getNoiseSessionState(for: peerID) }
                  .first { if case .none = $0 { return false } else { return true } }
            ?? .none
    }
    func triggerHandshake(with peerID: PeerID) {
        transports.first { $0.isPeerReachable(peerID) }?.triggerHandshake(with: peerID)
    }
    func getNoiseService() -> NoiseEncryptionService {
        // Only BLEService has a Noise service; Reticulum transport does not expose one
        transports.first { $0 is BLEService }!.getNoiseService()
    }
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        transports.first { $0.isPeerReachable(peerID) }?.sendReadReceipt(receipt, to: peerID)
    }
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        transports.forEach { $0.sendFavoriteNotification(to: peerID, isFavorite: isFavorite) }
    }
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
        transports.first { $0.isPeerReachable(peerID) }?.sendDeliveryAck(for: messageID, to: peerID)
    }
    func sendBroadcastAnnounce() { transports.forEach { $0.sendBroadcastAnnounce() } }
    func peerNickname(peerID: PeerID) -> String? {
        transports.compactMap { $0.peerNickname(peerID: peerID) }.first
    }
    func getPeersWithAgent(_ agentID: String) -> [PeerID] {
        transports.flatMap { $0.getPeersWithAgent(agentID) }
    }
}
```

ChatViewModel wiring change — the only existing line that changes:

```swift
// SafeGuardian/ViewModels/ChatViewModel.swift

// Before:
// let meshService: BLEService = BLEService(...)

// After:
let bleTransport = BLEService(keychain: keychain, idBridge: idBridge,
                               identityManager: identityManager)
let rnsNode      = ReticulumNode(keystorePath: reticulumKeystorePath())
let rnsTransport = ReticulumTransport(node: rnsNode)
let meshService  = TransportMux(transports: [bleTransport, rnsTransport])
```

---

### 4. packages/core-swift/Sources/SafeGuardianCore/ADSPAtom.swift

Shared contract package (already planned as a stub). Used by both the iOS app and the macOS daemon.
Mirrors the ADSP envelope from the adaptation plan.

```swift
// packages/core-swift/Sources/SafeGuardianCore/ADSPAtom.swift

import BitFoundation
import CryptoKit

public struct ADSPAtom {
    public let schemaVersion: String     // "adsp/1.0"
    public let atomType:      String
    public let tenantID:      String
    public let sourceType:    String     // "nova" | "trek" | "apex" | "radio" | "manual"
    public let sourceID:      Data       // peer_id bytes
    public let privacyScopes: [String]  // subset of the six allowed scopes
    public let payload:       Data       // canonical JSON (keys sorted lexicographically)
    public let signature:     Data       // Ed25519, 64 bytes
    public let timestamp:     UInt64     // ms since epoch

    // Wrap: sign and encode an outbound atom
    public static func wrap(
        type: String,
        payload: [String: Any],
        signingKey: Data,
        peerID: PeerID,
        tenantID: String = "",
        privacyScopes: [String] = []
    ) -> Data? {
        // 1. canonical_json(payload)
        // 2. build atom fields (without signature)
        // 3. canonical_json(atom_without_sig)
        // 4. ed25519_sign(signingKey, signingData) -> signature
        // 5. encode full atom as canonical JSON
        ...
    }

    // Verify: decode and verify an inbound atom against known signing keys
    public static func verify(_ data: Data,
                               knownKeys: [Data: Data]) -> ADSPAtom? {
        // 1. decode JSON -> ADSPAtom
        // 2. look up signing key by sourceID
        // 3. canonical_json(atom_without_sig)
        // 4. ed25519_verify(key, signingData, signature) -> Bool
        // 5. check tenantID, check privacyScopes against ALLOWED_SCOPES
        ...
    }

    public func payloadString(key: String) -> String? { ... }
}
```

---

## Identity mismatch note

Bitchat peer ID = SHA256(noise_static_public_key)[:8] (8 bytes)
Reticulum destination hash = SHA256(ed25519_public_key)[:10] (10 bytes)

These are different namespaces. A person reachable on both networks appears as two peers until
the iOS app observes an ADSP atom whose payload carries both a reticulum_dest_hash and a
noise_public_key field. At that point ChatViewModel can merge them into a single display entry.
This merge logic is a future addition to ChatViewModel; it is not a prerequisite for basic
message exchange to work.

## What does not change

BinaryProtocol, BLEService, NoiseProtocol, and the full bitchat mesh engine are untouched.
The Reticulum stack is additive. Both BLE service UUIDs are advertised simultaneously —
CoreBluetooth's CBPeripheralManager handles multiple services without conflict. CBCentralManager
scans for both service UUIDs in the same scanForPeripherals call.
