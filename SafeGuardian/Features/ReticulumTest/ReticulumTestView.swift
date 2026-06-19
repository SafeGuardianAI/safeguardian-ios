import SwiftUI

#if os(iOS)
import FieldMesh

@MainActor
final class ReticulumTestViewModel: ObservableObject {
    @Published var log: [String] = []
    @Published var nodeStatus: String = "stopped"
    @Published var destinationHex: String = ""
    @Published var messageBody: String = "hello from SafeGuardian"
    @Published var isStarted = false

    func start() {
        Task {
            do {
                let handler: @Sendable (NodeEvent) -> Void = { [weak self] event in
                    Task { @MainActor [weak self] in self?.handleEvent(event) }
                }
                await ReticulumService.shared.setEventHandler(handler)
                try await ReticulumService.shared.start(displayName: UIDevice.current.name)
                isStarted = true
                if let s = await ReticulumService.shared.status() {
                    append("identity \(s.identityHex.prefix(16))...")
                    append("lxmf    \(s.lxmfDestinationHex.prefix(16))...")
                }
            } catch {
                append("start: \(error)")
            }
        }
    }

    func send() {
        guard !destinationHex.isEmpty else { append("need destination hex"); return }
        Task {
            do {
                let id = try await ReticulumService.shared.sendMessage(
                    to: destinationHex, body: messageBody
                )
                append("queued \(id.prefix(12))...")
            } catch {
                append("send: \(error)")
            }
        }
    }

    func announce() {
        Task {
            do {
                try await ReticulumService.shared.announceNow()
                append("announced")
            } catch {
                append("announce: \(error)")
            }
        }
    }

    func stop() {
        Task {
            do {
                try await ReticulumService.shared.stop()
                isStarted = false
                nodeStatus = "stopped"
                append("stopped")
            } catch {
                append("stop: \(error)")
            }
        }
    }

    private func handleEvent(_ event: NodeEvent) {
        switch event {
        case .statusChanged(let s):
            nodeStatus = s.running ? "running" : "stopped"
            append("status: \(nodeStatus)")
        case .messageReceived(let m):
            append("rx \(m.sourceHex?.prefix(8) ?? "??"): \(m.bodyUtf8.prefix(60))")
        case .announceReceived(let dest, _, _, _, _, let name, let hops, _, _):
            append("peer \(name ?? String(dest.prefix(8))) hops=\(hops)")
        case .lxmfDelivery(let u):
            append("delivery \(u.messageIdHex.prefix(8)) \(u.status)")
        case .operationalNotice(let n):
            if case .warn = n.level { append("[warn] \(n.message)") }
            if case .error = n.level { append("[error] \(n.message)") }
        default:
            break
        }
    }

    private func append(_ text: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.insert("[\(ts)] \(text)", at: 0)
        if log.count > 100 { log.removeLast() }
    }
}

struct ReticulumTestView: View {
    @StateObject private var vm = ReticulumTestViewModel()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Transport") {
                    HStack {
                        Circle()
                            .fill(vm.isStarted ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(vm.nodeStatus)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if vm.isStarted {
                            Button("Stop", role: .destructive) { vm.stop() }
                        } else {
                            Button("Start") { vm.start() }
                        }
                    }
                    if vm.isStarted {
                        Button("Announce now") { vm.announce() }
                    }
                }

                Section("Send LXMF") {
                    TextField("Destination hex (64 chars)", text: $vm.destinationHex)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Body", text: $vm.messageBody)
                    Button("Send") { vm.send() }
                        .disabled(!vm.isStarted || vm.destinationHex.isEmpty)
                }
            }
            .frame(maxHeight: 320)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.log, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .navigationTitle("Reticulum")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
