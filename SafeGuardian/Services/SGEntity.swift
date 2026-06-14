import Foundation

// SGEntity is the canonical runtime representation of a FIM entity received
// or published over the SG mesh. The raw JSON payload is preserved for full
// field access; the structured fields cover what the SDK layer needs for
// routing, display, and priority decisions without a full FIM parse.
struct SGEntity {
    let id: String
    let entityType: String   // "incident" | "field_unit" | "contract" | "sitrep" | "activation"
    let priority: MessagePriority
    let timestamp: Date
    let sourceId: String
    let rawJSON: Data        // full FIM-compatible field set as JSON
    var version: Int         // increments on each update; higher version wins on merge
}

// Wire payload carried inside an SGEnvelope with payloadType = .entity.
// Encoding: JSON.
struct SGEntityPayload: Codable {
    let id: String
    let entityType: String
    let priority: UInt8      // MessagePriority raw value
    let timestamp: TimeInterval
    let sourceId: String
    let version: Int
    let fields: [String: SGFieldValue]

    func toEntity() -> SGEntity? {
        guard let prio = MessagePriority(rawValue: priority) else { return nil }
        let fieldsJSON = (try? JSONEncoder().encode(fields)) ?? Data()
        return SGEntity(
            id: id,
            entityType: entityType,
            priority: prio,
            timestamp: Date(timeIntervalSince1970: timestamp),
            sourceId: sourceId,
            rawJSON: fieldsJSON,
            version: version
        )
    }
}

// JSON-safe field value that covers the types FIM entities carry.
enum SGFieldValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let n = try? c.decode(Double.self)  { self = .number(n); return }
        if let b = try? c.decode(Bool.self)    { self = .bool(b);   return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .null:          try c.encodeNil()
        }
    }
}
