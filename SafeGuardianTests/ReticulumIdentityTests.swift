//
// ReticulumIdentityTests.swift
// SafeGuardianTests
//
// Tests for Reticulum identity management and packet roundtrips.
//

import Testing
import Foundation
import CryptoKit
import BitFoundation
@testable import SafeGuardian

struct ReticulumIdentityTests {

    @Test func testIdentityDeterminism() throws {
        let mockKeychain = MockKeychain()
        
        // First creation
        let id1 = try ReticulumIdentity.loadOrCreate(keychain: mockKeychain)
        let hash1 = id1.destinationHash
        
        // Second creation (should load from mock keychain)
        let id2 = try ReticulumIdentity.loadOrCreate(keychain: mockKeychain)
        let hash2 = id2.destinationHash
        
        #expect(hash1 == hash2)
        #expect(id1.peerID == id2.peerID)
    }

    @Test func testDestinationHashLength() throws {
        let mockKeychain = MockKeychain()
        let identity = try ReticulumIdentity.loadOrCreate(keychain: mockKeychain)
        
        #expect(identity.destinationHash.count == 16)
    }

    @Test func testAnnounceRoundtrip() throws {
        let mockKeychain = MockKeychain()
        let identity = try ReticulumIdentity.loadOrCreate(keychain: mockKeychain)
        let appData = "Test App Data".data(using: .utf8)!
        
        let announce = try ReticulumAnnounce.build(identity: identity, appData: appData)
        let encoded = announce.encode()
        
        guard let decoded = ReticulumAnnounce.decode(encoded) else {
            Issue.record("Failed to decode ReticulumAnnounce")
            return
        }
        
        #expect(decoded.destinationHash == identity.destinationHash)
        #expect(decoded.signingPublicKey == identity.signingPrivateKey.publicKey.rawRepresentation)
        #expect(decoded.encryptionPublicKey == identity.encryptionPrivateKey.publicKey.rawRepresentation)
        #expect(decoded.appData == appData)
        #expect(decoded.randomHash.count == ReticulumAnnounce.randomHashLength)
        #expect(decoded.signature.count == ReticulumAnnounce.signatureLength)
    }

    @Test func testDataPacketRoundtrip() throws {
        let mockKeychain = MockKeychain()
        let identity = try ReticulumIdentity.loadOrCreate(keychain: mockKeychain)
        let payload = "Hello Reticulum".data(using: .utf8)!
        
        let packet = ReticulumDataPacket.broadcast(payload: payload, identity: identity)
        let encoded = packet.encode()
        
        guard let decoded = ReticulumDataPacket.decode(encoded) else {
            Issue.record("Failed to decode ReticulumDataPacket")
            return
        }
        
        #expect(decoded.destinationHash == Data(repeating: 0, count: 16))
        #expect(decoded.payload == payload)
        #expect(decoded.header.packetType == .data)
        #expect(decoded.header.propagation == .broadcast)
    }
}
