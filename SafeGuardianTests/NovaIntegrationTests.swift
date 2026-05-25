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
        
        let novaPeerID = ChatViewModel.novaPeerID
        let messages = viewModel.privateChats[novaPeerID]
        print("Nova messages count: \(messages?.count ?? 0)")
        
        #expect(messages?.count == 2)
        #expect(messages?.first?.content == prompt)
        
        // Check response placeholder created
        let response = messages?.last
        #expect(response?.sender == novaPeerID.id)
        #expect(response?.content == "[thinking…]")
        
        // Check projection updated
        #expect(viewModel.messages.contains { $0 === response })
    }

    @Test
    func routeToNova_handlesLoadingState() async {
        let (viewModel, _) = makeTestableViewModel()
        
        // We can't easily force isLoading on the real shared MLXInferenceService
        // but we can check if it routes at least.
        
        viewModel.sendMessage("@nova test")
        
        let novaPeerID = ChatViewModel.novaPeerID
        #expect(viewModel.privateChats[novaPeerID] != nil)
    }
}
