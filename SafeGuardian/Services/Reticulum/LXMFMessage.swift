import BitFoundation
import CryptoKit
import Foundation

// LXMF (Lightweight Extensible Message Format) message framing above the Reticulum
// transport layer. An LXMF message identifies source and destination by their
// Reticulum destination hashes, carries a timestamp, optional title, UTF-8 content,
// and an Ed25519 signature over the concatenated fields.
struct LXMFMessage {
    static let hashLength = 16

    let source:      Data    // 16-byte Reticulum destination hash of the sender
    let destination: Data    // 16-byte Reticulum destination hash of the recipient
    let timestamp:   UInt64  // milliseconds since Unix epoch
    let title:       Data    // optional; empty for normal chat messages
    let content:     Data    // UTF-8 message text
    let signature:   Data    // 64-byte Ed25519 signature

    // MARK: - Serialisation

    func encode() -> Data {
        var out = Data()
        out.append(contentsOf: source.prefix(Self.hashLength))
        out.append(contentsOf: destination.prefix(Self.hashLength))
        var ts = timestamp.bigEndian
        out.append(Data(bytes: &ts, count: 8))
        var titleLen = UInt16(title.count).bigEndian
        out.append(Data(bytes: &titleLen, count: 2))
        out.append(title)
        var contentLen = UInt32(content.count).bigEndian
        out.append(Data(bytes: &contentLen, count: 4))
        out.append(content)
        out.append(contentsOf: signature.prefix(64))
        return out
    }

    static func decode(_ data: Data) -> LXMFMessage? {
        // Minimum: 16 + 16 + 8 + 2 + 4 + 64 = 110 bytes with empty title and content.
        guard data.count >= 110 else { return nil }
        var cursor = data.startIndex
        func read(_ n: Int) -> Data? {
            guard cursor + n <= data.endIndex else { return nil }
            defer { cursor += n }
            return Data(data[cursor..<(cursor + n)])
        }
        guard let src  = read(hashLength),
              let dst  = read(hashLength),
              let tsB  = read(8),
              let tlB  = read(2) else { return nil }
        let ts = UInt64(bigEndian: tsB.withUnsafeBytes { $0.load(as: UInt64.self) })
        let titleLen = Int(UInt16(bigEndian: tlB.withUnsafeBytes { $0.load(as: UInt16.self) }))
        guard let titleData = read(titleLen),
              let clB = read(4) else { return nil }
        let contentLen = Int(UInt32(bigEndian: clB.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard let contentData = read(contentLen),
              let sig = read(64) else { return nil }
        return LXMFMessage(
            source: src, destination: dst,
            timestamp: ts, title: titleData, content: contentData, signature: sig
        )
    }

    // MARK: - Construction

    // Build and sign an LXMF message from the local identity.
    static func build(
        from identity: ReticulumIdentity,
        to destination: Data,
        content: String,
        title: String = ""
    ) throws -> LXMFMessage {
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        let contentData = Data(content.utf8)
        let titleData   = Data(title.utf8)

        var toSign = Data()
        toSign.append(identity.destinationHash)
        toSign.append(destination)
        var tsBE = ts.bigEndian
        toSign.append(Data(bytes: &tsBE, count: 8))
        toSign.append(titleData)
        toSign.append(contentData)

        let sig = try identity.sign(toSign)
        return LXMFMessage(
            source: identity.destinationHash,
            destination: destination,
            timestamp: ts,
            title: titleData,
            content: contentData,
            signature: sig
        )
    }

    // MARK: - App type mapping

    func toSafeGuardianMessage(senderNickname: String) -> SafeGuardianMessage {
        let text = String(data: content, encoding: .utf8) ?? ""
        let senderPeer = PeerID(hexData: source)
        return SafeGuardianMessage(
            sender: senderNickname,
            content: text,
            timestamp: Date(timeIntervalSince1970: Double(timestamp) / 1000.0),
            isRelay: false,
            senderPeerID: senderPeer
        )
    }
}
