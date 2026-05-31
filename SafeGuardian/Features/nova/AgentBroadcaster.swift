import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

/// Generic timer-and-battery engine shared by every broadcasting agent.
///
/// Two emission paths:
///   1. Heartbeat — timer fires at currentInterval and always emits a full
///      state tick so peers know the node is alive even if nothing changed.
///   2. Delta — the agent calls triggerIfChanged() when observed state
///      changes. The broadcaster compares against the last emission using
///      the agent-supplied significantChange closure, and emits immediately
///      if the change crosses the threshold. Rapid bursts are suppressed via
///      a minimum delta interval so a fast-moving user does not flood the mesh.
///
/// Cumulative semantics: every emitted tick carries full state, not a patch.
/// The delta path controls WHEN to emit, not WHAT to emit.
@MainActor
final class AgentBroadcaster {
    let config: BroadcastConfig

    private(set) var currentInterval: TimeInterval
    private(set) var preferredTTL: UInt8
    private var tickSequence: Int

    private var suspended = false
    private var timerCancellable: AnyCancellable?
    private var lastEmitTime: Date = .distantPast

    // MARK: - Agent-supplied callbacks

    /// Called each heartbeat (and on delta triggers that pass the change gate).
    /// Return false to skip emission (e.g. precondition not met, location unknown).
    var onTick: ((BroadcastContext) -> Bool)?

    /// Called before a delta-triggered emission to ask whether the current state
    /// differs enough from the last emission to justify sending immediately.
    /// Return true to emit now. Default nil means always emit on delta trigger.
    var significantChange: (() -> Bool)?

    struct BroadcastContext {
        let batteryPct: Double
        let sequence: Int
        let ttl: UInt8
        let interval: TimeInterval
        /// True when this tick was triggered by a state change rather than the heartbeat.
        let isDeltaTrigger: Bool
    }

    init(config: BroadcastConfig) {
        self.config = config
        self.currentInterval = config.normalInterval
        self.preferredTTL = config.defaultTTL
        self.tickSequence = UserDefaults.standard.integer(forKey: config.sequenceKey)

        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }

    func start() {
        scheduleTimer(interval: config.normalInterval)
    }

    func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    // MARK: - Delta-triggered emission

    /// Call this whenever the agent observes a state change that might warrant
    /// an immediate tick (location update, medical status change, peer count jump).
    /// The broadcaster applies the significantChange gate and a minimum inter-emission
    /// gap before deciding whether to fire early.
    func triggerIfChanged() {
        guard !suspended else { return }
        let elapsed = Date().timeIntervalSince(lastEmitTime)
        guard elapsed >= config.minDeltaInterval else { return }
        if let gate = significantChange, !gate() { return }
        fire(isDelta: true)
    }

    // MARK: - Agent-tunable parameters

    func setAgentInterval(_ seconds: TimeInterval) {
        let clamped = min(max(seconds, config.minAgentInterval), config.maxAgentInterval)
        rescheduleIfNeeded(interval: clamped)
    }

    func setPreferredTTL(_ ttl: UInt8) {
        preferredTTL = min(max(ttl, 3), 7)
    }

    // MARK: - Timer

    private func scheduleTimer(interval: TimeInterval) {
        timerCancellable?.cancel()
        currentInterval = interval
        timerCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.fire(isDelta: false) }
    }

    private func rescheduleIfNeeded(interval: TimeInterval) {
        guard interval != currentInterval else { return }
        scheduleTimer(interval: interval)
    }

    // MARK: - Emission

    private func fire(isDelta: Bool) {
        guard !suspended else { return }

        #if os(iOS)
        let battery = UIDevice.current.batteryLevel
        let batteryPct = battery < 0 ? 1.0 : Double(battery)

        if battery >= 0, battery < config.batterySuspendThreshold {
            _ = emit(batteryPct: batteryPct, isDelta: false)
            suspended = true
            timerCancellable?.cancel()
            return
        }

        if !isDelta {
            let target: TimeInterval = battery >= 0 && battery < config.batteryReducedThreshold
                ? config.reducedInterval
                : config.normalInterval
            rescheduleIfNeeded(interval: target)
        }
        #else
        let batteryPct = 1.0
        #endif

        _ = emit(batteryPct: batteryPct, isDelta: isDelta)
    }

    @discardableResult
    private func emit(batteryPct: Double, isDelta: Bool) -> Bool {
        let seq = nextSequence()
        let ctx = BroadcastContext(
            batteryPct: batteryPct,
            sequence: seq,
            ttl: preferredTTL,
            interval: currentInterval,
            isDeltaTrigger: isDelta
        )
        let emitted = onTick?(ctx) ?? false
        if emitted { lastEmitTime = Date() }
        return emitted
    }

    private func nextSequence() -> Int {
        tickSequence += 1
        UserDefaults.standard.set(tickSequence, forKey: config.sequenceKey)
        return tickSequence
    }
}
