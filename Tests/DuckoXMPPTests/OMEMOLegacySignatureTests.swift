import Foundation
import Testing
@testable import DuckoXMPP

/// Legacy signed pre-key signatures, checked against the reference implementation's bundles.
struct OMEMOLegacySignatureTests {
    @Test(arguments: ["alice", "bob"])
    func `the reference bundle's signature verifies`(device name: String) throws {
        let device = try OMEMOLegacyFixtures.device(name)

        let valid = OMEMOLegacySignature.verify(
            Array(device.signedPreKey.publishedSignature), signedPreKey: Array(device.signedPreKey.publicKey),
            identityCurveKey: Array(device.identityKey.agreementPublicKey)
        )

        #expect(valid)
    }

    @Test(arguments: ["alice", "bob"])
    func `Ducko's own signature verifies for an identity with either sign bit`(device name: String) throws {
        let device = try OMEMOLegacyFixtures.device(name)
        let identity = try device.restoredIdentityKey()
        let signedPreKey = Array(device.signedPreKey.publicKey)

        let signature = try OMEMOLegacySignature.sign(signedPreKey: signedPreKey, with: identity)

        #expect(OMEMOLegacySignature.verify(signature, signedPreKey: signedPreKey, identityCurveKey: Array(device.identityKey.agreementPublicKey)))
    }

    enum Tampering: CaseIterable {
        case flippedSignBit, flippedBitInR, flippedBitInS, flippedBitInKey, unprefixedSignedPreKey, empty, truncated, extended
    }

    @Test(arguments: Tampering.allCases)
    func `a tampered signature or key is rejected`(tampering: Tampering) throws {
        let device = try OMEMOLegacyFixtures.device("alice")
        let signedPreKey = Array(device.signedPreKey.publicKey)
        var signature = Array(device.signedPreKey.publishedSignature)
        var identityCurveKey = Array(device.identityKey.agreementPublicKey)
        switch tampering {
        case .flippedSignBit: signature[63] ^= 0x80
        case .flippedBitInR: signature[0] ^= 0x01
        case .flippedBitInS: signature[32] ^= 0x01
        case .flippedBitInKey: identityCurveKey[0] ^= 0x01
        case .unprefixedSignedPreKey:
            let identity = try device.restoredIdentityKey()
            signature = try identity.sign(signedPreKey)
            signature[63] |= 0x80
        case .empty: signature = []
        case .truncated: signature.removeLast()
        case .extended: signature.append(0)
        }

        #expect(!OMEMOLegacySignature.verify(signature, signedPreKey: signedPreKey, identityCurveKey: identityCurveKey))
    }
}
