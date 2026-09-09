import AgentRuntime
import Foundation

/// On-device only, deliberately: SafeGuardian's whole premise is working without
/// internet infrastructure, so a remote inference provider doesn't belong in the
/// picture here. This still exists as a thin wrapper — rather than call
/// MLXInferenceService.shared directly everywhere — so AgentConversationEngine and
/// the settings UI stay decoupled from the concrete provider type, matching how
/// per-model differences already flow through the generic AgentLanguageProvider
/// surface instead of a provider-specific one.
@Observable @MainActor
final class AgentProviderRegistry {
    static let shared = AgentProviderRegistry()

    let activeProvider: any AgentLanguageProvider = MLXInferenceService.shared

    private init() {}
}
