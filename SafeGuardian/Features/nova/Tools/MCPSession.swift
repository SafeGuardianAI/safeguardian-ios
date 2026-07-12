import SafeGuardianMesh
// MCPSession.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

// MARK: - MCPToolSpec

struct MCPToolSpec: Sendable, Decodable {
    let name: String
    let description: String?
    // inputSchema kept as raw JSON for pass-through to model
    let inputSchema: MCPRawJSON?
}

// MARK: - MCPRawJSON

/// Holds arbitrary JSON as a pre-encoded Data blob.
/// Decodable from any JSON object so we do not need to know the schema shape.
struct MCPRawJSON: Sendable {
    let data: Data
}

extension MCPRawJSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(AnyCodable.self)
        data = try JSONEncoder().encode(raw)
    }
}

// MARK: - AnyCodable (private helper)

private struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self)   { value = v; return }
        if let v = try? container.decode(Int.self)    { value = v; return }
        if let v = try? container.decode(Double.self) { value = v; return }
        if let v = try? container.decode(String.self) { value = v; return }
        if let v = try? container.decode([String: AnyCodable].self) {
            value = v.mapValues { $0.value }; return
        }
        if let v = try? container.decode([AnyCodable].self) {
            value = v.map { $0.value }; return
        }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool:               try container.encode(v)
        case let v as Int:                try container.encode(v)
        case let v as Double:             try container.encode(v)
        case let v as String:             try container.encode(v)
        case let v as [String: Any]:
            try container.encode(v.mapValues { AnyCodable($0) })
        case let v as [Any]:
            try container.encode(v.map { AnyCodable($0) })
        default:                          try container.encodeNil()
        }
    }
}

// MARK: - MCPSession

/// HTTP client for a single MCP server. One session per server URL.
/// Mirrors RemoteInferenceService's URLSession pattern for consistency.
final class MCPSession: Sendable {
    let serverURL: URL
    let serverName: String

    private let session: URLSession = .shared

    init(serverURL: URL, serverName: String) {
        self.serverURL = serverURL
        self.serverName = serverName
    }

    // MARK: - Public API

    func initialize() async throws {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id(),
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "safeguardian-nova", "version": "1.0"]
            ]
        ]
        _ = try await post(body)
    }

    func listTools() async throws -> [MCPToolSpec] {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id(),
            "method": "tools/list",
            "params": [:] as [String: Any]
        ]
        let result = try await post(body)
        guard
            let resultMap = result["result"] as? [String: Any],
            let toolsArray = resultMap["tools"] as? [[String: Any]]
        else { return [] }
        let data = try JSONSerialization.data(withJSONObject: toolsArray)
        return try JSONDecoder().decode([MCPToolSpec].self, from: data)
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id(),
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
        let result = try await post(body)
        if let resultMap = result["result"] as? [String: Any],
           let content = resultMap["content"] as? [[String: Any]],
           let first = content.first,
           let text = first["text"] as? String {
            return text
        }
        if let error = result["error"] as? [String: Any] {
            return "{\"error\":\"\(error["message"] ?? "unknown")\"}"
        }
        return "{\"error\":\"unexpected_response\"}"
    }

    // MARK: - Internal

    private func id() -> String { UUID().uuidString }

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPSessionError.invalidResponse
        }
        return json
    }
}

// MARK: - MCPSessionError

enum MCPSessionError: Error {
    case invalidResponse
}
