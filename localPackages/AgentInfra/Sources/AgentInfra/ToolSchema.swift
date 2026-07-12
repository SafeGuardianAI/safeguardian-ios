// ToolSchema.swift
// AgentInfra
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Provider-agnostic JSON value, used for untyped tool call arguments.
public enum JSONValue: Sendable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        case .null: return NSNull()
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// A JSON-schema-shaped tool parameter type, mirroring OpenAI function-calling schemas.
public indirect enum ToolParameterType: Sendable {
    case string
    case int
    case double
    case bool
    case array(elementType: ToolParameterType)
    case object

    var jsonSchema: [String: any Sendable] {
        switch self {
        case .string: return ["type": "string"]
        case .int: return ["type": "integer"]
        case .double: return ["type": "number"]
        case .bool: return ["type": "boolean"]
        case .array(let element): return ["type": "array", "items": element.jsonSchema]
        case .object: return ["type": "object"]
        }
    }
}

/// A single named tool parameter. Build a tool's schema from an array of these.
public struct ToolParameter: Sendable {
    public let name: String
    public let type: ToolParameterType
    public let description: String
    public let isRequired: Bool

    public static func required(_ name: String, type: ToolParameterType, description: String) -> ToolParameter {
        ToolParameter(name: name, type: type, description: description, isRequired: true)
    }

    public static func optional(_ name: String, type: ToolParameterType, description: String) -> ToolParameter {
        ToolParameter(name: name, type: type, description: description, isRequired: false)
    }
}

/// OpenAI-format function-calling tool spec, as a JSON-serializable dictionary.
public typealias ToolSpec = [String: any Sendable]

public func makeToolSpec(name: String, description: String, parameters: [ToolParameter]) -> ToolSpec {
    var properties: [String: any Sendable] = [:]
    var required: [String] = []
    for p in parameters {
        properties[p.name] = p.type.jsonSchema.merging(["description": p.description]) { _, new in new }
        if p.isRequired { required.append(p.name) }
    }
    return [
        "type": "function",
        "function": [
            "name": name,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": required,
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]
}

/// A tool call requested by the model, provider-agnostic.
public struct ToolCall: Sendable {
    public struct Function: Sendable {
        public let name: String
        public let arguments: [String: JSONValue]
        public init(name: String, arguments: [String: JSONValue]) {
            self.name = name
            self.arguments = arguments
        }
    }
    public let function: Function
    public init(function: Function) {
        self.function = function
    }
}
