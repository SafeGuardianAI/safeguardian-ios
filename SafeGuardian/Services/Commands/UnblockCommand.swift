import Foundation

@MainActor
struct UnblockCommand: Command {
    let names = ["/unblock"]
    let usage = "/unblock <nickname>"

    func execute(args: String, context: CommandContext) -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: "usage: /unblock <nickname>")
        }

        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        let identityManager = context.identityManager

        if let peerID = context.provider?.getPeerIDForNickname(nickname),
           let fp = context.transport?.getFingerprint(for: peerID) {
            if !identityManager.isBlocked(fingerprint: fp) {
                return .success(message: "\(nickname) is not blocked")
            }
            identityManager.setBlocked(fp, isBlocked: false)
            return .success(message: "unblocked \(nickname)")
        }

        if let pub = context.provider?.nostrPubkeyForDisplayName(nickname) {
            if !identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: "\(nickname) is not blocked")
            }
            identityManager.setNostrBlocked(pub, isBlocked: false)
            return .success(message: "unblocked \(nickname) in geohash chats")
        }

        return .error(message: "cannot unblock \(nickname): not found")
    }
}
