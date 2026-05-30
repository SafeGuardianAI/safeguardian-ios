import Testing
import Foundation
import BitFoundation
@testable import SafeGuardian

// Minimal stub satisfying AgentLanguageProvider without touching Metal or MLX.
// Used by any test that exercises the agent routing layer without needing real inference.
@MainActor
private final class StubLanguageProvider: AgentLanguageProvider {
    let id = "stub"
    let displayName = "Stub"
    let activeModelID = "stub-model"
    var capabilities = AgentProviderCapabilities(requiresNetwork: false, modelCapabilities: nil)
    var isLoading = false
    var isModelLoaded = true
    func generate(input: AgentPromptInput) -> AsyncStream<AgentGenerationEvent> {
        AsyncStream { c in c.yield(.complete); c.finish() }
    }
    func cancel() {}
}

@Suite(.serialized)
@MainActor
struct AgentRoutingTests {

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

        AgentProviderRegistry.shared.setActiveProvider(StubLanguageProvider())

        return (viewModel, transport)
    }

    @Test
    func agentTrigger_interceptsPromptAndCreatesMessages() async {
        let (viewModel, _) = makeTestableViewModel()
        let prompt = "hello nova"

        viewModel.sendMessage("@nova \(prompt)")

        let peerID = Agent.nova.peerID
        let messages = viewModel.privateChats[peerID]

        // User turn + response placeholder; loading message absent because stub reports isModelLoaded = true.
        #expect((messages?.count ?? 0) >= 2)
        let userTurn = messages?.first { $0.sender != "local" && $0.sender != Agent.nova.displayName }
        #expect(userTurn?.content == prompt)

        // Placeholder is injected synchronously by AgentConversationEngine before any Task fires.
        let response = messages?.last
        #expect(response?.sender == Agent.nova.displayName)
        #expect(response?.content.contains("thinking") == true)
    }

    @Test
    func agentTrigger_createsPrivateChatThread() async {
        let (viewModel, _) = makeTestableViewModel()

        viewModel.sendMessage("@nova test")

        #expect(viewModel.privateChats[Agent.nova.peerID] != nil)
    }
}
