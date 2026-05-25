import BitFoundation
import Foundation

extension ChatViewModel {
    static let novaPeerID = PeerID(str: "nova-local")
    static let novaSystemPrompt =
        "You are Nova, a concise on-device AI assistant embedded in SafeGuardian, a disaster-response mesh communication app. Keep responses brief."

    @MainActor
    func routeToNova(_ prompt: String) {
        let service = MLXInferenceService.shared

        if service.isLoading {
            addLocalMessage("nova is loading the model, please wait…")
            return
        }

        // Record the user turn in the Nova DM thread
        let userMsg = SafeGuardianMessage(
            sender: "local", content: prompt, timestamp: Date(), isRelay: false)
        if privateChats[Self.novaPeerID] == nil {
            privateChats[Self.novaPeerID] = []
        }
        privateChats[Self.novaPeerID]?.append(userMsg)

        // Placeholder for the streaming response
        let response = SafeGuardianMessage(
            sender: Self.novaPeerID.id, content: "", timestamp: Date(), isRelay: false)
        privateChats[Self.novaPeerID]?.append(response)
        messages.append(response)
        objectWillChange.send()

        service.generate(
            systemPrompt: Self.novaSystemPrompt,
            userMessage: prompt
        ) { [weak response, weak self] token in
            guard let response, let self else { return }
            response.content += token
            self.objectWillChange.send()
        } onComplete: { [weak self] in
            self?.objectWillChange.send()
        }
    }
}
