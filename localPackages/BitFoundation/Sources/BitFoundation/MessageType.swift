//
// MessageType.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

/// Simplified BitChat protocol message types.
/// Reduced from 24 types to just 6 essential ones.
/// All private communication metadata (receipts, status) is embedded in noiseEncrypted payloads.
public enum MessageType: UInt8 {
    // Public messages (unencrypted)
    case announce = 0x01        // "I'm here" with nickname
    case message = 0x02         // Public chat message  
    case leave = 0x03           // "I'm leaving"
    case requestSync = 0x21     // GCS filter-based sync request (local-only)
    
    // Noise encryption
    case noiseHandshake = 0x10  // Handshake (init or response determined by payload)
    case noiseEncrypted = 0x11  // All encrypted payloads (messages, receipts, etc.)
    
    // Fragmentation (simplified)
    case fragment = 0x20        // Single fragment type for large messages
    case fileTransfer = 0x22    // Binary file/audio/image payloads

    // SafeGuardian-specific extension (0x30+).
    // Unknown to upstream bitchat nodes; they relay via standard TTL flood without decoding.
    case sgEnvelope   = 0x30    // SG entity / task / triage / agent payload
    case relayBeacon  = 0x31    // relay → peers: uptime, free heap, peer count
    case relayPing    = 0x32    // peer → relay: request immediate beacon
    
    public var description: String {
        switch self {
        case .announce: return "announce"
        case .message: return "message"
        case .leave: return "leave"
        case .requestSync: return "requestSync"
        case .noiseHandshake: return "noiseHandshake"
        case .noiseEncrypted: return "noiseEncrypted"
        case .fragment: return "fragment"
        case .fileTransfer: return "fileTransfer"
        case .sgEnvelope: return "sgEnvelope"
        case .relayBeacon: return "relayBeacon"
        case .relayPing: return "relayPing"
        }
    }
}
