import Foundation
import MLXLMCommon

@MainActor final class MLXSessionPool {
    struct Key: Hashable {
        let modelID: String
        let promptHash: Int
        /// Offset of the oldest turn in the current history window.
        let historyOffset: Int
        /// Thread identifier. Each conversation thread gets its own ChatSession
        /// so KV caches from different threads never mix.
        let threadID: String
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
