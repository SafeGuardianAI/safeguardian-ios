import Foundation
import Testing
@testable import SafeGuardian

struct SGEnvelopeTests {
    @Test
    func encodeDecode_usesTenantHashAndPackedPrioritySourceType() throws {
        let tenant = Data([0x12, 0x34, 0x56, 0x78])
        let messageId = Data((0x00...0x0F).map { UInt8($0) })
        let sourceId = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11])
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let expectedControl = (SGSourceType.apex.rawValue << 5) | MessagePriority.delayed.rawValue
        let envelope = SGEnvelope(
            priority: .delayed,
            sourceType: .apex,
            payloadType: .task,
            tenantHash: tenant,
            messageId: messageId,
            sourceId: sourceId,
            payload: payload
        )

        let encoded = envelope.encode()

        #expect(encoded.count == SGEnvelope.headerSize + payload.count)
        #expect(encoded[0] == SGEnvelope.currentVersion)
        #expect(encoded[1] == expectedControl)
        #expect(encoded[2] == SGPayloadType.task.rawValue)
        #expect(Data(encoded[3..<7]) == tenant)
        #expect(Data(encoded[7..<23]) == messageId)
        #expect(Data(encoded[23..<31]) == sourceId)
        #expect(Data(encoded[31..<35]) == Data([0x00, 0x00, 0x00, 0x04]))
        #expect(Data(encoded[35..<39]) == payload)
        #expect(SGEnvelope.peekPriority(from: encoded) == .delayed)
        #expect(SGEnvelope.peekSourceType(from: encoded) == .apex)

        let decoded = try #require(SGEnvelope.decode(encoded))
        #expect(decoded.priority == .delayed)
        #expect(decoded.sourceType == .apex)
        #expect(decoded.payloadType == .task)
        #expect(decoded.tenantHash == tenant)
        #expect(decoded.messageId == messageId)
        #expect(decoded.sourceId == sourceId)
        #expect(decoded.payload == payload)
    }

    @Test
    func decode_rejectsLegacyVersionOneHeader() {
        var legacy = Data(repeating: 0, count: 31)
        legacy[0] = 0x01
        legacy[1] = MessagePriority.routine.rawValue
        legacy[2] = SGPayloadType.agentMsg.rawValue

        #expect(SGEnvelope.decode(legacy) == nil)
    }
}
