# Optional Identity Persistence and Verification

The existing system already implements most of what is needed. The three-layer identity model in
IdentityModels.swift separates ephemeral peer IDs (rotating, network-private) from cryptographic
identity (stable Noise static key, fingerprint = SHA256 of that key) from social identity (local
petnames, trust levels, all encrypted in Keychain). The QR verification already creates a signed
binding of nickname + Noise public key + signing public key + optional Nostr npub, confirmed via a
challenge-response over the established Noise channel. SecureIdentityStateManager stores verified
fingerprints encrypted at rest with user-controlled optional persistence.

The anonymity-by-default property is preserved throughout: none of the extensions below activate
without explicit user action. The default path through the app is unchanged.

---

## Gap 1: Identity cards over the mesh without QR proximity

The QR flow requires two devices to be physically co-located. But two peers who have an established
Noise session are already mutually authenticated — each has the other's signing public key from the
announce signature, and the Noise handshake has proven control of the static key. What is missing is
a message that delivers the full QR payload (nickname + noise key + signing key + Ed25519 signature)
through the Noise-encrypted channel rather than through a camera. This is a NoisePayloadType
addition.

```swift
// SafeGuardian/Protocols/SafeGuardianProtocol.swift — add one case
enum NoisePayloadType: UInt8 {
    case privateMessage  = 0x01
    case readReceipt     = 0x02
    case delivered       = 0x03
    case verifyChallenge = 0x10
    case verifyResponse  = 0x11
    case identityCard    = 0x12   // full VerificationQR payload delivered over Noise channel
}
```

```swift
// SafeGuardian/Services/VerificationService.swift — add two methods

func buildIdentityCard(nickname: String, npub: String?) -> Data? {
    // Same logic as buildMyQRString but TLV-encoded rather than URL-encoded
    // [0x01 len noiseKeyHex] [0x02 len signKeyHex] [0x03 len nickname]
    // [0x04 len npub_or_empty] [0x05 8 ts_u64_be] [0x06 16 nonce] [0x07 64 sig]
    guard let qrString = buildMyQRString(nickname: nickname, npub: npub),
          let url = URL(string: qrString),
          let qr = VerificationQR.fromURL(url) else { return nil }
    return NoisePayload(type: .identityCard, data: encodeQRAsTLV(qr)).encode()
}

func parseIdentityCard(_ data: Data) -> VerificationQR? {
    // inverse TLV decode; applies same signature + freshness checks as verifyScannedQR
}
```

When a private Noise session completes and the user has "share my identity" enabled, the app sends
an identity card immediately after session establishment rather than waiting for a QR scan. The
receiving end runs the same signature verification as the QR flow and updates the local identity
cache identically. The QR flow remains as the out-of-band confirmation path for users who want
physical-proximity proof rather than trusting mesh delivery.

The BLEService handler for NOISE_ENCRYPTED packets already dispatches to didReceiveNoisePayload.
Adding a case for .identityCard there completes the receive path:

```swift
// SafeGuardian/Services/BLE/BLEService.swift — in handleNoiseEncrypted, add:
case .identityCard:
    if let qr = VerificationService.shared.parseIdentityCard(payload) {
        let fingerprint = sha256(Data(hexString: qr.noiseKeyHex)!).hexEncodedString()
        identityManager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: Data(hexString: qr.noiseKeyHex)!,
            signingPublicKey: Data(hexString: qr.signKeyHex),
            claimedNickname: qr.nickname
        )
        identityManager.updateSocialIdentity(SocialIdentity(
            fingerprint: fingerprint,
            localPetname: nil,
            claimedNickname: qr.nickname,
            trustLevel: .trusted,    // received over established Noise session = trusted
            isFavorite: false,
            isBlocked: false,
            notes: nil
        ))
    }
```

---

## Gap 2: Cross-device identity portability

The Noise static keypair lives in Keychain and does not survive a device reset or phone replacement.
A user with an established verified identity becomes a stranger to all their contacts after getting a
new phone. The fix is an opt-in encrypted identity export — the static private key, signing private
key, and social identity cache serialized and encrypted under a user-supplied passphrase using
Argon2id KDF + AES-256-GCM, exportable as a file or second QR code.

