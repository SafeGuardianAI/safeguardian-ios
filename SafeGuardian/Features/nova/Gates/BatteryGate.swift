// BatteryGate.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Rejects mesh queries when battery is critically low.
/// Local queries always pass regardless of battery level.
struct BatteryGate: AgentGate {
    let name = "battery"
    let threshold: Float

    init(threshold: Float = NovaConfig.meshQueryMinBatteryPct) {
        self.threshold = threshold
    }

    func passes(_ context: AgentGateContext) -> Bool {
        guard context.isMeshQuery else { return true }
        let battery = Float(context.tick?.batteryPct ?? 1.0)
        return battery >= threshold
    }
}
