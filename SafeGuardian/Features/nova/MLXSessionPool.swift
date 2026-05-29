import Foundation
import MLXLMCommon

@MainActor final class MLXSessionPool {
    struct Key: Hashable {
        let modelID: String
        let promptHash: Int
    }

    private var sessions: [Key: ChatSession] = [:]

    func session(for key: Key, container: ModelContainer, systemPrompt: String) -> ChatSession {
        if let existing = sessions[key] { return existing }
        let s = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: GenerateParameters(temperature: NovaConfig.temperature)
        )
        sessions[key] = s
        return s
    }

    func invalidate(key: Key) {
        sessions.removeValue(forKey: key)
    }

    func invalidateAll() {
        sessions.removeAll()
    }
}
