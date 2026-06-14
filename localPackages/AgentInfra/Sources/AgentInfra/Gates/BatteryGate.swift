// BatteryGate.swift
// AgentInfra
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Rejects mesh queries when battery is critically low.
/// Local queries always pass regardless of battery level.
public struct BatteryGate: AgentGate {
    public let name = "battery"
    public let threshold: Float

    public init(threshold: Float = 0.10) {
        self.threshold = threshold
    }

    public func passes(_ context: AgentGateContext) -> Bool {
        guard context.isMeshQuery else { return true }
        let battery = Float(context.tick?.batteryPct ?? 1.0)
        return battery >= threshold
    }
}
