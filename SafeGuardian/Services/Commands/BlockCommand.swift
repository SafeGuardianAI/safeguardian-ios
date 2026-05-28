import Foundation

@MainActor
struct BlockCommand: Command {
    let names = ["/block"]
    let usage = "/block [nickname]"

    func execute(args: String, context: CommandContext) -> CommandResult {
        let targetName = args.trimmed
        let identityManager = context.identityManager

        if targetName.isEmpty {
            let meshBlocked = context.provider?.blockedUsers ?? []
            var blockedNicknames: [String] = []
            if let peers = context.transport?.getPeerNicknames() {
                for (peerID, nickname) in peers {
                    if let fp = context.transport?.getFingerprint(for: peerID),
                       meshBlocked.contains(fp) {
                        blockedNicknames.append(nickname)
                    }
                }
            }

            let geoBlocked = Array(identityManager.getBlockedNostrPubkeys())
            var geoNames: [String] = []
            if let provider = context.provider {
                let visible = provider.getVisibleGeoParticipants()
                let index = Dictionary(uniqueKeysWithValues: visible.map { ($0.id.lowercased(), $0.displayName) })
                for pk in geoBlocked {
                    if let name = index[pk.lowercased()] {
                        geoNames.append(name)
                    } else {
                        geoNames.append("anon#\(String(pk.suffix(4)))")
                    }
                }
            }

            let meshList = blockedNicknames.isEmpty ? "none" : blockedNicknames.sorted().joined(separator: ", ")
            let geoList = geoNames.isEmpty ? "none" : geoNames.sorted().joined(separator: ", ")
            return .success(message: "blocked peers: \(meshList) | geohash blocks: \(geoList)")
        }

        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

        if let peerID = context.provider?.getPeerIDForNickname(nickname),
           let fp = context.transport?.getFingerprint(for: peerID) {
            if identityManager.isBlocked(fingerprint: fp) {
                return .success(message: "\(nickname) is already blocked")
            }
            if var identity = identityManager.getSocialIdentity(for: fp) {
                identity.isBlocked = true
                identity.isFavorite = false
                identityManager.updateSocialIdentity(identity)
            } else {
                identityManager.updateSocialIdentity(SocialIdentity(
                    fingerprint: fp, localPetname: nil, claimedNickname: nickname,
                    trustLevel: .unknown, isFavorite: false, isBlocked: true, notes: nil
                ))
            }
            return .success(message: "blocked \(nickname). you will no longer receive messages from them")
        }

        if let pub = context.provider?.nostrPubkeyForDisplayName(nickname) {
            if identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: "\(nickname) is already blocked")
            }
            identityManager.setNostrBlocked(pub, isBlocked: true)
            return .success(message: "blocked \(nickname) in geohash chats")
        }

        return .error(message: "cannot block \(nickname): not found or unable to verify identity")
    }
}
