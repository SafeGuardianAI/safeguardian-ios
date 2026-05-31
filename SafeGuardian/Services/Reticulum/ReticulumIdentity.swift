import BitFoundation
import CryptoKit
import Foundation

// Reticulum identity: one Ed25519 signing key and one X25519 encryption key.
// The destination hash is derived from both public keys combined with the service
// aspect tag, so each device has a stable Reticulum address that persists across
// app restarts and is independent of the Noise identity used for BLE mesh.
final class ReticulumIdentity {
    let signingPrivateKey: Curve25519.Signing.PrivateKey
    let encryptionPrivateKey: Curve25519.KeyAgreement.PrivateKey

    // 16-byte Reticulum destination address.
    let destinationHash: Data

    // PeerID wrapping the hex-encoded destination hash, compatible with the
    // existing Transport protocol surface.
    let peerID: PeerID

    private init(
        signingPrivateKey: Curve25519.Signing.PrivateKey,
        encryptionPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) {
        self.signingPrivateKey = signingPrivateKey
        self.encryptionPrivateKey = encryptionPrivateKey

        // Destination hash derivation.
        // Reticulum wire-format uses SHAKE_256; SHA256 truncated to 16 bytes is a
        // structurally identical placeholder. Swap the single hashing line below
        // when a Swift SHAKE_256 implementation is available.
        let tagData = Data(ReticulumConfig.reticulumIdentityServiceTag.utf8)
        let signPub = signingPrivateKey.publicKey.rawRepresentation
        let encPub = encryptionPrivateKey.publicKey.rawRepresentation
        var input = tagData
        input.append(signPub)
        input.append(encPub)
        let digest = SHA256.hash(data: input) // swap to SHAKE_256(input, length:16)
        self.destinationHash = Data(digest.prefix(16))
        self.peerID = PeerID(str: destinationHash.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - Lifecycle

    static func loadOrCreate(keychain: KeychainManagerProtocol) throws -> ReticulumIdentity {
        let service = ReticulumConfig.reticulumIdentityServiceTag
        // Try to load persisted keys first.
        if let signData = keychain.load(key: ReticulumConfig.reticulumIdentityServiceTag + ".signing", service: service),
           let encData = keychain.load(key: ReticulumConfig.reticulumIdentityServiceTag + ".encryption", service: service) {
            let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: signData)
            let encryption = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: encData)
            return ReticulumIdentity(signingPrivateKey: signing, encryptionPrivateKey: encryption)
        }
        // Generate new identity and persist.
        let signing = Curve25519.Signing.PrivateKey()
        let encryption = Curve25519.KeyAgreement.PrivateKey()
        keychain.save(
            key: ReticulumConfig.reticulumIdentityServiceTag + ".signing",
            data: signing.rawRepresentation,
            service: service,
            accessible: nil
        )
        keychain.save(
            key: ReticulumConfig.reticulumIdentityServiceTag + ".encryption",
            data: encryption.rawRepresentation,
            service: service,
            accessible: nil
        )
        return ReticulumIdentity(signingPrivateKey: signing, encryptionPrivateKey: encryption)
    }

    // MARK: - Cryptographic Operations

    func sign(_ data: Data) throws -> Data {
        try Data(signingPrivateKey.signature(for: data))
    }

    func sharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
        try encryptionPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }
}
