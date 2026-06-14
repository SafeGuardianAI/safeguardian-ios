import BitFoundation
import Combine
import CoreBluetooth
import Foundation

enum LinkType: String, Sendable {
    case ble         // bitchat BLE mesh
    case reticulum   // Reticulum / RNode LoRa bridge
    case wifiMesh    // MultipeerConnectivity peer-to-peer
    case lanGateway  // UDP LAN gateway (APEX command post)
}

enum MessagePriority: UInt8, Sendable {
    case immediate = 0
    case delayed   = 1
    case minimal   = 2
    case expectant = 3
    case routine   = 4
}

struct TransportPeerSnapshot: Equatable, Hashable {
    let peerID: PeerID
    let nickname: String
    let isConnected: Bool
    let noisePublicKey: Data?
    let lastSeen: Date
    var agentIDs: [String] = []
    var linkType: LinkType = .ble
    var estimatedBandwidthBps: Int = 500_000
}

protocol Transport: AnyObject {
    // Event sink
    var delegate: SafeGuardianDelegate? { get set }
    // Peer events (preferred over publishers for UI)
    var peerEventsDelegate: TransportPeerEventsDelegate? { get set }
    
    // Peer snapshots (for non-UI services)
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> { get }
    func currentPeerSnapshots() -> [TransportPeerSnapshot]

    // Identity
    var myPeerID: PeerID { get }
    var myNickname: String { get }
    func setNickname(_ nickname: String)

    // Lifecycle
    func startServices()
    func stopServices()
    func emergencyDisconnectAll()

    // Connectivity and peers
    func isPeerConnected(_ peerID: PeerID) -> Bool
    func isPeerReachable(_ peerID: PeerID) -> Bool
    func peerNickname(peerID: PeerID) -> String?
    func getPeerNicknames() -> [PeerID: String]
    func getPeersWithAgent(_ agentID: String) -> [PeerID]
    var localAgentIDs: [String] { get set }

    // Protocol utilities
    func getFingerprint(for peerID: PeerID) -> String?
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState
    func triggerHandshake(with peerID: PeerID)
    func getNoiseService() -> NoiseEncryptionService

    // Messaging
    func sendMessage(_ content: String, mentions: [String])
    func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date)
    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String)
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID)
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool)
    func sendBroadcastAnnounce()
    func sendDeliveryAck(for messageID: String, to peerID: PeerID)
    func sendFileBroadcast(_ packet: SafeGuardianFilePacket, transferId: String)
    func sendFilePrivate(_ packet: SafeGuardianFilePacket, to peerID: PeerID, transferId: String)
    func cancelTransfer(_ transferId: String)

    // QR verification (optional for transports)
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)

    // Pending file management (BCH-01-002: files held in memory until user accepts)
    func acceptPendingFile(id: String) -> URL?
    func declinePendingFile(id: String)

    // Bench instrumentation
    func negotiatedMTU(for peerID: PeerID) -> Int
    func lastKnownRSSI(for peerID: PeerID) -> Int?

    // Mesh load
    func meshPacketRate() -> Double   // packets/second observed in last 30s

    // Bluetooth state (BLE transports return real state; others return .unknown)
    func getCurrentBluetoothState() -> CBManagerState
}

extension Transport {
    func negotiatedMTU(for peerID: PeerID) -> Int { TransportConfig.bleDefaultFragmentSize + 43 }
    func lastKnownRSSI(for peerID: PeerID) -> Int? { nil }
    func meshPacketRate() -> Double { 0 }
    func getCurrentBluetoothState() -> CBManagerState { .unknown }
    func getPeersWithAgent(_ agentID: String) -> [PeerID] { [] }
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {}
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {}
    func sendFileBroadcast(_ packet: SafeGuardianFilePacket, transferId: String) {}
    func sendFilePrivate(_ packet: SafeGuardianFilePacket, to peerID: PeerID, transferId: String) {}
    func cancelTransfer(_ transferId: String) {}

    func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        sendMessage(content, mentions: mentions)
    }

    func acceptPendingFile(id: String) -> URL? { nil }
    func declinePendingFile(id: String) {}
}

protocol TransportPeerEventsDelegate: AnyObject {
    @MainActor func didUpdatePeerSnapshots(_ peers: [TransportPeerSnapshot])
}

extension BLEService: Transport {}
