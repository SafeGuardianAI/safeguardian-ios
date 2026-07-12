import BitFoundation
import SwiftUI

struct NovaBubble: View {
    let message: SafeGuardianMessage

    private var isUser: Bool { message.sender != "Nova" && message.sender != "local" }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 40) }
            bubbleContent
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var bubbleContent: some View {
        Text(message.content)
            .font(.system(size: 15, design: .monospaced))
            .foregroundColor(textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isUser ? Color.blue.opacity(0.15) : Color.primary.opacity(0.06))
            )
    }

    private var textColor: Color {
        message.sender == "local" ? .secondary : .primary
    }
}
