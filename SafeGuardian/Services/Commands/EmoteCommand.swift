import Foundation

/// Handles /hug and /slap — parametric emote commands that follow the same pattern.
@MainActor
struct EmoteCommand: Command {
    let names: [String]
    let usage: String
    private let action: String
    private let emoji: String
    private let suffix: String

    init(trigger: String, action: String, emoji: String, suffix: String = "") {
        self.names = ["/\(trigger)"]
        self.usage = "/\(trigger) <nickname>"
        self.action = action
        self.emoji = emoji
        self.suffix = suffix
    }

    func execute(args: String, context: CommandContext) -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: "usage: \(usage)")
        }

        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

        guard let targetPeerID = context.provider?.getPeerIDForNickname(nickname),
              let myNickname = context.provider?.nickname else {
            return .error(message: "cannot \(names[0].dropFirst()) \(nickname): not found")
        }

        if context.provider?.selectedPrivateChatPeer != nil {
            if let peerNickname = context.transport?.peerNickname(peerID: targetPeerID) {
                let personalMessage = "* \(emoji) \(myNickname) \(action) you\(suffix) *"
                context.transport?.sendPrivateMessage(personalMessage, to: targetPeerID,
                                                      recipientNickname: peerNickname,
                                                      messageID: UUID().uuidString)
                let pastAction: String = {
                    switch action {
                    case "hugs": return "hugged"
                    case "slaps": return "slapped"
                    default: return action.hasSuffix("e") ? action + "d" : action + "ed"
                    }
                }()
                context.provider?.addLocalPrivateSystemMessage("\(emoji) you \(pastAction) \(nickname)\(suffix)", to: targetPeerID)
            }
        } else {
            context.provider?.sendPublicRaw("* \(emoji) \(myNickname) \(action) \(nickname)\(suffix) *")
            context.provider?.addPublicSystemMessage("\(emoji) \(myNickname) \(action) \(nickname)\(suffix)")
        }

        return .handled
    }
}
