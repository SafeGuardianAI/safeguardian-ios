//
// PublicMessagePipelineTests.swift
// SafeGuardianTests
//
// Tests for PublicMessagePipeline ordering and deduplication.
//

import Testing
import Foundation
import BitFoundation
@testable import SafeGuardian

@MainActor
private final class TestPipelineDelegate: PublicMessagePipelineDelegate {
    private let dedupService = MessageDeduplicationService()
    var messages: [SafeGuardianMessage] = []

    func pipelineCurrentMessages(_ pipeline: PublicMessagePipeline) -> [SafeGuardianMessage] {
        messages
    }

    func pipeline(_ pipeline: PublicMessagePipeline, setMessages messages: [SafeGuardianMessage]) {
        self.messages = messages
    }

    func pipeline(_ pipeline: PublicMessagePipeline, normalizeContent content: String) -> String {
        dedupService.normalizedContentKey(content)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, contentTimestampForKey key: String) -> Date? {
        dedupService.contentTimestamp(forKey: key)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, recordContentKey key: String, timestamp: Date) {
        dedupService.recordContentKey(key, timestamp: timestamp)
    }

    func pipelineTrimMessages(_ pipeline: PublicMessagePipeline) {}

    func pipelinePrewarmMessage(_ pipeline: PublicMessagePipeline, message: SafeGuardianMessage) {}

    func pipelineSetBatchingState(_ pipeline: PublicMessagePipeline, isBatching: Bool) {}
}

struct PublicMessagePipelineTests {

    @Test @MainActor
    func flush_sortsByTimestamp() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate

        let earlier = Date().addingTimeInterval(-10)
        let later = Date()

        let messageA = SafeGuardianMessage(
            id: "a",
            sender: "A",
            content: "Later",
            timestamp: later,
            isRelay: false
        )
        let messageB = SafeGuardianMessage(
            id: "b",
            sender: "A",
            content: "Earlier",
            timestamp: earlier,
            isRelay: false
        )

        pipeline.enqueue(messageA)
        pipeline.enqueue(messageB)
        pipeline.flushIfNeeded()

        #expect(delegate.messages.map { $0.id } == ["b", "a"])
    }

    @Test @MainActor
    func flush_deduplicatesByContentWithinWindow() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate

        let now = Date()
        let messageA = SafeGuardianMessage(
            id: "a",
            sender: "A",
            content: "Same",
            timestamp: now,
            isRelay: false
        )
        let messageB = SafeGuardianMessage(
            id: "b",
            sender: "A",
            content: "Same",
            timestamp: now.addingTimeInterval(0.2),
            isRelay: false
        )

        pipeline.enqueue(messageA)
        pipeline.enqueue(messageB)
        pipeline.flushIfNeeded()

        #expect(delegate.messages.count == 1)
        #expect(delegate.messages.first?.content == "Same")
    }

    @Test @MainActor
    func lateInsert_meshAppendsRecentOlderMessage() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate
        pipeline.updateActiveChannel(.mesh)

        let base = Date()
        let newer = SafeGuardianMessage(
            id: "new",
            sender: "A",
            content: "New",
            timestamp: base,
            isRelay: false
        )
        let older = SafeGuardianMessage(
            id: "old",
            sender: "A",
            content: "Old",
            timestamp: base.addingTimeInterval(-5),
            isRelay: false
        )

        delegate.messages = [newer]
        pipeline.enqueue(older)
        pipeline.flushIfNeeded()

        #expect(delegate.messages.map { $0.id } == ["new", "old"])
    }

    @Test @MainActor
    func lateInsert_locationInsertsByTimestamp() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate
        pipeline.updateActiveChannel(.location(GeohashChannel(level: .city, geohash: "u4pruydq")))

        let base = Date()
        let newer = SafeGuardianMessage(
            id: "new",
            sender: "A",
            content: "New",
            timestamp: base,
            isRelay: false
        )
        let older = SafeGuardianMessage(
            id: "old",
            sender: "A",
            content: "Old",
            timestamp: base.addingTimeInterval(-5),
            isRelay: false
        )

        delegate.messages = [newer]
        pipeline.enqueue(older)
        pipeline.flushIfNeeded()

        #expect(delegate.messages.map { $0.id } == ["old", "new"])
    }
}
