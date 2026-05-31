import CoreLocation
import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

/// Nova-specific tick source. Owns location resolution and the published
/// latestTick observable. All timing, battery gating, TTL preference, and
/// agent-adjustable parameters live in the shared AgentBroadcaster engine.
@MainActor
final class NovaBroadcaster: ObservableObject {
    static var shared: NovaBroadcaster?

    @Published private(set) var latestTick: NovaStateTick?

    // Exposed so Nova tools can read/adjust broadcast parameters.
    let broadcaster: AgentBroadcaster

    private let peerService: UnifiedPeerService
    private let locationManager: LocationStateManager
    private var locationFixDate: Date?
    private var lastEmittedCoordinate: (lat: Double, lon: Double)?
    private var cancellables = Set<AnyCancellable>()

    private static let confidenceDecaySeconds: TimeInterval = 300

    init(peerService: UnifiedPeerService,
         locationManager: LocationStateManager = .shared) {
        self.peerService = peerService
        self.locationManager = locationManager
        self.broadcaster = AgentBroadcaster(config: .nova)
        setupLocationObserver()

        broadcaster.onTick = { [weak self] ctx in
            guard let self else { return false }
            guard let tick = self.buildTick(batteryPct: ctx.batteryPct,
                                            sequence: ctx.sequence) else { return false }
            self.latestTick = tick
            self.lastEmittedCoordinate = (tick.lat, tick.lon)
            return true
        }

        broadcaster.start()
    }

    // MARK: - Location

    private func setupLocationObserver() {
        locationManager.$currentLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                guard let self else { return }
                self.locationFixDate = location.timestamp
                broadcaster.significantChange = { [weak self] in
                    guard let self,
                          let last = self.lastEmittedCoordinate else { return true }
                    let dlat = location.coordinate.latitude  - last.lat
                    let dlon = location.coordinate.longitude - last.lon
                    let movedMeters = sqrt(dlat*dlat + dlon*dlon) * 111_320
                    guard let threshold = self.deltaThreshold(fix: location) else {
                        return true   // emergency override: distance irrelevant, fire unconditionally
                    }
                    return movedMeters > threshold
                }
                broadcaster.triggerIfChanged()
            }
            .store(in: &cancellables)
    }

    /// Dynamic displacement threshold for delta-triggered emission.
    ///
    /// Returns nil when the node is in a critical medical state — in that case the
    /// caller fires unconditionally (distance is irrelevant when position is life-critical).
    ///
    /// Otherwise returns a threshold in meters computed from three factors:
    ///
    /// GPS accuracy: the threshold floors at 1.5× the fix's horizontal accuracy so that
    /// apparent movement within measurement noise never causes a spurious emission.
    /// A poor fix (horizontalAccuracy > 100m) naturally raises the threshold.
    ///
    /// Medical urgency: serious injury halves the threshold; minor injury reduces it by 30%.
    /// The more urgent the state, the smaller the displacement needed to justify an update.
    ///
    /// Battery conservation: low battery doubles the threshold; critically low battery
    /// quintuples it. A nearly dead node should not flood the mesh with position refinements.
    private func deltaThreshold(fix: CLLocation) -> Double? {
        let medical = latestTick?.medicalStatus ?? .unknown

        // Critical state: emit on every location event regardless of displacement.
        // minDeltaInterval in AgentBroadcaster (10s for Nova) is still the rate gate.
        if medical == .critical { return nil }

        // Accuracy-based floor: movement must exceed GPS noise to be meaningful.
        // horizontalAccuracy < 0 indicates an invalid fix; treat as very poor.
        let accuracy = fix.horizontalAccuracy > 0 ? min(fix.horizontalAccuracy, 500.0) : 300.0
        var threshold = max(accuracy * 1.5, 15.0)

        // Medical urgency scaling.
        switch medical {
        case .serious:  threshold = max(accuracy, 10.0)  // near-raw accuracy, minimal filter
        case .minor:    threshold *= 0.7
        case .uninjured, .unknown, .critical: break
        }

        // Battery conservation: coarser threshold preserves both local energy and
        // mesh bandwidth that other low-battery nodes also need.
        #if os(iOS)
        let battery = UIDevice.current.batteryLevel
        if battery >= 0 {
            if battery < 0.05 { threshold *= 5.0 }
            else if battery < 0.20 { threshold *= 2.0 }
        }
        #endif

        return threshold
    }

    private func buildTick(batteryPct: Double, sequence: Int) -> NovaStateTick? {
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
            tickSequence: sequence,
            confidenceAtEmit: confidence
        )
    }

    private func resolveLocation() -> (lat: Double, lon: Double,
                                       source: NovaStateTick.LocationSource,
                                       confidence: Double) {
        if let fix = locationManager.currentLocation {
            let age = Date().timeIntervalSince(fix.timestamp)
            let confidence = max(0.0, 1.0 - age / Self.confidenceDecaySeconds)
            return (fix.coordinate.latitude, fix.coordinate.longitude, .gps, confidence)
        }
        if locationManager.teleported,
           case .location(let ch) = locationManager.selectedChannel {
            let center = Geohash.decodeCenter(ch.geohash)
            return (center.lat, center.lon, .reported, 0.5)
        }
        return (0, 0, .gps, 0)
    }
}
