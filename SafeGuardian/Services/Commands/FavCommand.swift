import Foundation

@MainActor
struct FavCommand: Command {
    let names: [String]
    let usage: String
    private let add: Bool

    init(add: Bool) {
        self.add = add
        self.names = add ? ["/fav"] : ["/unfav"]
        self.usage = add ? "/fav <nickname>" : "/unfav <nickname>"
    }

    func execute(args: String, context: CommandContext) -> CommandResult {
        let inGeoPublic: Bool = {
            if case .location = LocationChannelManager.shared.selectedChannel { return true }
            return false
        }()
        let inGeoDM = context.provider?.selectedPrivateChatPeer?.isGeoDM == true
        if inGeoPublic || inGeoDM {
            return .error(message: "favorites are only for mesh peers in #mesh")
        }

        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: "usage: \(usage)")
        }

        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

        guard let peerID = context.provider?.getPeerIDForNickname(nickname),
              let noisePublicKey = Data(hexString: peerID.id) else {
            return .error(message: "can't find peer: \(nickname)")
        }

        if add {
            let existing = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey)
            FavoritesPersistenceService.shared.addFavorite(
                peerNoisePublicKey: noisePublicKey,
                peerNostrPublicKey: existing?.peerNostrPublicKey,
                peerNickname: nickname
            )
            context.provider?.toggleFavorite(peerID: peerID)
            context.provider?.sendFavoriteNotification(to: peerID, isFavorite: true)
            return .success(message: "added \(nickname) to favorites")
        } else {
            FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noisePublicKey)
            context.provider?.toggleFavorite(peerID: peerID)
            context.provider?.sendFavoriteNotification(to: peerID, isFavorite: false)
            return .success(message: "removed \(nickname) from favorites")
        }
    }
}
