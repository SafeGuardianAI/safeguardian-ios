import Foundation
import SwiftUI
import BitFoundation

func runHeadlessTUI() {
    print("========================================")
    print("️ SafeGuardian Terminal Interface v1.0")
    print("========================================")
    print("[*] Booting native macOS infrastructure...")
    
    // Initialize on Main thread so @MainActor properties are safe
    DispatchQueue.main.async {
        let keychain = KeychainManager()
        let idBridge = NostrIdentityBridge()
        let chatViewModel = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: SecureIdentityStateManager(keychain)
        )
        
        print("[*] Core initialized. Identity: \(chatViewModel.nickname)")
        print("[*] Starting daemons (Tor, BLE, Presence)...")
        
        // Start the network daemons
        NetworkActivationService.shared.start()
        GeohashPresenceService.shared.start()
        
        print("[*] Ready. Type your message or command (e.g. /help, @nova hi).")
        print("    Type /exit to quit.")
        print("----------------------------------------")
        
        // Start background input loop so we don't block the main RunLoop
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                
                if trimmed == "/quit" || trimmed == "/exit" {
                    print("[*] Shutting down SafeGuardian TUI...")
                    exit(0)
                }
                
                print("\n[Input Registered]  \(trimmed)")
                print("----------------------------------------")
            }
        }
    }
    
    // Keep the main runloop alive to service Combine, Tor, BLE, and async tasks
    RunLoop.main.run()
}
