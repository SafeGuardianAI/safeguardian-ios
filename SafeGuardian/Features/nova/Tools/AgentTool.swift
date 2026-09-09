import SafeGuardianMesh
// AgentTool.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import AgentRuntime
import BitFoundation
import Foundation

// MARK: - DispatchGuard

/// Counts tool dispatches within one generation session and signals when the
/// iteration cap is reached. Tool calls dispatch sequentially (each await
/// completes before the next starts), so the counter increment is safe
/// without a lock despite the @unchecked Sendable marker.
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
    private let _tick: @MainActor () -> AgentStateTick?
    private let _meshPacketRate: @MainActor () -> Double
    private let _broadcastInterval: @MainActor () -> TimeInterval
    private let _broadcastTTL: @MainActor () -> UInt8
    private let _setTickInterval: @MainActor (TimeInterval) -> Void
    private let _setMessageTTL: @MainActor (UInt8) -> Void
    private let _setMedicalStatus: @MainActor (AgentStateTick.MedicalStatus) -> Void
    private let _publishCurrentStateTick: @MainActor () -> Bool
    private let _sendMesh: @MainActor (String, String, PeerID, String?) -> Void
    private let _sendRequest: @MainActor (String, String, PeerID) -> Void
    private let _registerPeerContinuation: @MainActor (String, CheckedContinuation<String, Never>) -> Void
    private let _registerAgentContinuation: @MainActor (String, CheckedContinuation<String, Never>) -> Void
    private let _registerApprovalContinuation: @MainActor (String, String, String, PeerID, CheckedContinuation<Bool, Never>) -> Void
    private let _cancelAgentRequest: @MainActor (String) -> Void
    private let _cancelPeerRequest: @MainActor (String) -> Void
    private let _sendRaw: @MainActor (String, PeerID) -> Void
    let peerID: PeerID

    @MainActor
    init(senderAgentID: String, peerID: PeerID, context: some AgentContext) {
        self.peerID = peerID
        _meshPeerIDs       = { context.meshPeerIDs }
        _tick              = { context.deviceTick }
        _meshPacketRate    = { context.meshPacketRate }
        _broadcastInterval = { context.broadcastInterval }
        _broadcastTTL      = { context.broadcastTTL }
        _setTickInterval   = { context.setTickInterval($0) }
        _setMessageTTL     = { context.setMessageTTL($0) }
        _setMedicalStatus  = { context.setMedicalStatus($0) }
        _publishCurrentStateTick = { context.publishCurrentStateTick() }
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
        _registerApprovalContinuation = { toolName, argumentSummary, token, requestPeerID, continuation in
            context.registerToolApprovalContinuation(toolName, argumentSummary, token, requestPeerID, continuation)
        }
        _cancelAgentRequest = { requestID in
            context.cancelAgentRequest(requestID)
        }
        _cancelPeerRequest = { requestID in
            context.cancelPeerRequest(requestID)
        }
        _sendRaw = { content, peerID in
            context.sendRawPrivate(content, to: peerID)
        }
    }

    func meshPeerIDs() async -> Set<PeerID> { await MainActor.run { _meshPeerIDs() } }
    func tick() async -> AgentStateTick? { await MainActor.run { _tick() } }
    func meshPacketRate() async -> Double { await MainActor.run { _meshPacketRate() } }
    func broadcastInterval() async -> TimeInterval { await MainActor.run { _broadcastInterval() } }
    func broadcastTTL() async -> UInt8 { await MainActor.run { _broadcastTTL() } }
    func setTickInterval(_ s: TimeInterval) async { await MainActor.run { _setTickInterval(s) } }
    func setMessageTTL(_ ttl: UInt8) async { await MainActor.run { _setMessageTTL(ttl) } }
    func setMedicalStatus(_ s: AgentStateTick.MedicalStatus) async { await MainActor.run { _setMedicalStatus(s) } }
    func publishCurrentStateTick() async -> Bool { await MainActor.run { _publishCurrentStateTick() } }

    func sendMesh(toAgentID: String, content: String, peerID: PeerID) async {
        await MainActor.run { _sendMesh(toAgentID, content, peerID, nil) }
    }

    func cancelAgentRequest(_ requestID: String) async {
        await MainActor.run { _cancelAgentRequest(requestID) }
    }

    func cancelPeerRequest(_ requestID: String) async {
        await MainActor.run { _cancelPeerRequest(requestID) }
    }

    func sendRawPrivate(_ content: String, peerID: PeerID) async {
        await MainActor.run { _sendRaw(content, peerID) }
    }

    /// Sends a query to a remote agent and suspends until its reply arrives.
    /// Resumes with "timeout" if the parent Task is cancelled before a reply arrives,
    /// preventing the CheckedContinuation from leaking in pendingAgentReplies.
    func requestFromAgent(agentID: String, content: String, peerID: PeerID) async -> String {
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    self._registerAgentContinuation(requestID, continuation)
                    self._sendMesh(agentID, content, peerID, requestID)
                }
            }
        } onCancel: {
            Task { @MainActor in self._cancelAgentRequest(requestID) }
        }
    }

    /// Sends a structured peer request and suspends until the peer responds or declines.
    /// Resumes with "timeout" if the parent Task is cancelled before the peer replies.
    func requestFromPeer(type: String, peerID: PeerID) async -> String {
        let requestID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    self._registerPeerContinuation(requestID, continuation)
                    self._sendRequest(type, requestID, peerID)
                }
            }
        } onCancel: {
            Task { @MainActor in self._cancelPeerRequest(requestID) }
        }
    }

    /// Suspends until the host context approves or denies execution of the named tool.
    /// `argumentSummary` is shown verbatim in the approval card so the human approves
    /// the concrete action (these arguments, this call) rather than a blanket grant of
    /// the tool category. Safe from any isolation context — uses CheckedContinuation,
    /// does not block.
    func requestApproval(for toolName: String, argumentSummary: String) async -> Bool {
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased())
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                self._registerApprovalContinuation(toolName, argumentSummary, token, self.peerID, continuation)
            }
        }
    }
}

