import Foundation

public actor ReticulumService {
    public static let shared = ReticulumService()

    private var node: Node?
    private var eventSub: EventSubscription?
    private var eventTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (NodeEvent) -> Void)?

    private init() {}

    public func setEventHandler(_ handler: @escaping @Sendable (NodeEvent) -> Void) {
        eventHandler = handler
    }

    public func start(
        displayName: String,
        tcpClients: [String] = ["rmap.world:4242"],
        storageDir: String? = nil
    ) throws {
        let n = Node()
        let dir = storageDir ?? defaultStorageDir()
        let config = NodeConfig(
            name: displayName,
            storageDir: dir,
            tcpClients: tcpClients,
            broadcast: true,
            announceIntervalSeconds: 300,
            staleAfterMinutes: 30,
            announceCapabilities: "sg",
            hubMode: .autonomous,
            hubIdentityHash: nil,
            hubApiBaseUrl: nil,
            hubApiKey: nil,
            hubRefreshIntervalSeconds: 3600
        )
        try n.start(config: config)
        node = n
        startEventLoop(n)
    }

    public func stop() throws {
        eventTask?.cancel()
        eventTask = nil
        eventSub?.close()
        eventSub = nil
        try node?.stop()
        node = nil
    }

    public func status() -> NodeStatus? {
        node?.getStatus()
    }

    @discardableResult
    public func sendMessage(to destinationHex: String, body: String, title: String? = nil) throws -> String {
        guard let n = node else { throw ReticulumServiceError.notStarted }
        let req = SendLxmfRequest(
            destinationHex: destinationHex,
            bodyUtf8: body,
            title: title,
            sendMode: .auto
        )
        return try n.sendLxmf(request: req)
    }

    public func listPeers() throws -> [PeerRecord] {
        guard let n = node else { throw ReticulumServiceError.notStarted }
        return try n.listPeers()
    }

    public func announceNow() throws {
        guard let n = node else { throw ReticulumServiceError.notStarted }
        try n.announceNow()
    }

    private func startEventLoop(_ n: Node) {
        let sub = n.subscribeEvents()
        eventSub = sub
        // Run the blocking poll off the actor executor on a background thread.
        eventTask = Task {
            while !Task.isCancelled {
                let event: NodeEvent? = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .background).async {
                        cont.resume(returning: sub.next(timeoutMs: 1000))
                    }
                }
                guard let event else { continue }
                eventHandler?(event)
            }
        }
    }

    private func defaultStorageDir() -> String? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("reticulum").path
    }
}

public enum ReticulumServiceError: Error {
    case notStarted
}
