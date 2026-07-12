import SafeGuardianMesh
import Foundation

// SGTriageEngine translates system-specific triage labels (T1, RED, L1, P1, urgent…)
// to the canonical 5-level MessagePriority vocabulary, using a configurable active
// profile. The engine also normalises MAYDAY declarations: a MAYDAY is an event
// attribute that sets priority to .immediate, not a priority level itself.
final class SGTriageEngine {

    private(set) var activeProfile: TriageProfile

    // Profiles tried in order when the active profile has no match.
    // Prevents silent .routine fallback on valid labels from adjacent systems.
    private let fallbackProfiles: [TriageProfile]

    init(profile: TriageProfile = .tccc) {
        self.activeProfile = profile
        self.fallbackProfiles = TriageProfile.allBuiltIn.filter { $0.name != profile.name }
    }

    func setProfile(_ profile: TriageProfile) {
        activeProfile = profile
    }

    // Translate a label to canonical priority. Active profile is tried first;
    // built-in profiles are tried in order before defaulting to .routine.
    func classify(_ label: String) -> MessagePriority {
        let key = label.uppercased().replacingOccurrences(of: " ", with: "")
        if let p = activeProfile.mapping[key] { return p }
        for profile in fallbackProfiles {
            if let p = profile.mapping[key] { return p }
        }
        return .routine
    }

    // Return .immediate for any recognised MAYDAY/distress declaration.
    // MAYDAY is a radio procedure, not a triage category — it triggers an
    // immediate-priority response as a consequence of the declaration.
    func classifyDeclaration(_ declaration: String) -> MessagePriority {
        let key = declaration.uppercased()
        if key.contains("MAYDAY") || key.contains("DISTRESS") || key.contains("SOS") {
            return .immediate
        }
        return classify(declaration)
    }
}
