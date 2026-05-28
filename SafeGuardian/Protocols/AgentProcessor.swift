import Foundation
import BitFoundation

/// A formal contract for on-device or cloud-connected agents (Nova, Trek, Apex).
/// Conformers handle specific message triggers and provide routing logic.
@MainActor
protocol AgentProcessor: Sendable {
    /// The unique identifier for the agent (e.g., "nova", "trek").
    var agentID: String { get }

    /// The trigger prefix this agent responds to (e.g., "@nova").
    var triggerPrefix: String { get }

    /// The PeerID used for this agent's private chat thread.
    var peerID: PeerID { get }

    /// Determines if this agent should handle the given message.
    func shouldHandle(_ message: String) -> Bool
    
    /// Executes the agent's logic for the given prompt.
    /// - Parameters:
    ///   - prompt: The user's input (stripped of the trigger prefix).
    ///   - context: Access to the ChatViewModel for message injection and state.
    func handle(prompt: String, context: AgentContext)
}

/// A restricted interface for agents to interact with the main application.
/// This prevents agents from having full read/write access to the entire ViewModel.
@MainActor
protocol AgentContext {
    var nickname: String { get }
    var privateChats: [PeerID: [SafeGuardianMessage]] { get }
    var deviceTick: NovaStateTick? { get }
    var selectedGeohash: String? { get }
    func addLocalMessage(_ content: String)
    func addAgentLocalMessage(_ content: String, to peerID: PeerID)
    func addResponse(sender: String, content: String, privatePeerID: PeerID?) -> SafeGuardianMessage
    func notifyChange()
}
