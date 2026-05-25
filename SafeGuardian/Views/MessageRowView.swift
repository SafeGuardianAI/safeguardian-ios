//
//  MessageRowView.swift
//  SafeGuardian
//
//  This is free and unencumbered software released into the public domain.
//

import SwiftUI
import BitFoundation

struct MessageDisplayItem: Identifiable, Equatable {
    let id: String
    let message: SafeGuardianMessage
    
    static func == (lhs: MessageDisplayItem, rhs: MessageDisplayItem) -> Bool {
        lhs.id == rhs.id && 
        lhs.message === rhs.message && 
        lhs.message.deliveryStatus == rhs.message.deliveryStatus
    }
}

struct MessageRowView: View, Equatable {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    
    let item: MessageDisplayItem
    @Binding var imagePreviewURL: URL?
    
    static func == (lhs: MessageRowView, rhs: MessageRowView) -> Bool {
        lhs.item == rhs.item &&
        lhs.imagePreviewURL == rhs.imagePreviewURL
    }
    
    var body: some View {
        let message = item.message
        Group {
            if message.sender == "system" {
                systemMessageRow(message)
            } else if let media = message.mediaAttachment(for: viewModel.nickname) {
                MediaMessageView(message: message, media: media, imagePreviewURL: $imagePreviewURL)
            } else {
                TextMessageView(message: message)
            }
        }
    }
    
    @ViewBuilder
    private func systemMessageRow(_ message: SafeGuardianMessage) -> some View {
        Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
