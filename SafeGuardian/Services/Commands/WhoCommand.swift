import Foundation

@MainActor
struct WhoCommand: Command {
    let names = ["/w", "/who"]
    let usage = "/who"

    func execute(args: String, context: CommandContext) -> CommandResult {
        switch LocationChannelManager.shared.selectedChannel {
        case .location(let ch):
            guard let provider = context.provider else {
                return .success(message: "nobody around")
            }
            let myHex = (try? provider.idBridge.deriveIdentity(forGeohash: ch.geohash))?.publicKeyHex.lowercased()
            let people = provider.getVisibleGeoParticipants().filter { person in
                guard let me = myHex else { return true }
                return person.id.lowercased() != me
            }
            let names = people.map { $0.displayName }
            if names.isEmpty { return .success(message: "no one else is online right now") }
            return .success(message: "online: " + names.sorted().joined(separator: ", "))

        case .mesh:
            guard let peers = context.transport?.getPeerNicknames(), !peers.isEmpty else {
                return .success(message: "no one else is online right now")
            }
            return .success(message: "online: \(peers.values.sorted().joined(separator: ", "))")
        }
    }
}
