import Foundation

@MainActor
struct MessageCommand: Command {
    let names = ["/m", "/msg"]
    let usage = "/msg @nickname [message]"

    func execute(args: String, context: CommandContext) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            return .error(message: "usage: /msg @nickname [message]")
        }

        let targetName = String(parts[0])
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

        guard let peerID = context.provider?.getPeerIDForNickname(nickname) else {
            return .error(message: "'\(nickname)' not found")
        }

        context.provider?.startPrivateChat(with: peerID)

        if parts.count > 1 {
            context.provider?.sendPrivateMessage(String(parts[1]), to: peerID)
        }

        return .success(message: "started private chat with \(nickname)")
    }
}
