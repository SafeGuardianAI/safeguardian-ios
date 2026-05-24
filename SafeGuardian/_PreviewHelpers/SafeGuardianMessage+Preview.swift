//
// SafeGuardianMessage+Preview.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

extension SafeGuardianMessage {
    static var preview: SafeGuardianMessage {
        SafeGuardianMessage(
            id: UUID().uuidString,
            sender: "John Doe",
            content: "Hello",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: "Jane Doe",
            senderPeerID: nil,
            mentions: nil,
            deliveryStatus: .sent
        )
    }
}
