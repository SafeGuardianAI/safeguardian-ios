import Foundation

@Observable @MainActor
final class NovaProviderRegistry {
    static let shared = NovaProviderRegistry()

    private(set) var activeProvider: any NovaLanguageProvider

    private init() {
        activeProvider = MLXInferenceService.shared
    }

    func setActiveProvider(_ provider: any NovaLanguageProvider) {
        activeProvider = provider
    }
}
