//
//  MessageListView+Helpers.swift
//  SafeGuardian
//
//  This is free and unencumbered software released into the public domain.
//

import SwiftUI
import BitFoundation

extension MessageListView {
    func copyMessageContent(_ content: String) {
        #if os(iOS)
        UIPasteboard.general.string = content
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
        #endif
    }

    func markMessagesAsRead() {
        if let peerID = privatePeer {
            viewModel.markPrivateMessagesAsRead(from: peerID)
            DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiReadReceiptRetryShortSeconds) {
                viewModel.markPrivateMessagesAsRead(from: peerID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiReadReceiptRetryLongSeconds) {
                viewModel.markPrivateMessagesAsRead(from: peerID)
            }
        }
    }

    func handleExternalURL(_ url: URL) -> OpenURLAction.Result {
        if let scheme = url.scheme?.lowercased(), scheme == "cashu" || scheme == "lightning" {
            #if os(iOS)
            UIApplication.shared.open(url)
            return .handled
            #else
            return .systemAction
            #endif
        }
        return .systemAction
    }
}

struct MessageActionSheet: View {
    @Binding var messageText: String
    var isTextFieldFocused: FocusState<Bool>.Binding
    let selectedMessageSender: String?
    let selectedMessageSenderID: PeerID?
    @Binding var showSidebar: Bool
    let viewModel: ChatViewModel

    var body: some View {
        Button("content.actions.mention") {
            if let sender = selectedMessageSender {
                messageText = "@\(sender) "
                isTextFieldFocused.wrappedValue = true
            }
        }

        Button("content.actions.direct_message") {
            if let peerID = selectedMessageSenderID {
                if peerID.isGeoChat {
                    if let full = viewModel.fullNostrHex(forSenderPeerID: peerID) {
                        viewModel.startGeohashDM(withPubkeyHex: full)
                    }
                } else {
                    viewModel.startPrivateChat(with: peerID)
                }
                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                    showSidebar = true
                }
            }
        }

        Button("content.actions.hug") {
            if let sender = selectedMessageSender {
                viewModel.sendMessage("/hug @\(sender)")
            }
        }

        Button("content.actions.slap") {
            if let sender = selectedMessageSender {
                viewModel.sendMessage("/slap @\(sender)")
            }
        }

        Button("content.actions.block", role: .destructive) {
            if let peerID = selectedMessageSenderID, peerID.isGeoChat,
               let full = viewModel.fullNostrHex(forSenderPeerID: peerID),
               let sender = selectedMessageSender {
                viewModel.blockGeohashUser(pubkeyHexLowercased: full, displayName: sender)
            } else if let sender = selectedMessageSender {
                viewModel.sendMessage("/block \(sender)")
            }
        }

        Button("common.cancel", role: .cancel) {}
    }
}
