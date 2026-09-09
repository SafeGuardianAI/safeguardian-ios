// ApprovalMessageView.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import SwiftUI

/// Renders one pending/approved/denied tool-call decision inline in the Nova
/// transcript, in place of the sentinel text MessageRowView detects. Buttons call
/// straight into PendingApprovals.shared.resolve, which both updates this
/// card's own state (read live from `entries`, no separate republish step
/// needed) and resumes the tool call's suspended continuation.
struct ApprovalMessageView: View {
    let token: String
    @State private var approvals = PendingApprovals.shared

    private var entry: PendingApprovals.Entry? { approvals.entry(forToken: token) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let summary = entry?.argumentSummary, summary != "(no arguments)" {
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            switch entry?.state ?? .denied {
            case .pending:
                HStack(spacing: 8) {
                    Button {
                        approvals.resolve(token, approved: true)
                    } label: {
                        Label("Allow", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(role: .cancel) {
                        approvals.resolve(token, approved: false)
                    } label: {
                        Label("Deny", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .approved:
                statusLabel("Approved")
            case .denied:
                statusLabel("Denied")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(statusColor.opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        if let promptTitle = entry?.promptTitle { return promptTitle }
        guard let toolName = entry?.toolName else { return "Nova wants to use a tool" }
        let readable = toolName.replacingOccurrences(of: "_", with: " ")
        return "Nova wants to \(readable)"
    }

    private var statusIcon: String {
        switch entry?.state ?? .denied {
        case .pending: "exclamationmark.triangle"
        case .approved: "checkmark.circle"
        case .denied: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch entry?.state ?? .denied {
        case .pending: .orange
        case .approved: .green
        case .denied: .red
        }
    }

    private func statusLabel(_ text: String) -> some View {
        Label(text, systemImage: statusIcon)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(statusColor)
    }
}
