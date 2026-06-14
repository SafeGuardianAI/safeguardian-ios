// AgentStateTick.swift
// AgentInfra
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// A single behavioral state observation from a SafeGuardian agent node.
/// Corresponds to the nova.state_tick ADSP atom schema. Provider-agnostic —
/// Nova, Trek, and any future agent use this same structure.
public struct AgentStateTick: Equatable, Sendable {

    public enum LocationSource: String, Equatable, Sendable {
        case gps, derived, reported
    }

    public enum MedicalStatus: String, Equatable, Sendable {
        case unknown, uninjured, minor, serious, critical
    }

    public enum TransportTier: String, Equatable, Sendable {
        case ble_coded, halow, lora, tcp
    }

    public let lat: Double
    public let lon: Double
    public let locationConfidence: Double
    public let locationSource: LocationSource
    public let medicalStatus: MedicalStatus
    public let structuralObservations: [String]
    public let batteryPct: Double
    public let transportTier: TransportTier
    public let peerCount: Int
    public let tickSequence: Int
    public let confidenceAtEmit: Double

    public init(
        lat: Double, lon: Double,
        locationConfidence: Double, locationSource: LocationSource,
        medicalStatus: MedicalStatus, structuralObservations: [String],
        batteryPct: Double, transportTier: TransportTier,
        peerCount: Int, tickSequence: Int, confidenceAtEmit: Double
    ) {
        self.lat = lat; self.lon = lon
        self.locationConfidence = locationConfidence; self.locationSource = locationSource
        self.medicalStatus = medicalStatus; self.structuralObservations = structuralObservations
        self.batteryPct = batteryPct; self.transportTier = transportTier
        self.peerCount = peerCount; self.tickSequence = tickSequence
        self.confidenceAtEmit = confidenceAtEmit
    }

    public var toolJSON: String {
        #"{"battery_pct":\#(Int(batteryPct*100)),"location_confidence":\#(String(format:"%.2f",locationConfidence)),"peer_count":\#(peerCount),"transport_tier":"\#(transportTier.rawValue)"}"#
    }
}
