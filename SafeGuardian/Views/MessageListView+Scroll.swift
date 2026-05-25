//
//  MessageListView+Scroll.swift
//  SafeGuardian
//
//  This is free and unencumbered software released into the public domain.
//

import SwiftUI
import BitFoundation

extension MessageListView {
    func expandWindow(ifNeededFor message: SafeGuardianMessage,
                      allMessages: [SafeGuardianMessage],
                      privatePeer: PeerID?,
                      proxy: ScrollViewProxy) {
        let step = TransportConfig.uiWindowStepCount
        let contextKey: String = {
            if let peer = privatePeer {
                "dm:\(peer)"
            } else {
                locationManager.selectedChannel.contextKey
            }
        }()
        let preserveID = "\(contextKey)|\(message.id)"

        if let peer = privatePeer {
            let current = windowCountPrivate[peer] ?? TransportConfig.uiWindowInitialCountPrivate
            let newCount = min(allMessages.count, current + step)
            guard newCount != current else { return }
            windowCountPrivate[peer] = newCount
            DispatchQueue.main.async {
                proxy.scrollTo(preserveID, anchor: .top)
            }
        } else {
            let current = windowCountPublic
            let newCount = min(allMessages.count, current + step)
            guard newCount != current else { return }
            windowCountPublic = newCount
            DispatchQueue.main.async {
                proxy.scrollTo(preserveID, anchor: .top)
            }
        }
    }

    func scrollToBottom(on proxy: ScrollViewProxy) {
        isAtBottom = true
        if let targetPeerID {
            proxy.scrollTo(targetPeerID, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let secondTarget = self.targetPeerID {
                proxy.scrollTo(secondTarget, anchor: .bottom)
            }
        }
    }

    var targetPeerID: String? {
        if let peer = privatePeer,
           let last = viewModel.getPrivateChatMessages(for: peer).suffix(300).last?.id {
            return "dm:\(peer)|\(last)"
        }
        if let last = viewModel.messages.suffix(300).last?.id {
            return "\(locationManager.selectedChannel.contextKey)|\(last)"
        }
        return nil
    }
}
