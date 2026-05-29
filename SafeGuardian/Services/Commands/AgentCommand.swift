import Foundation

@MainActor
struct AgentCommand: Command {
    let names = ["/agent"]
    let usage = "/agent <agent_id> <message>"

    func execute(args: String, context: CommandContext) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return .error(message: usage)
        }
        let agentID = String(parts[0]).lowercased()
        let content = String(parts[1])
        guard let peers = context.transport?.getPeerNicknames(), !peers.isEmpty else {
            return .error(message: "no peers connected")
        }
        context.provider?.broadcastAgentMessage(agentID: agentID, content: content)
        return .success(message: "sent to \(agentID) on \(peers.count) peer\(peers.count == 1 ? "" : "s")")
    }
}
