// NovaModelPickerView.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import SwiftUI

/// Surfaces MLXInferenceService's model list — previously wired
/// (savedModelIDs/addModel/removeModel/selectModel) but never shown in any
/// view. Lets the user switch the active on-device model and add or remove
/// entries from the saved list.
struct NovaModelPickerView: View {
    @State private var mlx = MLXInferenceService.shared
    @State private var newModelID = ""
    @Environment(\.colorScheme) var colorScheme

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.safeguardianSystem(size: 20))
                .foregroundColor(textColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                Text("saved models")
                    .font(.safeguardianSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)

                ForEach(mlx.savedModelIDs, id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(systemName: id == mlx.activeModelID ? "checkmark.circle.fill" : "circle")
                            .font(.safeguardianSystem(size: 13))
                            .foregroundColor(id == mlx.activeModelID ? textColor : secondaryTextColor)

                        Text(id)
                            .font(.safeguardianSystem(size: 12, design: .monospaced))
                            .foregroundColor(id == mlx.activeModelID ? textColor : secondaryTextColor)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        if id != MLXInferenceService.defaultModelID {
                            Button {
                                mlx.removeModel(id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.safeguardianSystem(size: 12))
                                    .foregroundColor(secondaryTextColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { mlx.selectModel(id) }
                }

                HStack(spacing: 8) {
                    TextField("huggingface repo id (mlx-community/...)", text: $newModelID)
                        .font(.safeguardianSystem(size: 12, design: .monospaced))
                        .foregroundColor(textColor)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        #endif

                    Button("add") {
                        mlx.addModel(newModelID)
                        newModelID = ""
                    }
                    .font(.safeguardianSystem(size: 12, design: .monospaced))
                    .foregroundColor(textColor)
                    .disabled(newModelID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 2)
            }
            Spacer()
        }
    }
}
