#if os(macOS)
import Foundation
import Combine
import Tor
import BitFoundation

@MainActor
final class SafeGuardianIPCHost {
    static let shared = SafeGuardianIPCHost()
    private var socketPath: String {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("chat.safeguardian", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("tui.sock").path
    }
    
    private var logPath: String {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("chat.safeguardian", isDirectory: true)
        return appSupport.appendingPathComponent("tui.log").path
    }

    public func log(_ message: String) {
        let timestamp = Date().description
        let logLine = "[\(timestamp)] \(message)\n"
        print("[IPC] \(message)")
        if let data = logLine.data(using: .utf8) {
            let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            let appSupport = paths[0].appendingPathComponent("chat.safeguardian", isDirectory: true)
            let logPath = appSupport.appendingPathComponent("tui.log").path
            
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: data)
            } else if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }

    private var source: DispatchSourceRead?
    private var listeningSocket: Int32 = -1
    private var activeClients: [Int32: Data] = [:]
    private var clientCancellables: [Int32: Set<AnyCancellable>] = [:]

    private var chatViewModel: ChatViewModel?
    
    private init() {}
    
    func start(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        log("Starting IPC Host...")
        
        let path = socketPath
        unlink(path)
        
        listeningSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listeningSocket >= 0 else {
            log("Failed to create socket")
            return
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        // Safer path copying to avoid memory corruption
        let pathData = path.data(using: .utf8)!
        pathData.withUnsafeBytes { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPtr in
                let dest = UnsafeMutableRawPointer(sunPtr).assumingMemoryBound(to: UInt8.self)
                let count = min(pathData.count, 103) // sun_path size is 104, leave room for null
                dest.update(from: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count)
                dest[count] = 0 // Null terminate
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        
        var bindAddr = addr
        let bindResult = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listeningSocket, sockPtr, socklen_t(addr.sun_len))
            }
        }
        
        guard bindResult >= 0 else {
            let error = String(cString: strerror(errno))
            log("Failed to bind socket to \(path): \(error) (errno: \(errno))")
            return
        }
        
        guard listen(listeningSocket, 5) >= 0 else {
            log("Failed to listen")
            return
        }
        
        log("Listening on \(path)")
        