```swift
// SafeGuardian/Identity/IdentityPortability.swift (new file, ~120 lines)

struct IdentityExport: Codable {
    let version: Int             // 1
    let noisePrivateKey: Data    // 32 bytes, AES-GCM encrypted under export key
    let signingPrivateKey: Data  // 64 bytes, AES-GCM encrypted under export key
    let socialCache: Data        // IdentityCache JSON, AES-GCM encrypted under export key
    let salt: Data               // 32 bytes, Argon2id salt
    let nonce: Data              // 12 bytes, AES-GCM nonce for each field combined
    // export key = Argon2id(passphrase, salt, t=3, m=65536, p=4) -> 32 bytes

    static func export(
        manager: SecureIdentityStateManagerProtocol,
        keychain: KeychainManagerProtocol,
        passphrase: String
    ) -> IdentityExport? { ... }

    func importIdentity(
        into keychain: KeychainManagerProtocol,
        passphrase: String
    ) -> Bool { ... }
}
```

A user who never creates an export has nothing recoverable. That is the correct default for high-risk
users. The export is the user's responsibility and does not change the anonymity properties of any
session that does not use it.

---

## SafeGuardian-specific: institutional responder credentials

For the disaster response context there is a third category: verified first responders whose identity
should be trustworthy to strangers who have never met them, without requiring a QR scan. Apex issues
a signed credential atom binding a Noise public key to a responder role and issuing agency, signed
with Apex's P-384 policy key. Trek agents carry and broadcast these credentials in their announce
payload. A civilian Nova agent receiving a Trek peer's announce can verify the attached credential
against the Apex P-384 public key compiled into the app binary.

```swift
// SafeGuardian/Identity/ResponderCredential.swift (new file, ~80 lines)

struct ResponderCredential: Codable {
    let version: Int             // 1
    let holderNoiseKey: Data     // 32 bytes — the responder's Noise static public key
    let role: String             // "first_responder" | "trek_agent" | "incident_commander"
    let agency: String           // issuing agency name
    let validUntil: Int64        // unix timestamp
    let issuerKeyID: String      // identifies which Apex P-384 key signed this
    let signature: Data          // P-384 signature over canonical TLV of above fields

    // Verify offline against the Apex P-384 public key baked into the app binary
    func verify(apexPublicKey: P384.Signing.PublicKey) -> Bool {
        let canonical = canonicalBytes()
        guard let sig = try? P384.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return apexPublicKey.isValidSignature(sig, for: canonical)
    }

    private func canonicalBytes() -> Data {
        // length-prefixed concatenation of all fields except signature, sorted by field ID
        ...
    }
}
```

The credential is carried as an optional field in the AnnouncementPacket payload. Anonymous civilian
users never have one. Trek agents always have one. The Apex P-384 public key is compiled into the
app — no network fetch is required for verification.

```swift
// SafeGuardian/Protocols/AgentProcessor.swift or AnnouncementPacket — extend payload:
struct AnnouncementPacket {
    let nickname: String
    let noisePublicKey: Data
    let signingPublicKey: Data
    let directNeighbors: [Data]
    let agentIDs: [String]
    let responderCredential: ResponderCredential?   // nil for all civilian nodes
}
```

---

## Trust level assignment summary

    Received via announce only (no verification)      -> TrustLevel.casual
    Identity card received over established Noise     -> TrustLevel.trusted
    QR scan confirmed (existing verifyChallenge flow) -> TrustLevel.verified
    Apex-signed ResponderCredential attached          -> TrustLevel.verified + role tag

---

## Files needed

    New files:
    - SafeGuardian/Identity/IdentityPortability.swift    (~120 lines)
    - SafeGuardian/Identity/ResponderCredential.swift    (~80 lines)

    Modified files:
    - SafeGuardian/Protocols/SafeGuardianProtocol.swift  (add NoisePayloadType.identityCard = 0x12)
    - SafeGuardian/Services/VerificationService.swift    (add buildIdentityCard / parseIdentityCard)
    - SafeGuardian/Services/BLE/BLEService.swift         (add .identityCard case in noise dispatch)
    - SafeGuardian/Protocols/SafeGuardianProtocol.swift  (add responderCredential to AnnouncementPacket)

    No changes to:
    - BinaryProtocol, NoiseProtocol, BLEService core logic, IdentityModels, SecureIdentityStateManager
    - The default anonymous path through the app
