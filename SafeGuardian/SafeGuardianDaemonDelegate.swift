#if os(macOS)
import AppKit
import BitFoundation
import UserNotifications

/// NSApplicationDelegate for --daemon mode.
/// Starts the full networking stack and IPC host without creating any windows.
@MainActor
final class SafeGuardianDaemonDelegate: NSObject, NSApplicationDelegate {
    private var chatViewModel: ChatViewModel?
    private let idBridge = NostrIdentityBridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let keychain = KeychainManager()
        let cvm = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: SecureIdentityStateManager(keychain)
        )
        chatViewModel = cvm

        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        NotificationDelegate.shared.chatViewModel = cvm
        GeoRelayDirectory.shared.prefetchIfNeeded()

        VerificationService.shared.configure(with: cvm.meshService.getNoiseService())

        NetworkActivationService.shared.start()
        GeohashPresenceService.shared.start()

        SafeGuardianIPCHost.shared.start(chatViewModel: cvm)
        SafeGuardianIPCHost.shared.log("Daemon ready — IPC host listening.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        chatViewModel?.applicationWillTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
#endif
