import BitFoundation
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

    // MARK: - Tenant config factory

    // Reads `triage_profile` from tenant.json-style config dict, defaulting to .tccc.
    // If value is "custom", reads `triage_mapping` as [String: String] and builds
    // a TriageProfile with canonical priority values.
    static func fromTenantConfig(_ config: [String: Any]) -> TriageProfile {
        let profileName = config["triage_profile"] as? String ?? "tccc"
        if let builtin = named(profileName) { return builtin }
        if profileName == "custom",
           let raw = config["triage_mapping"] as? [String: String] {
            let mapping = raw.compactMapValues { priorityFromCanonicalString($0) }
            return TriageProfile(name: "custom", mapping: mapping)
        }
        return .tccc
    }

    // Reads `sg.triage_profile` from UserDefaults for app-launch initialization.
    static func fromUserDefaults() -> TriageProfile {
        let stored = UserDefaults.standard.string(forKey: "sg.triage_profile") ?? "tccc"
        return named(stored) ?? .tccc
    }
}

private func priorityFromCanonicalString(_ s: String) -> MessagePriority? {
    switch s.lowercased() {
    case "immediate": return .immediate
    case "delayed":   return .delayed
    case "minimal":   return .minimal
    case "expectant": return .expectant
    case "routine":   return .routine
    default:          return nil
    }
}