// MARK: - ApprovalDedup

/// Caches an approval decision and its executed result by a content-derived key
/// (tool name + argument summary) so a retried call within the same generation
/// session — the AgentStuckGuard/DispatchGuard case, a model re-issuing the same
/// tool_call — reuses the earlier decision and result instead of re-prompting the
/// human or re-executing a side effect like a send. There is no real tool-call ID
/// from the model layer to key on (ToolCall carries only name+arguments), so
/// identical arguments is the practical stand-in; this is scoped to one
/// AgentToolRegistry (one inference call, matching DispatchGuard/AgentStuckGuard's
/// own lifetime), not persisted across turns, so a deliberate repeat of the same
/// call in a later turn is unaffected. Mutation is safe unsynchronized because
/// dispatch calls are sequential (see DispatchGuard's own comment).
final class ApprovalDedup: @unchecked Sendable {
    private nonisolated(unsafe) var decisions: [String: Bool] = [:]
    private nonisolated(unsafe) var results: [String: String] = [:]

    static func key(name: String, argumentSummary: String) -> String {
        "\(name)|\(argumentSummary)"
    }

    func decision(for key: String) -> Bool? { decisions[key] }
    func recordDecision(_ approved: Bool, for key: String) { decisions[key] = approved }

    func cachedResult(for key: String) -> String? { results[key] }
    func recordResult(_ result: String, for key: String) { results[key] = result }
}

// MARK: - AgentToolRegistry

/// A Sendable collection of tool specs and a unified dispatch closure.
/// Build one per inference call; the dispatch closure embeds the iteration
/// guard, status callback, approval gate, stuck guard, and task record.
struct AgentToolRegistry: Sendable {
    let specs: [ToolSpec]
    let dispatch: @Sendable (ToolCall) async throws -> String
    let taskRecord: AgentTaskRecord

    /// Extracts tool names from the OpenAI-format spec dictionaries.
    var names: [String] {
        specs.compactMap { spec -> String? in
            guard let fn = spec["function"] as? [String: any Sendable] else { return nil }
            return fn["name"] as? String
        }
    }

