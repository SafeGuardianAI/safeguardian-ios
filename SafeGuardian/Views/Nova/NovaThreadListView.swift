import BitFoundation
import SafeGuardianMesh
import SwiftUI

/// Thread management for an agent conversation — new/switch/rename/delete.
/// Ports the functionality that used to live only in ContentView's sidebar
/// agent section into the dedicated Nova tab, which had no thread UI at all.
struct NovaThreadListView: View {
    @Environment(\.dismiss) private var dismiss
    let agentID: String
    let onSelect: (PeerID) -> Void

    @State private var threadStore = AgentThreadStore.shared
    @State private var renamingThreadID: String?
    @State private var renameDraft = ""

    private var threads: [AgentThreadStore.Thread] {
        threadStore.threads(for: agentID)
    }

    private var activeThreadID: String? {
        threadStore.activeThread(for: agentID)?.id
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(threads) { thread in
                    threadRow(thread)
                }
            }
            .navigationTitle("Conversations")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let t = threadStore.newThread(for: agentID)
                        onSelect(t.peerID)
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func threadRow(_ thread: AgentThreadStore.Thread) -> some View {
        if renamingThreadID == thread.id {
            HStack {
                TextField("Title", text: $renameDraft, onCommit: commitRename)
                Button("Save", action: commitRename)
                    .buttonStyle(.borderless)
            }
        } else {
            Button {
                threadStore.switchToThread(thread.id, agentID: agentID)
                onSelect(thread.peerID)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: thread.id == activeThreadID ? "bubble.left.fill" : "bubble.left")
                        .foregroundColor(thread.id == activeThreadID ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(thread.title)
                            .foregroundColor(.primary)
                        Text(thread.createdAt, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                if threads.count > 1 {
                    Button(role: .destructive) {
                        threadStore.deleteThread(thread.id, agentID: agentID)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Button {
                    renamingThreadID = thread.id
                    renameDraft = thread.title
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
    }

    private func commitRename() {
        guard let id = renamingThreadID else { return }
        threadStore.updateTitle(renameDraft, threadID: id, agentID: agentID)
        renamingThreadID = nil
    }
}
