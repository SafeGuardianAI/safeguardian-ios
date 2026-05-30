// AgentGate.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Minimal context evaluated by pre-inference gates.
/// Assembled at call time from already-available device state — no inference, no async.
struct AgentGateContext {
    let prompt: String
    let tick: NovaStateTick?
    /// True when the prompt arrived from a remote peer via AgentMeshRouting.
    /// Local @nova queries always have isMeshQuery == false and must bypass mesh-only gates.
    let isMeshQuery: Bool
    let modelID: String
}

/// A pure synchronous predicate evaluated before provider.generate() is called.
/// Must return in microseconds — no network, no async, no model calls.
protocol AgentGate {
    var name: String { get }
    func passes(_ context: AgentGateContext) -> Bool
}
