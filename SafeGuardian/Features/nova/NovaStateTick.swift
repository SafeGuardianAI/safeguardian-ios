//
//  NovaStateTick.swift
//  SafeGuardian
//
//  This is free and unencumbered software released into the public domain.
//

import Foundation

/// A single Nova behavioral state observation, corresponding to the nova.state_tick
/// ADSP atom defined in docs/protocols/schemas/nova_state_tick.schema.json.
struct NovaStateTick: Equatable {

    // MARK: - Supporting Enums

    enum LocationSource: String, Equatable {
        case gps
        case derived
        case reported
    }

    enum MedicalStatus: String, Equatable {
        case unknown
        case uninjured
        case minor
        case serious
        case critical
    }

    enum TransportTier: String, Equatable {
        // iOS uses BLE as its active transport. The schema's ble_coded label
        // aligns with Android's Coded PHY usage; iOS uses standard 1M PHY BLE.
        // When HaLow or LoRa interfaces are added, those cases will be selected.
        case ble_coded
        case halow
        case lora
        case tcp
    }

    // MARK: - Fields

    let lat: Double
    let lon: Double
    let locationConfidence: Double
    let locationSource: LocationSource
    let medicalStatus: MedicalStatus
    let structuralObservations: [String]
    let batteryPct: Double
    let transportTier: TransportTier
    let peerCount: Int
    let tickSequence: Int
    let confidenceAtEmit: Double
}
