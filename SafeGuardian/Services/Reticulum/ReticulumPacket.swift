import CryptoKit
import Foundation

// Reticulum wire-format types.
//
// Two-byte header layout:
//   Byte 0: [ifac:1][headerType:1][context:4][propagation:2]
//   Byte 1: [destinationType:2][packetType:2][hops:4]
//
// After the header: optional 16-byte IFAC key (when ifac=1), then 16-byte
// destination hash (for non-link packets), optional 16-byte transport ID
// (when headerType=1), 1-byte context field, then variable-length data.

enum PropagationType: UInt8 {
    case broadcast = 0
    case transport = 1
    case relay     = 2
    case tunnel    = 3
}

enum DestinationType: UInt8 {
    case single = 0
    case group  = 1
    case plain  = 2
    case link   = 3
}

enum PacketType: UInt8 {
    case data        = 0
    case announce    = 1
    case linkRequest = 2
    case proof       = 3
}

// MARK: - Header

struct ReticulumPacketHeader {
    var ifac: Bool
    var headerType: UInt8          // 0 = no transport ID, 1 = transport ID present
    var contextFlags: UInt8        // 4 bits
    var propagation: PropagationType
    var destinationType: DestinationType
    var packetType: PacketType
    var hops: UInt8                // 4 bits

    func encode() -> Data {
        let b0: UInt8 = (ifac ? 0x80 : 0x00)
            | ((headerType & 0x01) << 6)
            | ((contextFlags & 0x0F) << 2)
            | (propagation.rawValue & 0x03)
        let b1: UInt8 = ((destinationType.rawValue & 0x03) << 6)
            | ((packetType.rawValue & 0x03) << 4)
            | (hops & 0x0F)
        return Data([b0, b1])
    }
}

extension ReticulumPacketHeader {
    init?(data: Data) {
        guard data.count >= 2 else { return nil }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        guard let prop = PropagationType(rawValue: b0 & 0x03),
              let dst  = DestinationType(rawValue: (b1 >> 6) & 0x03),
              let pkt  = PacketType(rawValue: (b1 >> 4) & 0x03) else { return nil }

        self.init(
            ifac: (b0 & 0x80) != 0,
            headerType: (b0 >> 6) & 0x01,
            contextFlags: (b0 >> 2) & 0x0F,
            propagation: prop,
            destinationType: dst,
            packetType: pkt,
            hops: b1 & 0x0F
        )
    }
}

// MARK: - Announce

struct ReticulumAnnounce {
    static let randomHashLength = 10
    static let signatureLength  = 64
    static let hashLength       = 16
    static let publicKeyLength  = 32

    let destinationHash:   Data  // 16 bytes
    let signingPublicKey:  Data  // 32 bytes
    let encryptionPublicKey: Data // 32 bytes
    let appData:           Data  // variable
    let randomHash:        Data  // 10 bytes
    let signature:         Data  // 64 bytes

    func encode() -> Data {
        var out = Data()
        out.append(contentsOf: destinationHash.prefix(Self.hashLength))
        out.append(contentsOf: signingPublicKey.prefix(Self.publicKeyLength))
        out.append(contentsOf: encryptionPublicKey.prefix(Self.publicKeyLength))
        out.append(contentsOf: appData)
        out.append(contentsOf: randomHash.prefix(Self.randomHashLength))
        out.append(contentsOf: signature.prefix(Self.signatureLength))
        return out
    }

    static func decode(_ data: Data) -> ReticulumAnnounce? {
        let minLen = hashLength + publicKeyLength + publicKeyLength + randomHashLength + signatureLength
        guard data.count >= minLen else { return nil }
        var offset = data.startIndex
        let dest   = data[offset..<(offset + hashLength)];      offset += hashLength
        let sign   = data[offset..<(offset + publicKeyLength)]; offset += publicKeyLength
        let enc    = data[offset..<(offset + publicKeyLength)]; offset += publicKeyLength
        let appEnd = data.endIndex - randomHashLength - signatureLength
        let app    = data[offset..<appEnd];                     offset = appEnd
        let rnd    = data[offset..<(offset + randomHashLength)]; offset += randomHashLength
        let sig    = data[offset..<(offset + signatureLength)]
        return ReticulumAnnounce(
            destinationHash: Data(dest),
            signingPublicKey: Data(sign),
            encryptionPublicKey: Data(enc),
            appData: Data(app),
            randomHash: Data(rnd),
            signature: Data(sig)
        )
    }

    // Build a signed announce for the local identity.
    static func build(identity: ReticulumIdentity, appData: Data = Data()) throws -> ReticulumAnnounce {
        var randomHash = Data(count: randomHashLength)
        randomHash.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, randomHashLength, $0.baseAddress!) }

        let signPub = identity.signingPrivateKey.publicKey.rawRepresentation
        let encPub  = identity.encryptionPrivateKey.publicKey.rawRepresentation
        var toSign = Data()
        toSign.append(identity.destinationHash)
        toSign.append(signPub)
        toSign.append(encPub)
        toSign.append(appData)
        toSign.append(randomHash)

        let sig = try identity.sign(toSign)
        return ReticulumAnnounce(
            destinationHash: identity.destinationHash,
            signingPublicKey: signPub,
            encryptionPublicKey: encPub,
            appData: appData,
            randomHash: randomHash,
            signature: sig
        )
    }
}

// MARK: - Data Packet

struct ReticulumDataPacket {
    let header:          ReticulumPacketHeader
    let destinationHash: Data   // 16 bytes
    let context:         UInt8
    let payload:         Data

    func encode() -> Data {
        var out = header.encode()
        out.append(contentsOf: destinationHash.prefix(ReticulumAnnounce.hashLength))
        out.append(context)
        out.append(payload)
        return out
    }

    static func decode(_ data: Data) -> ReticulumDataPacket? {
        guard let header = ReticulumPacketHeader(data: data), data.count >= 2 + 16 + 1 else { return nil }
        let base = data.startIndex + 2
        let hashEnd = base + ReticulumAnnounce.hashLength
        let dest = data[base..<hashEnd]
        let ctx  = data[hashEnd]
        let payload = data[(hashEnd + 1)...]
        return ReticulumDataPacket(
            header: header,
            destinationHash: Data(dest),
            context: ctx,
            payload: Data(payload)
        )
    }

    // Convenience: build a broadcast DATA packet carrying an LXMF payload.
    static func broadcast(payload: Data, identity: ReticulumIdentity) -> ReticulumDataPacket {
        let header = ReticulumPacketHeader(
            ifac: false, headerType: 0, contextFlags: 0,
            propagation: .broadcast,
            destinationType: .single,
            packetType: .data, hops: 0
        )
        // Broadcast destination: all-zeros hash by convention.
        return ReticulumDataPacket(
            header: header,
            destinationHash: Data(repeating: 0, count: 16),
            context: 0,
            payload: payload
        )
    }

    // Convenience: build a directed DATA packet to a known destination hash.
    static func directed(to destinationHash: Data, payload: Data) -> ReticulumDataPacket {
        let header = ReticulumPacketHeader(
            ifac: false, headerType: 0, contextFlags: 0,
            propagation: .transport,
            destinationType: .single,
            packetType: .data, hops: 0
        )
        return ReticulumDataPacket(
            header: header,
            destinationHash: destinationHash,
            context: 0,
            payload: payload
        )
    }
}
