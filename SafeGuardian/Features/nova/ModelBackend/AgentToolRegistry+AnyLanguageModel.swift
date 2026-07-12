import AgentInfra
import AnyLanguageModelKit
import Foundation

/// Bridges one AgentToolEntry (via the registry's spec + unified dispatch closure)
/// into an AnyLanguageModel Tool. Arguments are kept dynamic (raw JSON) instead of
/// per-tool @Generable structs, since AgentToolRegistry already owns typed decoding
/// via each entry's handler closure.
struct AgentDynamicTool: AnyLanguageModelKit.Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let invoke: @Sendable (GeneratedContent) async throws -> String

    func call(arguments: GeneratedContent) async throws -> String {
        try await invoke(arguments)
    }
}

extension AgentToolRegistry {
    /// Converts this registry's tool specs into AnyLanguageModel tools, routing
    /// every call back through the registry's single `dispatch` closure so the
    /// iteration guard, approval gate, status callback, and MCP routing stay
    /// centralized regardless of which provider is calling.
    func asLanguageModelTools() -> [any AnyLanguageModelKit.Tool] {
        let dispatch = self.dispatch
        return specs.compactMap { spec in
            guard let fn = spec["function"] as? [String: any Sendable],
                  let name = fn["name"] as? String,
                  let description = fn["description"] as? String,
                  let schema = try? Self.generationSchema(for: fn, name: name)
            else { return nil }
            return AgentDynamicTool(name: name, description: description, parameters: schema) { args in
                let values = Self.jsonValues(from: args)
                let call = ToolCall(function: .init(name: name, arguments: values))
                return (try? await dispatch(call)) ?? #"{"error":"tool_failed"}"#
            }
        }
    }

    private static func generationSchema(for fn: [String: any Sendable], name: String) throws -> GenerationSchema {
        let params = fn["parameters"] as? [String: any Sendable]
        let properties = params?["properties"] as? [String: [String: any Sendable]] ?? [:]
        let required = Set(params?["required"] as? [String] ?? [])
        let fields = properties.map { key, prop -> DynamicGenerationSchema.Property in
            .init(
                name: key,
                description: prop["description"] as? String,
                schema: dynamicSchema(for: prop),
                isOptional: !required.contains(key)
            )
        }
        let root = DynamicGenerationSchema(name: name, properties: fields)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func dynamicSchema(for prop: [String: any Sendable]) -> DynamicGenerationSchema {
        if let items = prop["items"] as? [String: any Sendable] {
            return DynamicGenerationSchema(arrayOf: dynamicSchema(for: items))
        }
        switch prop["type"] as? String {
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: return DynamicGenerationSchema(type: String.self)
        }
    }

    /// Parses a tool call's raw JSON arguments into our provider-agnostic JSONValue map.
    private static func jsonValues(from content: GeneratedContent) -> [String: AgentInfra.JSONValue] {
        guard let data = content.jsonString.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: AgentInfra.JSONValue].self, from: data)
        else { return [:] }
        return values
    }
}