    /// Renders a tool call's arguments as sorted-key JSON for display in the approval
    /// card, so the human approves the concrete call rather than the tool by name alone.
    static func argumentSummary(for arguments: [String: JSONValue]) -> String {
        guard !arguments.isEmpty else { return "(no arguments)" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(arguments),
              let string = String(data: data, encoding: .utf8)
        else { return "(unable to render arguments)" }
        return string
    }

    @MainActor
    static func build(
        agentID: String,
        context: some AgentContext,
        peerID: PeerID,
        deviceTools: [AgentToolEntry],
        meshTools: [AgentToolEntry],
        onStatus: StatusCallback? = nil,
        maxIterations: Int = NovaConfig.maxToolIterations,
        mcpRouting: [(name: String, session: MCPSession, spec: ToolSpec)] = [],
        taskRecord: AgentTaskRecord = AgentTaskRecord(),
        accountabilityLog: AccountabilityLog? = AgentAccountability.log
    ) -> AgentToolRegistry {
        let proxy = AgentContextProxy(senderAgentID: agentID, peerID: peerID, context: context)
        let guard_ = DispatchGuard(max: maxIterations)
        let stuck = AgentStuckGuard()
        let dedup = ApprovalDedup()
        let record = taskRecord
        let allTools = deviceTools + meshTools
        let lookup = Dictionary(uniqueKeysWithValues: allTools.map { ($0.name, $0) })
        let mcpLookup = Dictionary(uniqueKeysWithValues: mcpRouting.map { ($0.name, $0.session) })
        let specs: [ToolSpec] = allTools.map { $0.spec } + mcpRouting.map { $0.spec }

        // A tool call that originates from local model inference has no remote
        // sender: the same on-device agent both decided to call the tool
        // (associated with the Infer activity upstream) and executes it, so
        // requestedBy and executedBy name the same SoftwareAgent here. This
        // differs from LXMFToolRouter's accountability record, where the caller
        // is a distinct, remotely-authenticated identity.
        let novaRef = ProvenanceAgentRef(kind: .softwareAgent, id: agentID)
        // A plain @Sendable closure rather than a local func: `build` itself is
        // @MainActor, which would otherwise isolate a local func to the main
        // actor, but `dispatch` below runs off-actor, so this must be callable
        // from there without hopping.
        let recordAccountability: @Sendable (
            _ action: String, _ policy: String, _ decision: String, _ result: String?
        ) -> Void = { action, policy, decision, result in
            guard let accountabilityLog else { return }
            let entry = AccountabilityRecord(
                activity: .execute, requestedBy: novaRef, executedBy: novaRef,
                action: action, resource: action, policy: policy, decision: decision, result: result
            )
            Task { await accountabilityLog.record(entry) }
        }

        let dispatch: @Sendable (ToolCall) async throws -> String = { toolCall in
            let name = toolCall.function.name

            // Hard cap — returns a terminal message the model reads as a stop signal.
            guard guard_.next() else {
                recordAccountability(name, "iteration_limit", "deny", nil)
                return #"{"error":"iteration_limit","message":"Stop calling tools. Provide a final answer with what you know so far."}"#
            }

            // Policy lives on the tool itself (AgentToolEntry.requiresConfirmation) rather
            // than a name-keyed switch elsewhere, so a new consequential tool can't be
            // added without its author deciding this. MCP-routed tools have no
            // AgentToolEntry and never require confirmation.
            let requiresApproval = lookup[name]?.requiresConfirmation ?? false
            let dedupKey = requiresApproval
                ? ApprovalDedup.key(name: name, argumentSummary: Self.argumentSummary(for: toolCall.function.arguments))
                : nil

            // A retried call with identical arguments (AgentStuckGuard's territory)
            // returns the cached result rather than re-executing a side effect.
            if let dedupKey, let cachedResult = dedup.cachedResult(for: dedupKey) {
                return cachedResult
            }

            // Approval gate — suspends until the host context resumes the continuation,
            // unless this exact call was already decided earlier in this session.
            if requiresApproval, let dedupKey {
                let approved: Bool
                if let cached = dedup.decision(for: dedupKey) {
                    approved = cached
                } else {
                    let summary = Self.argumentSummary(for: toolCall.function.arguments)
                    approved = await proxy.requestApproval(for: name, argumentSummary: summary)
                    dedup.recordDecision(approved, for: dedupKey)
                }
                guard approved else {
                    recordAccountability(name, "user denied", "deny", nil)
                    return #"{"error":"denied","message":"User denied this tool call."}"#
                }
            }

            // Status update — fires before execution so the UI reflects current tool.
            await onStatus?.notify(name)

            // MCP-sourced tools route to their originating session.
            if let mcpSession = mcpLookup[name] {
                let args = toolCall.function.arguments.mapValues { $0.anyValue }
                let result = try await mcpSession.callTool(name: name, arguments: args)
                recordAccountability(name, requiresApproval ? "approved by user" : "no approval required", "permit", result)
                return result
            }

            guard let entry = lookup[name] else {
                return #"{"error":"unknown_tool","tool":"\#(name)"}"#
            }

            let result = try await entry.handler(toolCall.function.arguments, proxy)
            if let dedupKey { dedup.recordResult(result, for: dedupKey) }
            recordAccountability(name, requiresApproval ? "approved by user" : "no approval required", "permit", result)
            stuck.record(name, result: result)
            if let nudge = stuck.nudge(for: name) {
                return result + "\n" + nudge
            }
            return result
        }

        return AgentToolRegistry(specs: specs, dispatch: dispatch, taskRecord: record)
    }
}

// MARK: - AgentToolEntry

/// A single tool definition: its JSON schema spec and its async handler.
struct AgentToolEntry: Sendable {
    let name: String
    let spec: ToolSpec
    let handler: @Sendable ([String: JSONValue], AgentContextProxy) async throws -> String
    /// Declared at the tool's own definition site rather than in a separate name-keyed
    /// list elsewhere, so a new consequential tool can't be added without its author
    /// deciding whether it needs human approval before it executes.
    let requiresConfirmation: Bool

    static func make(
        name: String,
        description: String,
        parameters: [ToolParameter],
        requiresConfirmation: Bool = false,
        handler: @escaping @Sendable ([String: JSONValue], AgentContextProxy) async throws -> String
    ) -> AgentToolEntry {
        let spec = makeToolSpec(name: name, description: description, parameters: parameters)
        return AgentToolEntry(name: name, spec: spec, handler: handler, requiresConfirmation: requiresConfirmation)
    }
}
