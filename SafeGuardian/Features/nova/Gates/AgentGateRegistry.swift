// AgentGateRegistry.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Evaluates a list of AgentGate instances against a context.
/// Returns true only when every gate passes — any failure short-circuits.
/// To add a gate: create one file in Gates/, implement AgentGate, add it to standard().
struct AgentGateRegistry {
    let gates: [any AgentGate]

    func shouldHandle(_ context: AgentGateContext) -> Bool {
        gates.allSatisfy { $0.passes(context) }
    }

    static func standard() -> AgentGateRegistry {
        AgentGateRegistry(gates: [
            BatteryGate()
        ])
    }
}
