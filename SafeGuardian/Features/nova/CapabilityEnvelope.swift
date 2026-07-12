import SafeGuardianMesh
// CapabilityEnvelope.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Transport-agnostic wrapper for a JSON-RPC 2.0 MCP call or reply.
/// The mcpBody field carries the raw JSON-RPC bytes. Transport metadata
/// (who sent it, over what path, when it expires) travels alongside so
/// the receiver can enforce authority and TTL without parsing the body.
struct CapabilityEnvelope: Codable, Sendable {
    let requestID: String
    let callerAgentID: String
    let targetAgentID: String
    /// "http" or "ble_mesh"
    let transport: String
    let expiresAt: Date?
    /// Raw JSON-RPC 2.0 bytes (initialize / tools/list / tools/call / result)
    let mcpBody: Data

    init(
        requestID: String = UUID().uuidString,
        callerAgentID: String,
        targetAgentID: String,
        transport: String,
        expiresAt: Date? = nil,
        mcpBody: Data
    ) {
        self.requestID = requestID
        self.callerAgentID = callerAgentID
        self.targetAgentID = targetAgentID
        self.transport = transport
        self.expiresAt = expiresAt
        self.mcpBody = mcpBody
    }
}
