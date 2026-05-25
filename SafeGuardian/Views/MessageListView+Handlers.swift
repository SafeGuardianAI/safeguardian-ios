//
//  MessageListView+Handlers.swift
//  SafeGuardian
//
//  This is free and unencumbered software released into the public domain.
//

import SwiftUI
import BitFoundation

extension MessageListView {
    func onMessagesChange(proxy: ScrollViewProxy) {
        guard privatePeer == nil, let lastMsg = viewModel.messages.last else { return }

        // If the newest message is from me, always scroll to bottom
        let isFromSelf = (lastMsg.sender == viewModel.nickname) || lastMsg.sender.hasPrefix(viewModel.nickname + "#")
        if !isFromSelf && !isAtBottom { // Only autoscroll when user is at/near bottom
            return
        } else { // Ensure we consider ourselves at bottom for subsequent messages
            isAtBottom = true
        }

        func scrollIfNeeded(date: Date) {
            lastScrollTime = date
            let contextKey = locationManager.selectedChannel.contextKey
            if let target = viewModel.messages.suffix(windowCountPublic).last.map({ "\(contextKey)|\($0.id)" }) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }

        // Throttle scroll animations to prevent excessive UI updates
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) > TransportConfig.uiScrollThrottleSeconds {
            // Immediate scroll if enough time has passed
            scrollIfNeeded(date: now)
        } else {
            // Schedule a delayed scroll
            scrollThrottleTimer?.invalidate()
            scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: TransportConfig.uiScrollThrottleSeconds, repeats: false) { _ in
                Task { @MainActor in
                    scrollIfNeeded(date: Date())
                }
            }
        }
    }

    func onPrivateChatsChange(proxy: ScrollViewProxy) {
        guard let peerID = privatePeer, let messages = viewModel.privateChats[peerID], let lastMsg = messages.last else {
            return
        }

        // If the newest private message is from me, always scroll
        let isFromSelf = (lastMsg.sender == viewModel.nickname) || lastMsg.sender.hasPrefix(viewModel.nickname + "#")
        if !isFromSelf && !isAtBottom { // Only autoscroll when user is at/near bottom
            return
        } else {
            isAtBottom = true
        }

        func scrollIfNeeded(date: Date) {
            lastScrollTime = date
            let contextKey = "dm:\(peerID)"
            let count = windowCountPrivate[peerID] ?? 300
            if let target = messages.suffix(count).last.map({ "\(contextKey)|\($0.id)" }){
                proxy.scrollTo(target, anchor: .bottom)
            }
        }

        // Same throttling for private chats
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) > TransportConfig.uiScrollThrottleSeconds {
            scrollIfNeeded(date: now)
        } else {
            scrollThrottleTimer?.invalidate()
            scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: TransportConfig.uiScrollThrottleSeconds, repeats: false) { _ in
                Task { @MainActor in
                    scrollIfNeeded(date: Date())
                }
            }
        }
    }

    func onSelectedChannelChange(_ channel: ChannelID, proxy: ScrollViewProxy) {
        // When switching to a new geohash channel, scroll to the bottom
        guard privatePeer == nil else { return }
        switch channel {
        case .mesh:
            break
        case .location(let ch):
            // Reset window size
            isAtBottom = true
            windowCountPublic = TransportConfig.uiWindowInitialCountPublic
            let contextKey = "geo:\(ch.geohash)"
            if let target = viewModel.messages.suffix(windowCountPublic).last?.id.map({ "\(contextKey)|\($0)" }) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }
}
