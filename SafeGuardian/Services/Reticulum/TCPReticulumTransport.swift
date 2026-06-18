#if os(macOS)
import BitFoundation
import BitLogger
import Combine
import Foundation
import Network

// Transport conformance backed by a TCP connection to a local Reticulum daemon.
// Connects to 127.0.0.1:[sg.rns.tcpPort, default 4242] and speaks the HDLC framing
// used by the Python rns TCPServerInterface.
//
// Setup: add a [interface:Local TCP Server] block to ~/.reticulum/config with
// interfacetype = TCPServerInterface and listen_port = 4242, then run `rns --daemon`.
// The macOS app auto-connects on startServices() and reconnects on disconnect.
final class TCPReticulumTransport: @unchecked Sendable {

    static let portDefaultsKey = "sg.rns.tcpPort"
    static let defaultPort     = 4242
    static let sgEnvelopeTitle = "sg-envelope"

    private static let hdlcFlag: UInt8 = 0x7E
    private static let hdlcEsc:  UInt8 = 0x7D

    // MARK: - Transport protocol state

    weak var delegate: SafeGuardianDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?
    var localAgentIDs: [String] = []

    let identity: ReticulumIdentity
    private let noiseService: NoiseEncryptionService
    private var _myNickname: String

    private var connectedPeers: [PeerID: ReticulumAnnounce] = [:]
    private var peerNicknames:  [PeerID: String] = [:]
    private let peerSubject = CurrentValueSubject<[TransportPeerSnapshot], Never>([])

    private var connection:    NWConnection?
    private let queue = DispatchQueue(label: "sg.rns.tcp", qos: .userInitiated)
    private var receiveBuffer  = Data()
    private var reconnectWork: DispatchWorkItem?
    private var announceTimer: Timer?

    // MARK: - Init

    init(identity: ReticulumIdentity, keychain: KeychainManagerProtocol) {
        self.identity     = identity
        self.noiseService = NoiseEncryptionService(keychain: keychain)
        self._myNickname  = UserDefaults.standard.string(forKey: "bitchat.nickname") ?? "anon"
    }

    // MARK: - HDLC

    private static func hdlcEncode(_ data: Data) -> Data {
        var out = Data([hdlcFlag])
        for b in data {
            if b == hdlcFlag      { out.append(contentsOf: [hdlcEsc, 0x5E]) }
            else if b == hdlcEsc  { out.append(contentsOf: [hdlcEsc, 0x5D]) }
            else                  { out.append(b) }
        }
        out.append(hdlcFlag)
        return out
    }

    private func consumeFrames() -> [Data] {
        var frames: [Data] = []
        var segments: [Data] = []
        var current = Data()
        for b in receiveBuffer {
            if b == Self.hdlcFlag { segments.append(current); current = Data() }
            else { current.append(b) }
        }
        receiveBuffer = current
        for seg in segments.dropFirst() where !seg.isEmpty {
            var frame = Data(); var esc = false
            for b in seg {
                if esc { frame.append(b ^ 0x20); esc = false }
                else if b == Self.hdlcEsc { esc = true }
                else { frame.append(b) }
            }
            frames.append(frame)
        }
        return frames
    }

    // MARK: - Connection

    func openConnection() {
        let rawPort = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
        let port = rawPort > 0 ? rawPort : Self.defaultPort
        guard let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port)) else { return }
        let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveLoop()
                self?.broadcastAnnounce()
            case .failed:
                self?.scheduleReconnect()
            default:
                break
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.openConnection() }
        reconnectWork = w
        queue.asyncAfter(deadline: .now() + 5, execute: w)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                for frame in self.consumeFrames() { self.handlePacket(frame) }
            }
            if error == nil { self.receiveLoop() }
        }
    }

    func write(_ data: Data) {
        connection?.send(content: Self.hdlcEncode(data), completion: .idempotent)
    }

    // MARK: - Packet handling

    func handlePacket(_ data: Data) {
        guard let packet = ReticulumDataPacket.decode(data) else { return }
        switch packet.header.packetType {
        case .announce:
            guard let announce = ReticulumAnnounce.decode(packet.payload) else { return }
            let peerID = PeerID(hexData: announce.destinationHash)
            connectedPeers[peerID] = announce
            peerNicknames[peerID] = String(data: announce.appData, encoding: .utf8)
            emitPeerSnapshots()
            delegate?.didConnectToPeer(peerID)
        case .data:
            guard let lxmf = LXMFMessage.decode(packet.payload) else { return }
            let senderID = PeerID(hexData: lxmf.source)
            if lxmf.title == Data(Self.sgEnvelopeTitle.utf8),
               let envelope = SGEnvelope.decode(lxmf.content) {
                delegate?.didReceiveSGEnvelope(envelope, from: senderID)
                return
            }
            let ts = Date(timeIntervalSince1970: Double(lxmf.timestamp) / 1000.0)
            delegate?.didReceivePublicMessage(
                from: senderID,
                nickname: peerNicknames[senderID] ?? senderID.id.prefix(8).description,
                content: String(data: lxmf.content, encoding: .utf8) ?? "",
                timestamp: ts, messageID: nil
            )
        default:
            break
        }
    }

    func broadcastAnnounce() {
        guard let nickData = _myNickname.data(using: .utf8),
              let signed   = try? ReticulumAnnounce.build(identity: identity, appData: nickData) else { return }
        let header = ReticulumPacketHeader(
            ifac: false, headerType: 0, contextFlags: 0,
            propagation: .broadcast, destinationType: .single, packetType: .announce, hops: 0
        )
        let packet = ReticulumDataPacket(
            header: header, destinationHash: identity.destinationHash,
            context: 0, payload: signed.encode()
        )
        write(packet.encode())
    }

    func emitPeerSnapshots() {
        let snapshots = connectedPeers.map { (peerID, announce) in
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: peerNicknames[peerID] ?? peerID.id.prefix(8).description,
                isConnected: true, noisePublicKey: Data(announce.signingPublicKey),
                lastSeen: Date(), linkType: .reticulum, estimatedBandwidthBps: 50_000
            )
        }
        peerSubject.send(snapshots)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.peerEventsDelegate?.didUpdatePeerSnapshots(snapshots)
        }
    }
}
#endif
