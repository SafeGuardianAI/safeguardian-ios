import SafeGuardianMesh
//
// ChatViewModel+Lifecycle.swift
// SafeGuardian
//
// App scene-phase, shared-content, and deep-link handling for ChatViewModel.
// SafeGuardianApp.swift delegates here so both platforms drive the same
// activation path instead of each host duplicating the logic.
//

import Foundation
import Tor
import WhisperInfra

extension ChatViewModel {

    // MARK: - Deep links & extension hand-off

    func handleOpenURL(_ url: URL) {
        if url.scheme == "safeguardian" && url.host == "share" {
            checkForSharedContent()
        }
    }

    /// Picks up text/URL content queued by the share extension into the app
    /// group's UserDefaults, if it was queued within the accept window.
    func checkForSharedContent() {
        guard let userDefaults = UserDefaults(suiteName: SafeGuardianApp.groupID) else { return }

        guard let sharedContent = userDefaults.string(forKey: "sharedContent"),
              let sharedDate = userDefaults.object(forKey: "sharedContentDate") as? Date else {
            return
        }

        guard Date().timeIntervalSince(sharedDate) < TransportConfig.uiShareAcceptWindowSeconds else { return }

        let contentType = userDefaults.string(forKey: "sharedContentType") ?? "text"
        userDefaults.removeObject(forKey: "sharedContent")
        userDefaults.removeObject(forKey: "sharedContentType")
        userDefaults.removeObject(forKey: "sharedContentDate")

        DispatchQueue.main.async {
            if contentType == "url",
               let data = sharedContent.data(using: .utf8),
               let urlData = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let url = urlData["url"] {
                self.sendMessage(url)
            } else {
                self.sendMessage(sharedContent)
            }
        }
    }

    // MARK: - Scene phase (iOS only — macOS has no background/foreground cycle)

#if os(iOS)
    func handleScenePhaseBackground() {
        // Keep BLE mesh running in background; BLEService adapts scanning automatically.
        // Always send Tor to dormant on background for a clean restart later.
        TorManager.shared.setAppForeground(false)
        TorManager.shared.goDormantOnBackground()
        // Unload Whisper model to free RAM.
        SpeechInferenceCoordinator.shared.unload()
        endGeohashSampling()
        // Proactively disconnect Nostr to avoid spurious socket errors while Tor is down.
        NostrRelayManager.shared.disconnect()
        didEnterBackground = true
    }

    func handleScenePhaseActive() {
        meshService.startServices()
        TorManager.shared.setAppForeground(true)
        // Reload Whisper model for voice input readiness.
        Task.detached(priority: .utility) {
            try? await SpeechInferenceCoordinator.shared.load()
        }
        // On initial cold launch, Tor was just started in onAppear.
        // Skip the deterministic restart the first time we become active.
        let shouldRefreshNostrConnections = didHandleInitialActive && didEnterBackground
        if shouldRefreshNostrConnections {
            if TorManager.shared.isAutoStartAllowed() && !TorManager.shared.isReady {
                TorManager.shared.ensureRunningOnForeground()
            }
        } else {
            didHandleInitialActive = true
        }
        didEnterBackground = false

        if shouldRefreshNostrConnections && TorManager.shared.isAutoStartAllowed() {
            Task.detached {
                let _ = await TorManager.shared.awaitReady(timeout: 60)
                await MainActor.run {
                    // Rebuild proxied sessions to bind to the live Tor after readiness.
                    TorURLSession.shared.rebuild()
                    NostrRelayManager.shared.resetAllConnections()
                }
            }
        }
        checkForSharedContent()
    }
#endif
}
