import BitLogger
import Foundation
import Network

// LANGatewayTransport sends and receives SGEnvelope payloads over UDP to an APEX
// command-post server on the local WiFi LAN. It is not a peer mesh transport and
// does not conform to Transport — it is a separate service attached to
// MultiTransportManager alongside the BLE and Reticulum transports.
//
// Deployment scenario: field device connects to command-post WiFi AP, gateway
// IP is configured in tenant.json (or set manually). The APEX local_server.py
// listens on the same port and relays SGEnvelopes to/from the operational backend.
//
// UDP is used rather than TCP because:
// - SGEnvelopes are self-contained and idempotent (deduplication by messageId)
// - No connection handshake latency for infrequent bursts
// - Graceful degradation if server is unreachable — packets drop, mesh continues
//
// Requires NSLocalNetworkUsageDescription in Info.plist (already added).
// Server-side stub: local_server.py needs a UDP socket on Config.defaultPort
// that decodes SGEnvelope bytes and dispatches by payloadType.

final class LANGatewayTransport {

    struct Config {
        let host: String
        let port: UInt16

        static let defaultPort: UInt16 = 9472

        // UserDefaults keys written by the app when it receives tenant config.
        static let hostKey = "sg.gateway.host"
        static let portKey = "sg.gateway.port"

        static func fromUserDefaults() -> Config? {
            guard let host = UserDefaults.standard.string(forKey: hostKey),
                  !host.isEmpty else { return nil }
            let rawPort = UserDefaults.standard.integer(forKey: portKey)
            let port = rawPort > 0 ? UInt16(rawPort) : defaultPort
            return Config(host: host, port: port)
        }

        static func save(host: String, port: UInt16 = defaultPort) {
            UserDefaults.standard.set(host, forKey: hostKey)
            UserDefaults.standard.set(Int(port), forKey: portKey)
        }
    }

    // MARK: - State

    private(set) var isConnected = false
    var onEnvelopeReceived: ((SGEnvelope) -> Void)?

    private let config: Config
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "sg.langateway", qos: .userInitiated)
    private var heartbeatTimer: DispatchSourceTimer?
    private var reconnectWorkItem: DispatchWorkItem?

    // MARK: - Init

    init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.setupConnection()
            self?.startHeartbeat()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.heartbeatTimer?.cancel()
            self?.heartbeatTimer = nil
            self?.reconnectWorkItem?.cancel()
            self?.reconnectWorkItem = nil
            self?.connection?.cancel()
            self?.connection = nil
            self?.isConnected = false
        }
    }

    // MARK: - Send

    func send(_ envelope: SGEnvelope) {
        queue.async { [weak self] in
            guard let self, let conn = self.connection, self.isConnected else { return }
            conn.send(content: envelope.encode(), completion: .idempotent)
        }
    }

    // MARK: - Private

    private func setupConnection() {
        guard let nwPort = NWEndpoint.Port(rawValue: config.port) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: nwPort,
            using: params
        )

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isConnected = true
                self?.receiveLoop()
            case .failed(let error):
                SecureLogger.warning("LANGateway connection failed: \(error)", category: .session)
                self?.isConnected = false
                self?.scheduleReconnect()
            case .cancelled:
                self?.isConnected = false
            default:
                break
            }
        }

        conn.start(queue: queue)
        connection = conn
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65507) { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty, let envelope = SGEnvelope.decode(data) {
                self?.onEnvelopeReceived?(envelope)
            }
            guard error == nil else { return }
            self?.receiveLoop()
        }
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.setupConnection()
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            let ping = SGEnvelope.build(
                priority: .routine,
                payloadType: .agentMsg,
                sourceId: Data(repeating: 0, count: 8),
                payload: Data("ping".utf8)
            )
            self.send(ping)
        }
        timer.resume()
        heartbeatTimer = timer
    }
}
