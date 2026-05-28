#if os(macOS)
import Foundation
import Combine
import Tor
import BitFoundation

@MainActor
final class SafeGuardianIPCHost {
    static let shared = SafeGuardianIPCHost()

    private var socketPath: String {
        let dir = appSupportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let candidate = dir.appendingPathComponent("tui.sock").path
        // sockaddr_un.sun_path is 103 bytes on macOS; sandbox container paths exceed this.
        // Fall back to the temp directory whose path is always short enough.
        guard candidate.utf8.count <= 103 else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("sg.tui.sock").path
        }
        return candidate
    }

    private var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat.safeguardian", isDirectory: true)
    }

    private(set) var source: DispatchSourceRead?
    private(set) var listeningSocket: Int32 = -1
    var activeClients: [Int32: Data] = [:]
    var clientCancellables: [Int32: Set<AnyCancellable>] = [:]
    var chatViewModel: ChatViewModel?
    private let ioQueue = DispatchQueue(label: "chat.safeguardian.ipc.io")

    private init() {}

    func start(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        log("Starting IPC Host...")
        let path = socketPath
        unlink(path)
        listeningSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listeningSocket >= 0 else { log("Failed to create socket"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = path.data(using: .utf8)!
        pathData.withUnsafeBytes { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPtr in
                let dest = UnsafeMutableRawPointer(sunPtr).assumingMemoryBound(to: UInt8.self)
                let count = min(pathData.count, 103)
                dest.update(from: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count)
                dest[count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        var bindAddr = addr
        let bound = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listeningSocket, $0, socklen_t(addr.sun_len)) }
        }
        guard bound >= 0 else {
            log("Bind failed: \(String(cString: strerror(errno)))")
            return
        }
        guard listen(listeningSocket, 5) >= 0 else { log("Listen failed"); return }
        log("Listening on \(path)")
        source = DispatchSource.makeReadSource(fileDescriptor: listeningSocket, queue: .global())
        source?.setEventHandler { [weak self] in Task { @MainActor in self?.acceptConnection() } }
        source?.resume()
    }

    func acceptConnection() {
        let fd = accept(listeningSocket, nil, nil)
        guard fd >= 0 else { return }
        log("Terminal client connected.")
        activeClients[fd] = Data()
        sendToClient(fd, "SafeGuardian\n")
        sendToClient(fd, "Type a message to send to the mesh. /exit to quit.\n")
        sendToClient(fd, "---\n")
        setupSubscriptions(for: fd, connectionTime: Date())
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        src.setEventHandler { [weak self] in
            Task { @MainActor in
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = read(fd, &buf, buf.count)
                if n <= 0 { self?.closeClient(fd, source: src) }
                else { self?.processClientData(fd, data: Data(buf[0..<n])) }
            }
        }
        src.resume()
    }

    func closeClient(_ fd: Int32, source: DispatchSourceRead) {
        source.cancel(); close(fd)
        activeClients.removeValue(forKey: fd)
        clientCancellables.removeValue(forKey: fd)
    }

    func processClientData(_ fd: Int32, data: Data) {
        guard var buf = activeClients[fd] else { return }
        buf.append(data)
        while let nl = buf.firstIndex(of: 10) {
            if let line = String(data: buf[..<nl], encoding: .utf8) { handleInput(line, clientFD: fd) }
            buf.removeSubrange(..<buf.index(after: nl))
        }
        activeClients[fd] = buf
    }

    private func handleInput(_ input: String, clientFD: Int32) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/exit", trimmed != "/quit" else { return }
        chatViewModel?.sendMessage(trimmed)
    }

    func sendToClient(_ fd: Int32, _ text: String) {
        let data = Data(text.utf8)
        ioQueue.async {
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        }
    }

    func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        print("[IPC] \(message)")
        let url = appSupportDir.appendingPathComponent("tui.log")
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: url.path) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else { try? data.write(to: url) }
        }
    }
}
#endif
