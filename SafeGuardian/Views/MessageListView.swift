//
//  MessageListView.swift
//  SafeGuardian
//
//  Created by Islam on 30/03/2026.
//

import BitFoundation
import SwiftUI

struct MessageListView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject var locationManager = LocationChannelManager.shared

    @Environment(\.colorScheme) var colorScheme

    let privatePeer: PeerID?
    @Binding var isAtBottom: Bool
    @Binding var messageText: String
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var showSidebar: Bool

    var isTextFieldFocused: FocusState<Bool>.Binding

    @State var showMessageActions = false
    @State var lastScrollTime: Date = .distantPast
    @State var scrollThrottleTimer: Timer?

    var body: some View {
        let currentWindowCount: Int = {
            if let peer = privatePeer {
                return windowCountPrivate[peer] ?? TransportConfig.uiWindowInitialCountPrivate
            }
            return windowCountPublic
        }()

        let messages = viewModel.getMessages(for: privatePeer)
        let windowedMessages = Array(messages.suffix(currentWindowCount))

        let contextKey: String = {
            if let peer = privatePeer {
                "dm:\(peer)"
            } else {
                locationManager.selectedChannel.contextKey
            }
        }()

        let messageItems: [MessageDisplayItem] = windowedMessages.compactMap { message in
            guard !message.content.trimmed.isEmpty else { return nil }
            return MessageDisplayItem(id: "\(contextKey)|\(message.id)", message: message)
        }

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(messageItems) { item in
                        let message = item.message
                        MessageRowView(item: item, imagePreviewURL: $imagePreviewURL)
                            .equatable()
                            .onAppear {
                                if message.id == windowedMessages.last?.id {
                                    isAtBottom = true
                                }
                                if message.id == windowedMessages.first?.id,
                                   messages.count > windowedMessages.count {
                                    expandWindow(
                                        ifNeededFor: message,
                                        allMessages: messages,
                                        privatePeer: privatePeer,
                                        proxy: proxy
                                    )
                                }
                            }
                            .onDisappear {
                                if message.id == windowedMessages.last?.id {
                                    isAtBottom = false
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let isAgentMessage = viewModel.agents.contains(where: { $0.peerID.id == message.sender })
                                if message.sender != "system" && !isAgentMessage {
                                    messageText = "@\(message.sender) "
                                    isTextFieldFocused.wrappedValue = true
                                }
                            }
                            .contextMenu {
                                Button("content.message.copy") {
                                    copyMessageContent(message.content)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                    }
                }
                .transaction { tx in if viewModel.isBatchingPublic { tx.disablesAnimations = true } }
                .padding(.vertical, 2)
            }
            .onOpenURL(perform: handleOpenURL)
            .onTapGesture(count: 3) { viewModel.sendMessage("/clear") }
            .onAppear { scrollToBottom(on: proxy) }
            .onChange(of: privatePeer) { _, _ in scrollToBottom(on: proxy) }
            .onChange(of: viewModel.messages.count) { _, _ in onMessagesChange(proxy: proxy) }
            .onChange(of: viewModel.privateChats) { _, _ in onPrivateChatsChange(proxy: proxy) }
            .onChange(of: locationManager.selectedChannel) { _, newValue in onSelectedChannelChange(newValue, proxy: proxy) }
            .confirmationDialog(
                selectedMessageSender.map { "@\($0)" } ?? String(localized: "content.actions.title"),
                isPresented: $showMessageActions,
                titleVisibility: .visible
            ) {
                MessageActionSheet(
                    messageText: $messageText,
                    isTextFieldFocused: isTextFieldFocused,
                    selectedMessageSender: selectedMessageSender,
                    selectedMessageSenderID: selectedMessageSenderID,
                    showSidebar: $showSidebar,
                    viewModel: viewModel
                )
            }
            .onAppear { markMessagesAsRead() }
            .onDisappear { scrollThrottleTimer?.invalidate() }
        }
        .environment(\.openURL, OpenURLAction { url in handleExternalURL(url) })
    }
}
