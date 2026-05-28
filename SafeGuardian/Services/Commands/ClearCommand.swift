import Foundation

@MainActor
struct ClearCommand: Command {
    let names = ["/clear"]
    let usage = "/clear"

    func execute(args: String, context: CommandContext) -> CommandResult {
        if let peerID = context.provider?.selectedPrivateChatPeer {
            context.provider?.privateChats[peerID]?.removeAll()
        } else {
            context.provider?.clearCurrentPublicTimeline()
        }
        return .handled
    }
}
