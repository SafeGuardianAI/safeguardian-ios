import SafeGuardianMesh
import SwiftUI

// Deployment provisioning: the tenant this device reports under and the APEX
// LAN gateway it mirrors envelopes to. Both persist in UserDefaults and take
// effect immediately; an empty tenant emits the zero hash (unprovisioned).
struct DeploymentSettingsSection: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var tenantDraft = TenantIdentity.tenantID
    @State private var gatewayDraft = LANGatewayTransport.Config.fromUserDefaults()?.host ?? ""

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var secondaryTextColor: Color {
        textColor.opacity(0.8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("deployment")

            row(icon: "building.2",
                label: "tenant id",
                caption: "deployment this device reports under") {
                TextField("unprovisioned", text: $tenantDraft)
                    .font(.safeguardianSystem(size: 13, design: .monospaced))
                    .foregroundColor(textColor)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onSubmit { TenantIdentity.setTenantID(tenantDraft) }
            }

            row(icon: "server.rack",
                label: "apex gateway host",
                caption: "lan address of the ops gateway; blank disables") {
                TextField("none", text: $gatewayDraft)
                    .font(.safeguardianSystem(size: 13, design: .monospaced))
                    .foregroundColor(textColor)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onSubmit {
                        let host = gatewayDraft.trimmingCharacters(in: .whitespaces)
                        LANGatewayTransport.Config.save(host: host)
                        viewModel.sgClient?.reloadGatewayFromDefaults()
                    }
            }
        }
    }

    private func row(icon: String, label: String, caption: String,
                     @ViewBuilder field: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.safeguardianSystem(size: 20))
                .foregroundColor(textColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.safeguardianSystem(size: 11, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                field()
                Text(caption)
                    .font(.safeguardianSystem(size: 11, design: .monospaced))
                    .foregroundColor(secondaryTextColor.opacity(0.7))
            }
            Spacer()
        }
    }
}
