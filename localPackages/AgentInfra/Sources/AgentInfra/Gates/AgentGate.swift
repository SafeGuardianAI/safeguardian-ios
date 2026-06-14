// AgentGate.swift
// AgentInfra
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Minimal context evaluated by pre-inference gates.
/// Assembled at call time from already-available device state — no inference, no async.
public struct AgentGateContext {
    public let prompt: String
    public let tick: AgentStateTick?
    /// True when the prompt arrived from a remote peer via AgentMeshRouting.
    /// Local @nova queries always have isMeshQuery == false and must bypass mesh-only gates.
    public let isMeshQuery: Bool
    public let modelID: String

    public init(prompt: String, tick: AgentStateTick?, isMeshQuery: Bool, modelID: String) {
        self.prompt = prompt
        self.tick = tick
        self.isMeshQuery = isMeshQuery
        self.modelID = modelID
    }
}

/// A pure synchronous predicate evaluated before provider.generate() is called.
/// Must return in microseconds — no network, no async, no model calls.
public protocol AgentGate {
    var name: String { get }
    func passes(_ context: AgentGateContext) -> Bool
}
