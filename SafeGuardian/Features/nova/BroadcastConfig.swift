import Foundation

/// Per-agent broadcast configuration. Defines the initial timing policy and
/// TTL for a single broadcasting agent. All values are tunable at runtime via
/// AgentBroadcaster — this struct carries only the defaults and hard bounds.
struct BroadcastConfig {
    let agentID: String

    // Timer policy
    let normalInterval: TimeInterval       // interval under normal battery
    let reducedInterval: TimeInterval      // interval when battery < reducedThreshold

    // Agent-adjustable bounds
    let minAgentInterval: TimeInterval
    let maxAgentInterval: TimeInterval

    // Battery gates
    let batteryReducedThreshold: Float
    let batterySuspendThreshold: Float

    // Routing defaults
    let defaultTTL: UInt8

    // Minimum gap between any two emissions regardless of delta triggers.
    // Prevents a fast-changing state from flooding the mesh.
    let minDeltaInterval: TimeInterval

    var sequenceKey: String { "broadcaster.\(agentID).tick_sequence" }
}

extension BroadcastConfig {
    static let nova = BroadcastConfig(
        agentID: "nova",
        normalInterval: 60,
        reducedInterval: 120,
        minAgentInterval: 30,
        maxAgentInterval: 300,
        batteryReducedThreshold: 0.20,
        batterySuspendThreshold: 0.05,
        defaultTTL: 7,
        minDeltaInterval: 10
    )

    static let trek = BroadcastConfig(
        agentID: "trek",
        normalInterval: 10,
        reducedInterval: 30,
        minAgentInterval: 5,
        maxAgentInterval: 60,
        batteryReducedThreshold: 0.20,
        batterySuspendThreshold: 0.05,
        defaultTTL: 5,
        minDeltaInterval: 3
    )
}
