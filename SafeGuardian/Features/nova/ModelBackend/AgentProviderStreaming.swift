// AgentProviderStreaming.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import AgentInfra
import AnyLanguageModelKit
import Foundation

enum AgentProviderStreaming {
    /// Drains a LanguageModelSession stream into an AgentGenerationEvent continuation,
    /// racing the whole generation against `timeoutSeconds`. Yields .token deltas as they
    /// arrive, then .complete, or .failure on error/timeout/cancellation.
    ///
    /// `onFirstToken` fires once, before the first .token is yielded, so callers can flip
    /// an isLoading flag exactly when generation visibly starts rather than only at completion.
    /// `beforeComplete` runs only on the success path, after the last token and before
    /// .complete is yielded — the correct place to emit a `.stats` event, since
    /// AgentConversationEngine only reads accumulated stats when it processes .complete.
    static func drain(
        _ stream: LanguageModelSession.ResponseStream<String>,
        into continuation: AsyncStream<AgentGenerationEvent>.Continuation,
        timeoutSeconds: UInt64 = NovaConfig.generationTimeoutSeconds,
        onFirstToken: (@Sendable () -> Void)? = nil,
        beforeComplete: (@Sendable () -> Void)? = nil
    ) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var previous = ""
                    var firstToken = true
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        let delta = String(snapshot.content.dropFirst(previous.count))
                        previous = snapshot.content
                        if !delta.isEmpty {
                            if firstToken { firstToken = false; onFirstToken?() }
                            continuation.yield(.token(delta))
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw CancellationError()
                }
                try await group.next()
                group.cancelAll()
            }
            beforeComplete?()
            continuation.yield(.complete)
        } catch is CancellationError {
            // The task group collapses both a genuine timeout and the caller's own Task
            // being cancelled into the same CancellationError. Only the former is worth
            // reporting — a caller-initiated cancel should stop silently, matching the
            // stream's own `continuation.finish()` immediately after this returns.
            if !Task.isCancelled {
                continuation.yield(.failure("generation timed out"))
            }
        } catch {
            continuation.yield(.failure(error.localizedDescription))
        }
    }
}
