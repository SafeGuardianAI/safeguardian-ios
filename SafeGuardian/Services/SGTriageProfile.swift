import Foundation

// TriageProfile maps system-specific triage labels to the canonical 5-level
// priority vocabulary. Built-in profiles cover the doctrinal systems used by
// US/NATO military, civilian SAR, and mass-casualty EMS. A custom profile
// can be constructed from tenant.json for non-standard team vocabularies.
struct TriageProfile {
    let name: String
    let mapping: [String: MessagePriority]

    // MARK: - Built-in profiles

    static let tccc = TriageProfile(name: "tccc", mapping: [
        "T1": .immediate, "T2": .delayed, "T3": .minimal, "T4": .expectant,
    ])

    static let start = TriageProfile(name: "start", mapping: [
        "RED": .immediate, "YELLOW": .delayed, "GREEN": .minimal, "BLACK": .expectant,
    ])

    static let salt = TriageProfile(name: "salt", mapping: [
        "L1": .immediate, "L2": .delayed, "L3": .minimal, "L4": .expectant,
    ])

    static let jumpstart = TriageProfile(name: "jumpstart", mapping: [
        // Pediatric adaptation of START; same color labels, different thresholds.
        "RED": .immediate, "YELLOW": .delayed, "GREEN": .minimal, "BLACK": .expectant,
    ])

    static let medevac = TriageProfile(name: "medevac", mapping: [
        // 9-line transport urgency categories — describes evacuation priority,
        // not field triage. Maps into the canonical vocabulary for contract routing.
        "URGENT": .immediate, "URGENTSURGICAL": .immediate,
        "PRIORITY": .delayed, "ROUTINE": .minimal, "CONVENIENCE": .routine,
        "A": .immediate, "B": .delayed, "C": .minimal, "D": .routine,
    ])

    static let ics = TriageProfile(name: "ics", mapping: [
        "P1": .immediate, "P2": .delayed, "P3": .minimal, "P4": .routine,
        "IMMEDIATE": .immediate, "HIGH": .delayed, "MEDIUM": .minimal, "LOW": .routine,
    ])

    // MARK: - Lookup

    static func named(_ name: String) -> TriageProfile? {
        switch name.lowercased() {
        case "tccc":      return .tccc
        case "start":     return .start
        case "salt":      return .salt
        case "jumpstart": return .jumpstart
        case "medevac":   return .medevac
        case "ics":       return .ics
        default:          return nil
        }
    }

    static var allBuiltIn: [TriageProfile] {
        [.tccc, .start, .salt, .jumpstart, .medevac, .ics]
    }
}
