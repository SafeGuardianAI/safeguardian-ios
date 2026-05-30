import BitFoundation
import Foundation
import MLXLMCommon

/// Bridges @MainActor-isolated AgentContext into @Sendable tool dispatch closures.
/// Marked @unchecked Sendable because every access to MainActor-isolated state
/// routes through MainActor.run — the threading contract is manually enforced.
final class AgentContextProxy: @unchecked Sendable {
    private let _meshPeerIDs: @MainActor () -> Set<PeerID>
    private let _tick: @MainActor () -> NovaStateTick?
    private let _sendMesh: @MainActor (String, String, PeerID) -> Void
    private let _sendRequest: @MainActor (String, String, PeerID) -> Void
    private let _registerContinuation: @MainActor (String, CheckedContinuation<String, Never>) -> Void

    @MainActor
    init(senderAgentID: String, context: some AgentContext) {
        _meshPeerIDs = { context.meshPeerIDs }
        _tick = { context.deviceTick }
        _sendMesh = { toAgentID, content, peerID in
            context.sendMeshMessage(agentID: senderAgentID, content: content, to: peerID)
        }
        _sendRequest = { type, requestID, peerID in
            context.sendPeerRequest(type: type, requestID: requestID, to: peerID)
        }
        _registerContinuation = { requestID, continuation in
            context.registerPeerRequestContinuation(requestID, continuation)
        }
    }

    func meshPeerIDs() async -> Set<PeerID> { await MainActor.run { _meshPeerIDs() } }
    func tick() async -> NovaStateTick? { await MainActor.run { _tick() } }
    func sendMesh(toAgentID: String, content: String, peerID: PeerID) async {
        await MainActor.run { _sendMesh(toAgentID, content, peerID) }
    }

    /// Sends a structured peer request and suspends until the peer responds or declines.
    /// Returns a human-readable result string the agent can use directly in its reply.
    func requestFromPeer(type: String, peerID: PeerID) async -> String {
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let id = String(requestID)
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                self._registerContinuation(id, continuation)
                self._sendRequest(type, id, peerID)
            }
        }
    }
}

/// A Sendable collection of tool specs and a unified dispatch closure ready
/// to pass directly to ChatSession. Build one per inference call using
/// AgentToolRegistry.build(agentID:context:).
struct AgentToolRegistry: Sendable {
    let specs: [ToolSpec]
    let dispatch: @Sendable (ToolCall) async throws -> String

    @MainActor
    static func build(
        agentID: String,
        context: some AgentContext,
        deviceTools: [AgentToolEntry],
        meshTools: [AgentToolEntry]
    ) -> AgentToolRegistry {
        let proxy = AgentContextProxy(senderAgentID: agentID, context: context)
        let allTools = deviceTools + meshTools
        let lookup = Dictionary(uniqueKeysWithValues: allTools.map { ($0.name, $0) })
        let specs = allTools.map { $0.spec }
        let dispatch: @Sendable (ToolCall) async throws -> String = { toolCall in
            let name = toolCall.function.name
            guard let entry = lookup[name] else {
                return #"{"error":"unknown tool \#(name)"}"#
            }
            return try await entry.handler(toolCall.function.arguments, proxy)
        }
        return AgentToolRegistry(specs: specs, dispatch: dispatch)
    }
}

/// A single tool definition: its JSON schema spec and its async handler.
struct AgentToolEntry: Sendable {
    let name: String
    let spec: ToolSpec
    let handler: @Sendable ([String: JSONValue], AgentContextProxy) async throws -> String

    static func make(
        name: String,
        description: String,
        parameters: [ToolParameter],
        handler: @escaping @Sendable ([String: JSONValue], AgentContextProxy) async throws -> String
    ) -> AgentToolEntry {
        let tool = Tool<[String: String], String>(name: name, description: description, parameters: parameters) { _ in "" }
        return AgentToolEntry(name: name, spec: tool.schema, handler: handler)
    }
}
