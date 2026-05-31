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
                // Delta trigger: emit immediately when position moves > 50m
                // from the last emitted coordinate, subject to minDeltaInterval.
                broadcaster.significantChange = { [weak self] in
                    guard let self,
                          let last = self.lastEmittedCoordinate else { return true }
                    let dlat = location.coordinate.latitude  - last.lat
                    let dlon = location.coordinate.longitude - last.lon
                    let approxMeters = sqrt(dlat*dlat + dlon*dlon) * 111_320
                    return approxMeters > 50
                }
                broadcaster.triggerIfChanged()
            }
            .store(in: &cancellables)
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
