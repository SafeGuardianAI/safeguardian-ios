import AgentInfra
import BitFoundation
import SafeGuardianMesh
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// First-class Nova conversation surface. Routes directly to AgentConversationEngine
/// without touching selectedPrivateChatPeer, keeping the mesh tab undisturbed.
struct NovaConversationView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var engine = AgentConversationEngine.shared
    @State private var messageText = ""
    @State private var mlx = MLXInferenceService.shared
    @State private var threadStore = AgentThreadStore.shared
    @State private var showThreadList = false
    @FocusState private var inputFocused: Bool
    #if os(iOS)
    @State private var showImagePicker = false
    @State private var pendingImage: UIImage? = nil
    #else
    @State private var showMacImagePicker = false
    @State private var pendingImage: NSImage? = nil
    #endif

    private var novaPeerID: PeerID {
        threadStore.activePeerID(for: "nova")
    }

    private var messages: [SafeGuardianMessage] {
        viewModel.privateChats[novaPeerID] ?? []
    }

    private var threadSubtitle: String? {
        let threads = threadStore.threads(for: "nova")
        guard threads.count > 1, let active = threadStore.activeThread(for: "nova"),
              active.title.caseInsensitiveCompare("Nova") != .orderedSame else { return nil }
        return active.title
    }

    var body: some View {
        VStack(spacing: 0) {
            novaHeader
            Divider()
            messageScroll
            if mlx.isLoading || mlx.downloadProgress > 0 && mlx.downloadProgress < 1 {
                modelBanner
            }
#if os(iOS)
            AgentInputBar(
                text: $messageText,
                focused: $inputFocused,
                onSend: sendToNova,
                pendingImage: $pendingImage,
                onAttachTapped: { showImagePicker = true }
            )
#else
            AgentInputBar(
                text: $messageText,
                focused: $inputFocused,
                onSend: sendToNova,
                pendingImage: $pendingImage,
                onAttachTapped: { showMacImagePicker = true }
            )
#endif
        }
#if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { inputFocused = false }
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView(sourceType: .photoLibrary) { image in
                showImagePicker = false
                pendingImage = image
            }
            .ignoresSafeArea()
        }
#else
        .sheet(isPresented: $showMacImagePicker) {
            MacImagePickerView { url in
                showMacImagePicker = false
                pendingImage = url.flatMap(NSImage.init)
            }
        }
#endif
        .sheet(isPresented: $showThreadList) {
            NovaThreadListView(agentID: "nova") { _ in }
        }
    }

    private var novaHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.blue)
                Text("Nova")
                    .font(.headline)
                if let threadSubtitle {
                    Text("· \(threadSubtitle)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showThreadList = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            meshStatusLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
    }

    private func dismissKeyboard() {
        inputFocused = false
#if os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
#endif
    }

    private var meshStatusLine: some View {
        let connectedPeers = viewModel.unifiedPeerService.peers.filter { $0.isConnected || $0.isReachable }
        let trekAgents  = MeshAgentRegistry.shared.agents(type: "trek")
        let apexAgents  = MeshAgentRegistry.shared.agents(type: "apex")
        let hashPrefix: String
        if let h = MeshAgentRegistry.shared.localDestinationHash {
            hashPrefix = String(h.prefix(8))
        } else {
            hashPrefix = "----"
        }

        let agentLabels: [String] = (trekAgents.isEmpty ? [] : ["trek"])
            + (apexAgents.isEmpty ? [] : ["apex"])

        return HStack(spacing: 8) {
            Text(hashPrefix)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
            if connectedPeers.isEmpty {
                Text("no mesh peers")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
            } else {
                Text("\(connectedPeers.count) peer\(connectedPeers.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                ForEach(agentLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(3)
                        .foregroundColor(.blue)
                }
            }
            Spacer()
        }
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages, id: \.id) { msg in
                            NovaBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(.blue.opacity(0.35))
            if !mlx.isModelLoaded && !mlx.isLoading {
                Text("Model weights load on first use.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 32)
    }

    private var modelShortName: String {
        mlx.activeModelID.split(separator: "/").last.map(String.init) ?? mlx.activeModelID
    }

    private var modelBanner: some View {
        let isDownloading = mlx.downloadProgress > 0 && mlx.downloadProgress < 1
        return HStack(spacing: 8) {
            if isDownloading {
                ProgressView(value: mlx.downloadProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 100)
                Text("Downloading \(modelShortName) \(Int(mlx.downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ProgressView().scaleEffect(0.7)
                Text("Loading \(modelShortName)...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06))
    }

    private func sendToNova() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        let capturedImage = pendingImage
        pendingImage = nil
        let imageData = capturedImage.flatMap { image -> Data? in
            guard let processedURL = try? ImageUtils.processImage(image) else { return nil }
            return try? Data(contentsOf: processedURL)
        }
        guard !text.isEmpty || imageData != nil else { return }
        messageText = ""
        dismissKeyboard()
        let peerID = novaPeerID
        let displayContent = text.isEmpty ? "[image]" : text
        let userMsg = SafeGuardianMessage(
            sender: viewModel.nickname,
            content: displayContent,
            timestamp: Date(),
            isRelay: false
        )
        if viewModel.privateChats[peerID] == nil { viewModel.privateChats[peerID] = [] }
        viewModel.privateChats[peerID]?.append(userMsg)
        if let t = AgentThreadStore.shared.activeThread(for: "nova"), t.title == "New conversation" {
            AgentThreadStore.shared.updateTitle(displayContent, threadID: t.id, agentID: "nova")
        }
        Agent.nova.handle(prompt: text, image: imageData, context: viewModel, threadPeerID: peerID)
    }
}

