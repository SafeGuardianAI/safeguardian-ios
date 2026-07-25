import SafeGuardianMesh
import SwiftUI

/// Invisible host attached to ContentView's background. Observes the location
/// share grant store and presents the consent sheet whenever a peer's offer
/// arrives. The sheet forces an explicit Accept or Decline, mirroring the
/// system Share My Location consent pattern.
struct LocationShareConsentHost: View {
    let service: LocationShareService?

    var body: some View {
        if let service {
            LocationShareConsentPresenter(service: service, store: service.store)
        }
    }
}

private struct LocationShareConsentPresenter: View {
    let service: LocationShareService
    @ObservedObject var store: LocationShareStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { !store.pendingRequests.isEmpty },
                set: { _ in }
            )) {
                if let hex = store.pendingRequests.first {
                    LocationShareConsentSheet(service: service, requesterHex: hex)
                        .interactiveDismissDisabled()
                }
            }
    }
}

private struct LocationShareConsentSheet: View {
    let service: LocationShareService
    let requesterHex: String
    @Environment(\.dismiss) private var dismiss

    private var requesterName: String {
        service.nicknameFor?(requesterHex) ?? String(requesterHex.prefix(8))
    }

    // Destination hash rendered in 4-char groups for manual verification
    // against the peer's own device.
    private var fingerprint: String {
        stride(from: 0, to: requesterHex.count, by: 4).map { offset in
            let start = requesterHex.index(requesterHex.startIndex, offsetBy: offset)
            let end = requesterHex.index(start, offsetBy: 4, limitedBy: requesterHex.endIndex) ?? requesterHex.endIndex
            return String(requesterHex[start..<end])
        }.joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.circle")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .padding(.top, 28)
            Text("\(requesterName) wants to share their location with you")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("You will see their position as it changes. They will not see yours unless you share back. You can stop at any time with /unshareloc.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text(fingerprint)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                service.acceptShare(from: requesterHex)
                dismiss()
            } label: {
                Text("Accept")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button {
                service.declineShare(from: requesterHex)
                dismiss()
            } label: {
                Text("Decline")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.medium])
    }
}
