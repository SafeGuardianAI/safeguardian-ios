//
// CommandProcessor.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
//

import CoreLocation
import Foundation
import BitFoundation

/// Simple struct for geo participant info used by CommandProcessor
struct CommandGeoParticipant {
    let id: String        // pubkey hex (lowercased)
    let displayName: String
}

/// Protocol defining what CommandProcessor needs from its context.
@MainActor
protocol CommandContextProvider: AnyObject {
    var nickname: String { get }
    var selectedPrivateChatPeer: PeerID? { get }
    var blockedUsers: Set<String> { get }
    var privateChats: [PeerID: [SafeGuardianMessage]] { get set }
    var idBridge: NostrIdentityBridge { get }

    func getPeerIDForNickname(_ nickname: String) -> PeerID?
    func getVisibleGeoParticipants() -> [CommandGeoParticipant]
    func nostrPubkeyForDisplayName(_ displayName: String) -> String?

    func startPrivateChat(with peerID: PeerID)
    func sendPrivateMessage(_ content: String, to peerID: PeerID)
    func clearCurrentPublicTimeline()
    func sendPublicRaw(_ content: String)

    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID)
    func addPublicSystemMessage(_ content: String)

    func toggleFavorite(peerID: PeerID)
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool)

    func addLocalMessage(_ content: String)
    func promptGPSShare()
}

/// Registry-based command dispatcher.
/// To add a command: implement the Command protocol in a new file and add it to
/// the commands array below. No other file needs to change.
@MainActor
final class CommandProcessor {
    weak var contextProvider: CommandContextProvider?
    weak var meshService: (any Transport)?
    private let identityManager: SecureIdentityStateManagerProtocol

    private let commands: [any Command] = [
        GPSCommand(),
        MessageCommand(),
        WhoCommand(),
        ClearCommand(),
        EmoteCommand(trigger: "hug", action: "hugs", emoji: ""),
        EmoteCommand(trigger: "slap", action: "slaps", emoji: "", suffix: " around a bit with a large trout"),
        BlockCommand(),
        UnblockCommand(),
        FavCommand(add: true),
        FavCommand(add: false),
    ]

    private lazy var lookup: [String: any Command] = {
        var table: [String: any Command] = [:]
        for command in commands {
            for name in command.names { table[name] = command }
        }
        return table
    }()

    init(contextProvider: CommandContextProvider? = nil, meshService: (any Transport)? = nil, identityManager: SecureIdentityStateManagerProtocol) {
        self.contextProvider = contextProvider
        self.meshService = meshService
        self.identityManager = identityManager
    }

    @MainActor
    func process(_ command: String) -> CommandResult {
        let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let cmd = parts.first else { return .error(message: "Invalid command") }
        let args = parts.count > 1 ? String(parts[1]) : ""

        guard let handler = lookup[String(cmd)] else {
            return .error(message: "unknown command: \(cmd)")
        }

        let context = CommandContext(
            provider: contextProvider,
            transport: meshService,
            identityManager: identityManager
        )
        return handler.execute(args: args, context: context)
    }
}
