//
//  NovaBroadcaster.swift
//  SafeGuardian
//
//  This is free and unencumbered software released into the public domain.
//

import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

/// Rule-based behavioral agent that observes device and mesh state and emits
/// signed Nova StateTick atoms at a rate governed by battery policy.
///
/// Sits above the existing BLE mesh event stream without modifying it.
/// Constructed by ChatViewModel alongside UnifiedPeerService.
@MainActor
final class NovaBroadcaster: ObservableObject {

    // MARK: - Published Output

    @Published private(set) var latestTick: NovaStateTick?

    // MARK: - Private State

    private let peerService: UnifiedPeerService
    private let locationManager: LocationStateManager
    private var tickSequence: Int
    private var locationFixDate: Date?
    private var suspended: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var timerCancellable: AnyCancellable?

    // 5-minute confidence decay window, matching Android contract.
    private static let confidenceDecaySeconds: TimeInterval = 300

    // Normal and reduced-rate intervals in seconds.
    private static let normalInterval: TimeInterval = 60
    private static let reducedInterval: TimeInterval = 120

    // Battery thresholds.
    private static let reducedRateThreshold: Float = 0.20
    private static let suspendThreshold: Float = 0.05

    // UserDefaults key for persisting tick sequence across launches.
    private static let sequenceKey = "nova.tick_sequence"

    // MARK: - Initialization

    init(peerService: UnifiedPeerService,
         locationManager: LocationStateManager = .shared) {
        self.peerService = peerService
        self.locationManager = locationManager
        self.tickSequence = UserDefaults.standard.integer(forKey: Self.sequenceKey)

#if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
#endif
        setupLocationObserver()
        scheduleTimer(interval: Self.normalInterval)
    }

    // MARK: - Setup

    private func setupLocationObserver() {
        locationManager.$currentLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.locationFixDate = location.timestamp
            }
            .store(in: &cancellables)
    }

    private func scheduleTimer(interval: TimeInterval) {
        timerCancellable?.cancel()
        timerCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.emitTick()
            }
    }

    // MARK: - Tick Emission

    /// Emits a tick if the location-first guard passes.
    /// At 5% battery this will be the final emission before suspension.
    func emitTick() {
        guard !suspended else { return }

#if os(iOS)
        let battery = UIDevice.current.batteryLevel
#else
        let battery: Float = -1
#endif
        let batteryPct = battery < 0 ? 1.0 : Double(battery)

        if battery >= 0, battery < Self.suspendThreshold {
            emitBeacon(batteryPct: batteryPct)
            suspended = true
            timerCancellable?.cancel()
            return
        }

        let targetInterval: TimeInterval
        if battery >= 0, battery < Self.reducedRateThreshold {
            targetInterval = Self.reducedInterval
        } else {
            targetInterval = Self.normalInterval
        }

        // Reschedule if battery crossed into reduced-rate band.
        rescheduleIfNeeded(interval: targetInterval)

        guard let tick = buildTick(batteryPct: batteryPct) else { return }
        publish(tick)
    }

    // MARK: - Tick Construction

    private func buildTick(batteryPct: Double) -> NovaStateTick? {
        let (lat, lon, source, confidence) = resolveLocation()
        guard confidence > 0 else { return nil }

        return NovaStateTick(
            lat: lat,
            lon: lon,
            locationConfidence: confidence,
            locationSource: source,
            medicalStatus: .unknown,
            structuralObservations: [],
            batteryPct: batteryPct,
            transportTier: .ble_coded,
            peerCount: peerService.connectedPeerIDs.count,
            tickSequence: nextSequence(),
            confidenceAtEmit: confidence
        )
    }

    private func emitBeacon(batteryPct: Double) {
        guard let tick = buildTick(batteryPct: batteryPct) else { return }
        publish(tick)
    }

    // MARK: - Location Resolution

    private func resolveLocation() -> (lat: Double, lon: Double,
                                       source: NovaStateTick.LocationSource,
                                       confidence: Double) {
        if let fix = locationManager.currentLocation {
            let age = Date().timeIntervalSince(fix.timestamp)
            let confidence = max(0.0, 1.0 - age / Self.confidenceDecaySeconds)
            return (fix.coordinate.latitude, fix.coordinate.longitude, .gps, confidence)
        }

        // Teleported: user manually selected a geohash channel with no GPS fix.
        if locationManager.teleported,
           case .location(let ch) = locationManager.selectedChannel {
            let center = Geohash.decodeCenter(ch.geohash)
            return (center.lat, center.lon, .reported, 0.5)
        }

        return (0, 0, .gps, 0)
    }

    // MARK: - Helpers

    private func nextSequence() -> Int {
        tickSequence += 1
        UserDefaults.standard.set(tickSequence, forKey: Self.sequenceKey)
        return tickSequence
    }

    private func publish(_ tick: NovaStateTick) {
        latestTick = tick
    }

    private var currentInterval: TimeInterval = NovaBroadcaster.normalInterval

    private func rescheduleIfNeeded(interval: TimeInterval) {
        guard interval != currentInterval else { return }
        currentInterval = interval
        scheduleTimer(interval: interval)
    }
}
