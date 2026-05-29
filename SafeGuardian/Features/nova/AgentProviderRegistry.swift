import Foundation

@Observable @MainActor
final class AgentProviderRegistry {
    static let shared = AgentProviderRegistry()

    private(set) var activeProvider: any AgentLanguageProvider

    private init() {
        activeProvider = MLXInferenceService.shared
    }

    func setActiveProvider(_ provider: any AgentLanguageProvider) {
        activeProvider = provider
    }
}
