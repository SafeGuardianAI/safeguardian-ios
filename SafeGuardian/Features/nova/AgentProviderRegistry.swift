import Foundation

@Observable @MainActor
final class AgentProviderRegistry {
    static let shared = AgentProviderRegistry()

    private static let providerKey = "nova.activeProviderID"

    private(set) var activeProvider: any AgentLanguageProvider

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.providerKey)
        activeProvider = saved == "remote" ? RemoteInferenceService.shared : MLXInferenceService.shared
    }

    func setActiveProvider(_ provider: any AgentLanguageProvider) {
        activeProvider = provider
        UserDefaults.standard.set(provider.id, forKey: Self.providerKey)
    }
}
