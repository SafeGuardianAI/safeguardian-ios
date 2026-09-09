// NovaToolTogglesView.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import SwiftUI

/// Per-tool enable/disable toggles for Nova's tool registry, backed by
/// ToolSettingsStore. A disabled tool is filtered out of the spec list in
/// AgentToolRegistry+AllTools.swift.standard(...) before it ever reaches
/// the model — distinct from the approval flow, which asks every time
/// rather than turning a tool off permanently.
struct NovaToolTogglesView: View {
    @State private var toolSettings = ToolSettingsStore.shared
    @State private var expanded = false
    @Environment(\.colorScheme) var colorScheme

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.safeguardianSystem(size: 20))
                    .foregroundColor(textColor)
                    .frame(width: 30)

                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    HStack {
                        Text("tools (\(ToolCatalog.all.count - toolSettings.disabledNames.count)/\(ToolCatalog.all.count) enabled)")
                            .font(.safeguardianSystem(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(textColor)
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.safeguardianSystem(size: 11))
                            .foregroundColor(secondaryTextColor)
                    }
                }
                .buttonStyle(.plain)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ToolCatalog.all, id: \.name) { entry in
                        Toggle(isOn: Binding(
                            get: { toolSettings.isEnabled(entry.name) },
                            set: { toolSettings.setEnabled(entry.name, $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.displayName)
                                    .font(.safeguardianSystem(size: 12, design: .monospaced))
                                    .foregroundColor(textColor)
                                Text(entry.summary)
                                    .font(.safeguardianSystem(size: 10, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }
                        }
                        .tint(textColor)
                    }
                }
                .padding(.leading, 42)
            }
        }
    }
}
