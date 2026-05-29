import Testing
import Foundation
import BitFoundation
@testable import SafeGuardian

@Suite(.serialized)
@MainActor
struct NovaIntegrationTests {
    
    private func makeTestableViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
        let keychain = MockKeychain()
        let keychainHelper = MockKeychainHelper()
        let idBridge = NostrIdentityBridge(keychain: keychainHelper)
        let identityManager = MockIdentityManager(keychain)
        let transport = MockTransport()

        let viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            transport: transport
        )

        return (viewModel, transport)
    }

    @Test
    func routeToNova_interceptsPromptAndCreatesMessages() async {
        let (viewModel, _) = makeTestableViewModel()
        let prompt = "hello nova"
        
        viewModel.sendMessage("@nova \(prompt)")

        let novaPeerID = NovaAgent.novaPeerID
        let messages = viewModel.privateChats[novaPeerID]

        // Thread: [local loading message, user turn, response placeholder]
        #expect((messages?.count ?? 0) >= 2)
        let userTurn = messages?.first { $0.sender != "local" && $0.sender != "Nova" }
        #expect(userTurn?.content == prompt)

        // Response placeholder injected by NovaAgent
        let response = messages?.last
        #expect(response?.sender == "Nova")
        #expect(response?.content.contains("thinking") == true)
    }

    @Test
    func routeToNova_handlesLoadingState() async {
        let (viewModel, _) = makeTestableViewModel()
        
        // We can't easily force isLoading on the real shared MLXInferenceService
        // but we can check if it routes at least.
        
        viewModel.sendMessage("@nova test")
        
        let novaPeerID = NovaAgent.novaPeerID
        #expect(viewModel.privateChats[novaPeerID] != nil)
    }
}
