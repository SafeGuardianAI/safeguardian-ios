// AgentTool.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import BitFoundation
import Foundation
import MLXLMCommon

// MARK: - DispatchGuard

/// Counts tool dispatches within one generation session and signals when the
/// iteration cap is reached. MLXLMCommon dispatches tool calls sequentially
/// (each await completes before the next starts), so the counter increment is
/// safe without a lock despite the @unchecked Sendable marker.
final class DispatchGuard: @unchecked Sendable {
    nonisolated(unsafe) private var count = 0
    let max: Int
    init(max: Int) { self.max = max }

    /// Returns true if the call is within the allowed budget, false when the cap
    /// is exceeded. The caller should return a terminal error to the model.
    func next() -> Bool {
        count += 1
        return count <= max
    }
}

// MARK: - StatusCallback

/// Accumulates tool names called during a generation session and fires a
/// MainActor status update for each one so the UI can show meaningful progress.
/// Marked @unchecked Sendable because mutation always happens before the
/// MainActor hop; the dispatch is sequential so there is no concurrent write.
final class StatusCallback: @unchecked Sendable {
    private(set) var calledToolNames: [String] = []
    private let _update: @MainActor (String) -> Void

    @MainActor
    init(_ update: @escaping @MainActor (String) -> Void) {
        _update = update
    }

    func notify(_ toolName: String) async {
        calledToolNames.append(toolName)
        await MainActor.run { _update(toolName) }
    }
}

// MARK: - AgentContextProxy

/// Bridges @MainActor-isolated AgentContext into @Sendable tool dispatch closures.
/// Marked @unchecked Sendable because every access to MainActor-isolated state
/// routes through MainActor.run — the threading contract is manually enforced.
final class AgentContextProxy: @unchecked Sendable {
    private let _meshPeerIDs: @MainActor () -> Set<PeerID>
    private let _tick: @MainActor () -> NovaStateTick?
    private let _meshPacketRate: @MainActor () -> Double
    private let _broadcastInterval: @MainActor () -> TimeInterval
    private let _broadcastTTL: @MainActor () -> UInt8
    private let _setTickInterval: @MainActor (TimeInterval) -> Void
    private let _setMessageTTL: @MainActor (UInt8) -> Void
    private let _sendMesh: @MainActor (String, String, PeerID, String?) -> Void
    private let _sendRequest: @MainActor (String, String, PeerID) -> Void
    private let _registerPeerContinuation: @MainActor (String, CheckedContinuation<String, Never>) -> Void
    private let _registerAgentContinuation: @MainActor (String, CheckedContinuation<String, Never>) -> Void
    private let _registerApprovalContinuation: @MainActor (String, CheckedContinuation<Bool, Never>) -> Void

    @MainActor
    init(senderAgentID: String, context: some AgentContext) {
        _meshPeerIDs       = { context.meshPeerIDs }
        _tick              = { context.deviceTick }
        _meshPacketRate    = { context.meshPacketRate }
        _broadcastInterval = { context.broadcastInterval }
        _broadcastTTL      = { context.broadcastTTL }
        _setTickInterval   = { context.setTickInterval($0) }
        _setMessageTTL     = { context.setMessageTTL($0) }
        _sendMesh = { toAgentID, content, peerID, requestID in
            context.sendMeshMessage(agentID: senderAgentID, content: content, to: peerID, requestID: requestID)
        }
        _sendRequest = { type, requestID, peerID in
            context.sendPeerRequest(type: type, requestID: requestID, to: peerID)
        }
        _registerPeerContinuation = { requestID, continuation in
            context.registerPeerRequestContinuation(requestID, continuation)
        }
        _registerAgentContinuation = { requestID, continuation in
            context.registerAgentReplyContinuation(requestID, continuation)
        }
        _registerApprovalContinuation = { token, continuation in
            context.registerToolApprovalContinuation(token, continuation)
        }
    }

