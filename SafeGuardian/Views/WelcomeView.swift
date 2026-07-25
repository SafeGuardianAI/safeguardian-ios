import SwiftUI

/// First-run screen shown once, before any other first-run sheet, so the user
/// has context for the Bluetooth and notification prompts instead of meeting
/// them cold on launch.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
                .padding(.top, 32)

            Text("Welcome to SafeGuardian")
                .font(.title2.weight(.semibold))

            Text("SafeGuardian meshes directly with nearby devices over Bluetooth, so you can stay in contact even without internet or cell service.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 16) {
                permissionRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Bluetooth",
                    description: "Builds the mesh with nearby SafeGuardian users. You may already have seen the system prompt for this."
                )
                permissionRow(
                    icon: "bell.badge",
                    title: "Notifications",
                    description: "Alerts you to new messages and when nearby peers join the mesh."
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Spacer()

            Button(action: { dismiss() }) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }

    private func permissionRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.blue)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    WelcomeView()
}
