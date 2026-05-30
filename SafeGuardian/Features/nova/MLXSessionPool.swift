import Foundation
import MLXLMCommon

@MainActor final class MLXSessionPool {
    struct Key: Hashable {
        let modelID: String
        let promptHash: Int
        /// Offset of the oldest turn in the current history window.
        /// Increments each time the window slides past historyWindowSize turns.
        /// A change in this value means the existing session must be discarded
        /// and a new one seeded from the incoming windowed history.
        let historyOffset: Int
    }

    private var sessions: [Key: ChatSession] = [:]

    func session(
        for key: Key,
        container: ModelContainer,
        systemPrompt: String,
        history: [Chat.Message] = [],
        toolRegistry: AgentToolRegistry? = nil
    ) -> ChatSession {
        if let existing = sessions[key] { return existing }
        let s: ChatSession
        if history.isEmpty {
            s = ChatSession(
                container,
                instructions: systemPrompt,
                generateParameters: GenerateParameters(temperature: NovaConfig.temperature),
                tools: toolRegistry?.specs,
                toolDispatch: toolRegistry?.dispatch
            )
        } else {
            s = ChatSession(
                container,
                instructions: systemPrompt,
                history: history,
                generateParameters: GenerateParameters(temperature: NovaConfig.temperature),
                tools: toolRegistry?.specs,
                toolDispatch: toolRegistry?.dispatch
            )
        }
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