        source = DispatchSource.makeReadSource(fileDescriptor: listeningSocket, queue: DispatchQueue.global())
        source?.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.acceptConnection()
            }
        }
        source?.resume()
    }
    
    private func acceptConnection() {
        let clientSocket = accept(listeningSocket, nil, nil)
        guard clientSocket >= 0 else { return }
        
        let connectionTime = Date()
        log("New terminal client connected.")
        activeClients[clientSocket] = Data()
        
        sendToClient(clientSocket, "========================================\n")
        sendToClient(clientSocket, " SafeGuardian Terminal Interface v1.0\n")
        sendToClient(clientSocket, "========================================\n")
        sendToClient(clientSocket, "[*] Connected to running application.\n")
        sendToClient(clientSocket, "[*] Ready. Type your message or command (e.g. /help, @nova hi).\n")
        sendToClient(clientSocket, "    Type /exit to quit.\n")
        sendToClient(clientSocket, "----------------------------------------\n")
        
        setupSubscriptions(for: clientSocket, connectionTime: connectionTime)
        
        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientSocket, queue: DispatchQueue.global())
        clientSource.setEventHandler { [weak self] in
            Task { @MainActor in
                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = read(clientSocket, &buffer, buffer.count)
                if bytesRead <= 0 {
                    self?.closeClient(clientSocket, source: clientSource)
                } else {
                    self?.processClientData(clientSocket, data: Data(buffer[0..<bytesRead]))
                }
            }
        }
        clientSource.resume()
    }
    
    private func processClientData(_ socket: Int32, data: Data) {
        guard var buffer = activeClients[socket] else { return }
        buffer.append(data)
        
        // Scan for newlines
        while let newlineIndex = buffer.firstIndex(of: 10) { // '\n'
            let lineData = buffer[..<newlineIndex]
            if let line = String(data: lineData, encoding: .utf8) {
                handleInput(line)
            }
            buffer.removeSubrange(..<buffer.index(after: newlineIndex))
        }
        
        activeClients[socket] = buffer
    }
    
    private func closeClient(_ clientSocket: Int32, source: DispatchSourceRead) {
        source.cancel()
        close(clientSocket)
        activeClients.removeValue(forKey: clientSocket)
        clientCancellables.removeValue(forKey: clientSocket)
    }
    
    private func handleInput(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == "/quit" || trimmed == "/exit" {
            // Let the client disconnect itself
            return
        }
        
        log("Processing Input: \(trimmed.prefix(50))...")
        
        // Pass to main app
        Task { @MainActor in
            chatViewModel?.sendMessage(trimmed)
        }
    }
    
    private func broadcast(_ message: String) {
        log("Broadcasting: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        for client in activeClients.keys {
            sendToClient(client, message)
        }
    }
    
    private func sendToClient(_ socket: Int32, _ message: String) {
        let data = Data(message.utf8)
        data.withUnsafeBytes { ptr in
            write(socket, ptr.baseAddress, data.count)
        }
    }
    
    private func setupSubscriptions(for socket: Int32, connectionTime: Date) {
        guard let chatViewModel = chatViewModel else { return }
        clientCancellables[socket] = Set<AnyCancellable>()

        Task { @MainActor in
            var knownMessageIDs = Set<String>()
            var lastRenderedContent: [String: String] = [:]
            var isFirstTrigger = true

            TorManager.shared.$isReady
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isReady in
                    let status = isReady ? "Ready" : "Bootstrapping / Offline"
                    self?.sendToClient(socket, "\n[Tor Status]: \(status)\n")
                }
                .store(in: &clientCancellables[socket, default: Set<AnyCancellable>()])
                
            LocationChannelManager.shared.$availableChannels
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] channels in
                    let names = channels.map { $0.geohash }.joined(separator: ", ")
                    self?.sendToClient(socket, "\n[Location Channels Updated]: \(names)\n")
                }
                .store(in: &clientCancellables[socket, default: Set<AnyCancellable>()])

            chatViewModel.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        // Ensure client is still connected
                        guard self?.activeClients[socket] != nil else { return }

                        if isFirstTrigger {
                            isFirstTrigger = false
                            for msg in chatViewModel.messages {
                                knownMessageIDs.insert(msg.id)
                                // Standardize trimming for history too
                                lastRenderedContent[msg.id] = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            self?.log("TUI Warm Start complete. \(knownMessageIDs.count) history messages indexed.")
                            return
                        }

                        guard let msg = chatViewModel.messages.last else { return }
                        
                        guard msg.timestamp >= connectionTime else { return }

                        let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !content.isEmpty else { return }

                        if !knownMessageIDs.contains(msg.id) {
                            knownMessageIDs.insert(msg.id)
                            lastRenderedContent[msg.id] = content
                            self?.sendToClient(socket, "\n[\(msg.sender)] \(content)\n")
                        } else if let lastContent = lastRenderedContent[msg.id], lastContent != content {
                            lastRenderedContent[msg.id] = content
                            if content.hasPrefix("[") && content.hasSuffix("]") {
                                self?.sendToClient(socket, "\r[\(msg.sender)] \(content)")
                            } else if lastContent.hasPrefix("[") && lastContent.hasSuffix("]") {
                                self?.sendToClient(socket, "\n[\(msg.sender)] \(content)")
                            } else if content.hasPrefix(lastContent) {
                                self?.sendToClient(socket, String(content.dropFirst(lastContent.count)))
                            } else {
                                self?.sendToClient(socket, "\r[\(msg.sender)] \(content)")
                            }
                        }
                    }
                }
                .store(in: &clientCancellables[socket, default: Set<AnyCancellable>()])
        }
    }
}
#endif
