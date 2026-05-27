#if os(macOS)
import Foundation
import Combine
import Tor
import BitFoundation

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

    private func log(_ message: String) {
        let timestamp = Date().description
        let logLine = "[\(timestamp)] \(message)\n"
        print("[IPC] \(message)") // Console
        if let data = logLine.data(using: .utf8) {
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
    private var activeClients: [Int32] = []
    
    private var chatViewModel: ChatViewModel?
    private var cancellables = Set<AnyCancellable>()
    
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
        let pathLen = path.withCString { Int(strlen($0)) }
        _ = path.withCString { strncpy(&addr.sun_path.0, $0, Int(MemoryLayout.size(ofValue: addr.sun_path))) }
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
            self?.acceptConnection()
        }
        source?.resume()
        
        setupSubscriptions()
    }
    
    private func acceptConnection() {
        let clientSocket = accept(listeningSocket, nil, nil)
        guard clientSocket >= 0 else { return }
        
        log("New terminal client connected.")
        activeClients.append(clientSocket)
        sendToClient(clientSocket, "========================================\n")
        sendToClient(clientSocket, " SafeGuardian Terminal Interface v1.0\n")
        sendToClient(clientSocket, "========================================\n")
        sendToClient(clientSocket, "[*] Connected to running application.\n")
        sendToClient(clientSocket, "[*] Ready. Type your message or command (e.g. /help, @nova hi).\n")
        sendToClient(clientSocket, "    Type /exit to quit.\n")
        sendToClient(clientSocket, "----------------------------------------\n")
        
        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientSocket, queue: DispatchQueue.global())
        clientSource.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 1024)
            let bytesRead = read(clientSocket, &buffer, buffer.count)
            if bytesRead <= 0 {
                self?.closeClient(clientSocket, source: clientSource)
            } else {
                let data = Data(buffer[0..<bytesRead])
                if let str = String(data: data, encoding: .utf8) {
                    self?.handleInput(str)
                }
            }
        }
        clientSource.resume()
    }
    
    private func closeClient(_ clientSocket: Int32, source: DispatchSourceRead) {
        source.cancel()
        close(clientSocket)
        activeClients.removeAll { $0 == clientSocket }
    }
    
    private func handleInput(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == "/quit" || trimmed == "/exit" {
            // Let the client disconnect itself
            return
        }
        
        // Pass to main app
        Task { @MainActor in
            chatViewModel?.sendMessage(trimmed)
        }
    }
    
    private func broadcast(_ message: String) {
        log("Broadcasting: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        for client in activeClients {
            sendToClient(client, message)
        }
    }
    
    private func sendToClient(_ socket: Int32, _ message: String) {
        let data = Data(message.utf8)
        data.withUnsafeBytes { ptr in
            write(socket, ptr.baseAddress, data.count)
        }
    }
    
    private func setupSubscriptions() {
        guard let chatViewModel = chatViewModel else { return }
        
        Task { @MainActor in
            TorManager.shared.$isReady
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isReady in
                    let status = isReady ? "Ready" : "Bootstrapping / Offline"
                    self?.broadcast("\n[Tor Status]: \(status)\n")
                }
                .store(in: &cancellables)
                
            LocationChannelManager.shared.$availableChannels
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] channels in
                    let names = channels.map { $0.geohash }.joined(separator: ", ")
                    self?.broadcast("\n[Location Channels Updated]: \(names)\n")
                }
                .store(in: &cancellables)

            var knownMessageIDs = Set<String>()
            var lastRenderedContent: [String: String] = [:]

            chatViewModel.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        for msg in chatViewModel.messages {
                            if !knownMessageIDs.contains(msg.id) {
                                knownMessageIDs.insert(msg.id)
                                lastRenderedContent[msg.id] = msg.content
                                self?.broadcast("\n[\(msg.sender)] \(msg.content)\n")
                            } else if let lastContent = lastRenderedContent[msg.id], lastContent != msg.content {
                                lastRenderedContent[msg.id] = msg.content
                                // Use carriage return to overwrite line for streaming (requires smart terminal)
                                self?.broadcast("\r[\(msg.sender)] \(msg.content)")
                                if !msg.content.hasPrefix("[") && !msg.content.hasSuffix("]") {
                                    self?.broadcast("\n")
                                }
                            }
                        }
                    }
                }
                .store(in: &cancellables)
        }
    }
}
#endif