    func meshPeerIDs() async -> Set<PeerID> { await MainActor.run { _meshPeerIDs() } }
    func tick() async -> NovaStateTick? { await MainActor.run { _tick() } }
    func meshPacketRate() async -> Double { await MainActor.run { _meshPacketRate() } }
    func broadcastInterval() async -> TimeInterval { await MainActor.run { _broadcastInterval() } }
    func broadcastTTL() async -> UInt8 { await MainActor.run { _broadcastTTL() } }
    func setTickInterval(_ s: TimeInterval) async { await MainActor.run { _setTickInterval(s) } }
    func setMessageTTL(_ ttl: UInt8) async { await MainActor.run { _setMessageTTL(ttl) } }

    func sendMesh(toAgentID: String, content: String, peerID: PeerID) async {
        await MainActor.run { _sendMesh(toAgentID, content, peerID, nil) }
    }

    /// Sends a query to a remote agent and suspends until its reply arrives.
    func requestFromAgent(agentID: String, content: String, peerID: PeerID) async -> String {
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                self._registerAgentContinuation(requestID, continuation)
                self._sendMesh(agentID, content, peerID, requestID)
            }
        }
    }

    /// Sends a structured peer request and suspends until the peer responds or declines.
    func requestFromPeer(type: String, peerID: PeerID) async -> String {
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let id = String(requestID)
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                self._registerPeerContinuation(id, continuation)
                self._sendRequest(type, id, peerID)
            }
        }
    }

    /// Suspends until the host context approves or denies execution of the named tool.
    /// Safe from any isolation context — uses CheckedContinuation, does not block.
    func requestApproval(for toolName: String) async -> Bool {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let id = String(token)
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                self._registerApprovalContinuation(id, continuation)
            }
        }
    }
}

// MARK: - AgentToolRegistry

/// A Sendable collection of tool specs and a unified dispatch closure.
/// Build one per inference call; the dispatch closure embeds the iteration
/// guard, status callback, and approval gate.
struct AgentToolRegistry: Sendable {
    let specs: [ToolSpec]
    let dispatch: @Sendable (ToolCall) async throws -> String

    @MainActor
    static func build(
        agentID: String,
        context: some AgentContext,
        deviceTools: [AgentToolEntry],
        meshTools: [AgentToolEntry],
        onStatus: StatusCallback? = nil,
        approvalCheck: (@Sendable (String) -> Bool)? = nil,
        maxIterations: Int = NovaConfig.maxToolIterations
    ) -> AgentToolRegistry {
        let proxy = AgentContextProxy(senderAgentID: agentID, context: context)
        let guard_ = DispatchGuard(max: maxIterations)
        let allTools = deviceTools + meshTools
        let lookup = Dictionary(uniqueKeysWithValues: allTools.map { ($0.name, $0) })
        let specs = allTools.map { $0.spec }

        let dispatch: @Sendable (ToolCall) async throws -> String = { toolCall in
            let name = toolCall.function.name

            // Hard cap — returns a terminal message the model reads as a stop signal.
            guard guard_.next() else {
                return #"{"error":"iteration_limit","message":"Stop calling tools. Provide a final answer with what you know so far."}"#
            }

            // Approval gate — suspends until the host context resumes the continuation.
            if approvalCheck?(name) == true {
                let approved = await proxy.requestApproval(for: name)
                guard approved else {
                    return #"{"error":"denied","message":"User denied this tool call."}"#
                }
            }

            // Status update — fires before execution so the UI reflects current tool.
            await onStatus?.notify(name)

            guard let entry = lookup[name] else {
                return #"{"error":"unknown_tool","tool":"\#(name)"}"#
            }
            return try await entry.handler(toolCall.function.arguments, proxy)
        }

        return AgentToolRegistry(specs: specs, dispatch: dispatch)
    }
}

// MARK: - AgentToolEntry

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
        let tool = Tool<[String: String], String>(
            name: name, description: description, parameters: parameters
        ) { _ in "" }
        return AgentToolEntry(name: name, spec: tool.schema, handler: handler)
    }
}
