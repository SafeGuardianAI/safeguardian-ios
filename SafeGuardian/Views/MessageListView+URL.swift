//
//  MessageListView+URL.swift
//  SafeGuardian
//
//  This is free and unencumbered software released into the public domain.
//

import SwiftUI
import BitFoundation

extension MessageListView {
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "safeguardian" else { return }
        switch url.host {
        case "user":
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let peerID = PeerID(str: id.removingPercentEncoding ?? id)
            selectedMessageSenderID = peerID

            if peerID.isGeoDM || peerID.isGeoChat {
                selectedMessageSender = viewModel.geohashDisplayName(for: peerID)
            } else if let name = viewModel.meshService.peerNickname(peerID: peerID) {
                selectedMessageSender = name
            } else {
                selectedMessageSender = viewModel.messages.last(where: { $0.senderPeerID == peerID && $0.sender != "system" })?.sender
            }

            if viewModel.isSelfSender(peerID: peerID, displayName: selectedMessageSender) {
                selectedMessageSender = nil
                selectedMessageSenderID = nil
            } else {
                showMessageActions = true
            }

        case "geohash":
            let gh = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
            guard (2...12).contains(gh.count), gh.allSatisfy({ allowed.contains($0) }) else { return }

            func levelForLength(_ len: Int) -> GeohashChannelLevel {
                switch len {
                case 0...2: return .region
                case 3...4: return .province
                case 5: return .city
                case 6: return .neighborhood
                case 7: return .block
                default: return .block
                }
            }

            let level = levelForLength(gh.count)
            let channel = GeohashChannel(level: level, geohash: gh)

            let inRegional = LocationChannelManager.shared.availableChannels.contains { $0.geohash == gh }
            if !inRegional && !LocationChannelManager.shared.availableChannels.isEmpty {
                LocationChannelManager.shared.markTeleported(for: gh, true)
            }
            LocationChannelManager.shared.select(ChannelID.location(channel))

        default:
            return
        }
    }
}
