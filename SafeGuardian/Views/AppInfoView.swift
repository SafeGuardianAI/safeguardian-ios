import SwiftUI

struct AppInfoView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var novaResetConfirm = false
    @State private var mlxService = MLXInferenceService.shared
    @State private var newModelID = ""
    @State private var showAddModelAlert = false
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    // MARK: - Constants
    private enum Strings {
        static let appName: LocalizedStringKey = "app_info.app_name"
        static let tagline: LocalizedStringKey = "app_info.tagline"

        enum Features {
            static let title: LocalizedStringKey = "app_info.features.title"
            static let offlineComm = AppInfoFeatureInfo(
                icon: "wifi.slash",
                title: "app_info.features.offline.title",
                description: "app_info.features.offline.description"
            )
            static let encryption = AppInfoFeatureInfo(
                icon: "lock.shield",
                title: "app_info.features.encryption.title",
                description: "app_info.features.encryption.description"
            )
            static let extendedRange = AppInfoFeatureInfo(
                icon: "antenna.radiowaves.left.and.right",
                title: "app_info.features.extended_range.title",
                description: "app_info.features.extended_range.description"
            )
            static let mentions = AppInfoFeatureInfo(
                icon: "at",
                title: "app_info.features.mentions.title",
                description: "app_info.features.mentions.description"
            )
            static let favorites = AppInfoFeatureInfo(
                icon: "star.fill",
                title: "app_info.features.favorites.title",
                description: "app_info.features.favorites.description"
            )
            static let geohash = AppInfoFeatureInfo(
                icon: "number",
                title: "app_info.features.geohash.title",
                description: "app_info.features.geohash.description"
            )
        }

        enum Privacy {
            static let title: LocalizedStringKey = "app_info.privacy.title"
            static let noTracking = AppInfoFeatureInfo(
                icon: "eye.slash",
                title: "app_info.privacy.no_tracking.title",
                description: "app_info.privacy.no_tracking.description"
            )
            static let ephemeral = AppInfoFeatureInfo(
                icon: "shuffle",
                title: "app_info.privacy.ephemeral.title",
                description: "app_info.privacy.ephemeral.description"
            )
            static let panic = AppInfoFeatureInfo(
                icon: "hand.raised.fill",
                title: "app_info.privacy.panic.title",
                description: "app_info.privacy.panic.description"
            )
        }

        enum HowToUse {
            static let title: LocalizedStringKey = "app_info.how_to_use.title"
            static let instructions: [LocalizedStringKey] = [
                "app_info.how_to_use.set_nickname",
                "app_info.how_to_use.change_channels",
                "app_info.how_to_use.open_sidebar",
                "app_info.how_to_use.start_dm",
                "app_info.how_to_use.clear_chat",
                "app_info.how_to_use.commands"
            ]
        }

    }
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Spacer()
                Button("app_info.done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(textColor)
                .padding()
            }
            .background(backgroundColor.opacity(0.95))
            
            ScrollView {
                infoContent
            }
            .background(backgroundColor)
        }
        .frame(width: 600, height: 700)
        #else
        NavigationView {
            ScrollView {
                infoContent
            }
            .background(backgroundColor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.safeguardianSystem(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(textColor)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("app_info.close")
                }
            }
        }
        #endif
    }
    
    @ViewBuilder
    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .center, spacing: 8) {
                Text(Strings.appName)
                    .font(.safeguardianSystem(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Text(Strings.tagline)
                    .font(.safeguardianSystem(size: 16, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
            
            // How to Use
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.HowToUse.title)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Strings.HowToUse.instructions.enumerated()), id: \.offset) { _, instruction in
                        Text(instruction)
                    }
                }
                .font(.safeguardianSystem(size: 14, design: .monospaced))
                .foregroundColor(textColor)
            }

            // Features
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Features.title)

                FeatureRow(info: Strings.Features.offlineComm)

                FeatureRow(info: Strings.Features.encryption)

                FeatureRow(info: Strings.Features.extendedRange)

                FeatureRow(info: Strings.Features.favorites)

                FeatureRow(info: Strings.Features.geohash)

                FeatureRow(info: Strings.Features.mentions)
            }

            // Privacy
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Privacy.title)

                FeatureRow(info: Strings.Privacy.noTracking)

                FeatureRow(info: Strings.Privacy.ephemeral)

                FeatureRow(info: Strings.Privacy.panic)
            }

            // Nova on-device AI
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("on-device ai")

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.safeguardianSystem(size: 20))
                        .foregroundColor(textColor)
                        .frame(width: 30)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        let activeModelBinding = Binding(
                            get: { mlxService.activeModelID },
                            set: { mlxService.selectModel($0) }
                        )
                        
                        HStack {
                            Picker("active model", selection: activeModelBinding) {
                                ForEach(mlxService.savedModelIDs, id: \.self) { id in
                                    Text(id.components(separatedBy: "/").last ?? id)
                                        .tag(id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .accentColor(textColor)
                            .font(.safeguardianSystem(size: 14, weight: .semibold, design: .monospaced))
                            
                            Spacer()
                            
                            Button(action: { showAddModelAlert = true }) {
                                Image(systemName: "plus.circle")
                                    .foregroundColor(textColor)
                            }
                            .buttonStyle(.plain)
                            
                            if mlxService.activeModelID != MLXInferenceService.defaultModelID {
                                Button(action: { mlxService.removeModel(mlxService.activeModelID) }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        Text("type @nova <message> in the chat composer to query the on-device model. responses are private and never sent to the mesh.")
                            .font(.safeguardianSystem(size: 12, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        if mlxService.isLoading {
                            ProgressView(value: mlxService.downloadProgress)
                                .accentColor(textColor)
                                .padding(.top, 4)
                            Text("downloading model: \(Int(mlxService.downloadProgress * 100))%")
                                .font(.safeguardianSystem(size: 10, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                        }
                    }
                    Spacer()
                }

                Button(action: {
                    novaResetConfirm = true
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("reset nova session")
                    }
                    .font(.safeguardianSystem(size: 13, design: .monospaced))
                    .foregroundColor(textColor)
                    .padding(.leading, 42)
                }
                .buttonStyle(.plain)
                .confirmationDialog("reset nova session?", isPresented: $novaResetConfirm, titleVisibility: .visible) {
                    Button("reset", role: .destructive) {
                        mlxService.dropSession()
                    }
                    Button("cancel", role: .cancel) {}
                } message: {
                    Text("clears the downloaded model and conversation history. nova will re-download on next use.")
                }
            }
        }
        .padding()
        .alert("add huggingface model", isPresented: $showAddModelAlert) {
            TextField("org/model-name", text: $newModelID)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                #endif
            Button("add") {
                mlxService.addModel(newModelID)
                newModelID = ""
            }
            Button("cancel", role: .cancel) {
                newModelID = ""
            }
        } message: {
            Text("enter a raw huggingface repo ID (e.g. mlx-community/Qwen3-0.6B-4bit). make sure it is an mlx-compatible 4-bit model.")
        }
    }
}

struct AppInfoFeatureInfo {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    init(_ title: LocalizedStringKey) {
        self.title = title
    }
    
    var body: some View {
        Text(title)
            .font(.safeguardianSystem(size: 16, weight: .bold, design: .monospaced))
            .foregroundColor(textColor)
            .padding(.top, 8)
    }
}

struct FeatureRow: View {
    let info: AppInfoFeatureInfo
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: info.icon)
                .font(.safeguardianSystem(size: 20))
                .foregroundColor(textColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.safeguardianSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Text(info.description)
                    .font(.safeguardianSystem(size: 12, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
    }
}

#Preview("Default") {
    AppInfoView()
}

#Preview("Dynamic Type XXL") {
    AppInfoView()
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#Preview("Dynamic Type XS") {
    AppInfoView()
        .environment(\.sizeCategory, .extraSmall)
}
