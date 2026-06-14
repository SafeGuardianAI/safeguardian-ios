// AgentLanguageProvider.swift
// AgentInfra
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// The inference backend protocol. Any provider — local MLX, remote Ollama,
/// Apple Foundation Models, or a test stub — implements this and plugs into
/// AgentProviderRegistry. Nova, Trek, and any future agent share this contract.
@MainActor
public protocol AgentLanguageProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var activeModelID: String { get }
    var capabilities: AgentProviderCapabilities { get }
    var isLoading: Bool { get }
    var isModelLoaded: Bool { get }
    func generate(input: AgentPromptInput) -> AsyncStream<AgentGenerationEvent>
    func cancel()
}
