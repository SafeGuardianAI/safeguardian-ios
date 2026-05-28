// Entry point. Handles the --daemon flag before SwiftUI takes over.
// On macOS with --daemon: runs headless (no window, no dock icon).
// All other invocations defer to the normal SwiftUI app lifecycle.

#if os(macOS)
import AppKit

if CommandLine.arguments.contains("--daemon") {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = SafeGuardianDaemonDelegate()
    app.delegate = delegate
    app.run()
} else {
    SafeGuardianApp.main()
}
#else
SafeGuardianApp.main()
#endif
