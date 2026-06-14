import Foundation
import Security

// SGEnvelope is the SafeGuardian-specific wire payload carried inside a bitchat packet
// with type sgEnvelope (0x30). Upstream bitchat nodes relay the containing packet via
// standard TTL flood control without decoding this payload. SafeGuardian nodes decode it
// and dispatch to the appropriate subsystem via SGEnvelopeHandler.
//
// Wire layout (35-byte fixed header + variable payload):
//   version:          1 byte  — 0x02
//   priority/source:  1 byte  — low 5 bits: MessagePriority, high 3 bits: SGSourceType
//   payloadType:      1 byte  — SGPayloadType raw value
//   tenantHash:       4 bytes — tenant hash prefix
//   messageId:       16 bytes — UUID bytes (deduplication key)
//   sourceId:         8 bytes — sender PeerID bytes
//   payloadLen:       4 bytes — big-endian UInt32
//   payload:          variable

struct SGEnvelope {
    static let currentVersion: UInt8 = 0x02
    static let headerSize = 35  // 1 + 1 + 1 + 4 + 16 + 8 + 4
    static let defaultTenantHash = Data(repeating: 0, count: 4)
    private static let priorityMask: UInt8 = 0x1F
    private static let sourceTypeShift = 5

    let priority:    MessagePriority
    let sourceType:  SGSourceType
    let payloadType: SGPayloadType
    let tenantHash:  Data  // 4 bytes
    let messageId:   Data  // 16 bytes
    let sourceId:    Data  // 8 bytes
    let payload:     Data

    // MARK: - Encode / Decode

    func encode() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(Self.currentVersion)
        out.append(Self.priorityControlByte(priority: priority, sourceType: sourceType))
        out.append(payloadType.rawValue)
        out.append(Self.fixedBytes(tenantHash, count: 4))
        out.append(Self.fixedBytes(messageId, count: 16))
        out.append(Self.fixedBytes(sourceId, count: 8))
        var lenBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lenBE) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func decode(_ data: Data) -> SGEnvelope? {
        guard data.count >= headerSize else { return nil }
        var offset = data.startIndex
        guard data[offset] == currentVersion else { return nil }; offset += 1
        let priorityControl = data[offset]; offset += 1
        guard let prio = MessagePriority(rawValue: priorityControl & priorityMask),
              let source = SGSourceType(rawValue: priorityControl >> sourceTypeShift) else { return nil }
        guard let ptype = SGPayloadType(rawValue: data[offset]) else { return nil }; offset += 1
        let tenant = Data(data[offset..<(offset + 4)]); offset += 4
        let msgId = Data(data[offset..<(offset + 16)]); offset += 16
        let srcId = Data(data[offset..<(offset + 8)]); offset += 8
        let payLen = Int(
            (UInt32(data[offset]) << 24) |
            (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) |
            UInt32(data[offset + 3])
        )
        offset += 4
        guard data.count >= offset + payLen else { return nil }
        let payload = Data(data[offset..<(offset + payLen)])
        return SGEnvelope(priority: prio, sourceType: source, payloadType: ptype,
                          tenantHash: tenant, messageId: msgId, sourceId: srcId,
                          payload: payload)
    }

    // Peek priority without full decode — used by BLEService relay path.
    // Priority is packed into the low 5 bits at byte offset 1.
    static func peekPriority(from data: Data) -> MessagePriority {
        guard data.count > 1 else { return .routine }
        return MessagePriority(rawValue: data[data.startIndex + 1] & priorityMask) ?? .routine
    }

    static func peekSourceType(from data: Data) -> SGSourceType {
        guard data.count > 1 else { return .nova }
        return SGSourceType(rawValue: data[data.startIndex + 1] >> sourceTypeShift) ?? .nova
    }

    var messageIdString: String {
        messageId.map { String(format: "%02x", $0) }.joined()
    }

    var tenantHashString: String {
        tenantHash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Factory

    static func build(priority: MessagePriority, payloadType: SGPayloadType,
                      sourceId: Data, payload: Data,
                      sourceType: SGSourceType = .nova,
                      tenantHash: Data = SGEnvelope.defaultTenantHash) -> SGEnvelope {
        var msgId = Data(count: 16)
        msgId.withUnsafeMutableBytes {
            if let base = $0.baseAddress {
                _ = SecRandomCopyBytes(kSecRandomDefault, 16, base)
            }
        }
        return SGEnvelope(priority: priority, sourceType: sourceType,
                          payloadType: payloadType, tenantHash: tenantHash,
                          messageId: msgId, sourceId: sourceId, payload: payload)
    }

    private static func priorityControlByte(priority: MessagePriority, sourceType: SGSourceType) -> UInt8 {
        ((sourceType.rawValue & 0x07) << sourceTypeShift) | (priority.rawValue & priorityMask)
    }

    private static func fixedBytes(_ data: Data, count: Int) -> Data {
        var out = Data(data.prefix(count))
        if out.count < count {
            out.append(Data(repeating: 0, count: count - out.count))
        }
        return out
    }
}

enum SGSourceType: UInt8, Sendable {
    case nova   = 0x00
    case trek   = 0x01
    case apex   = 0x02
    case radio  = 0x03
    case sensor = 0x04
    case manual = 0x05
}

enum SGPayloadType: UInt8, Sendable {
    case entity     = 0x01  // FIM entity publish
    case task       = 0x02  // Mission task create
    case triage     = 0x03  // Triage classification
    case agentMsg   = 0x04  // Agent-to-agent message
    case taskStatus = 0x05  // Task status update
}
