import struct os.OSAllocatedUnfairLock
@testable import DuckoCore
@testable import DuckoXMPP

/// Key material that decodes: any 32 bytes make an Ed25519 seed and an X25519 private key. The signed pre-key is
/// `signedPreKeyID`, and `retainedSignedPreKeyIDs` name the older ones held besides it.
func makeIdentityData(
    deviceID: UInt32 = 4242, preKeyIDs: [UInt32] = [1], signedPreKeyID: UInt32 = 7, retainedSignedPreKeyIDs: [UInt32] = []
) -> OMEMOModule.OMEMOIdentityData {
    OMEMOModule.OMEMOIdentityData(
        deviceID: deviceID,
        identityKeyRaw: Array(repeating: 0xA1, count: 32),
        signedPreKeyID: signedPreKeyID,
        signedPreKeyRaw: Array(repeating: 0xB2, count: 32),
        signedPreKeySignature: Array(repeating: 0xC3, count: 64),
        preKeys: preKeyIDs.map { OMEMOModule.OMEMOIdentityData.PreKeyData(keyID: $0, keyRaw: Array(repeating: 0xD4, count: 32)) },
        retainedSignedPreKeys: retainedSignedPreKeyIDs.map {
            OMEMOModule.OMEMOIdentityData.SignedPreKeyData(keyID: $0, keyRaw: Array(repeating: 0xB2, count: 32), signature: Array(repeating: 0xC3, count: 64))
        }
    )
}

/// A responder session in `format`, in the stored encoding, or, with `isRatchetOnly`, its ratchet alone as the earlier
/// encoding stored it.
func storedSessionData(format: OMEMOWireFormat = .omemo2, isRatchetOnly: Bool = false) throws -> [UInt8] {
    let ratchet = try OMEMODoubleRatchetSession(
        asResponderWithSharedSecret: Array(repeating: 1, count: 32),
        ourSignedPreKeyPair: OMEMOSignedPreKey(keyID: 1, identityKey: OMEMOIdentityKeyPair()).keyPair,
        format: format
    )
    let keyExchange = OMEMOKeyExchangeHeader(
        preKeyID: 1, signedPreKeyID: 1, identityKey: Array(repeating: 0xAB, count: 32), ephemeralKey: Array(repeating: 0xEE, count: 32)
    )
    return isRatchetOnly
        ? ratchet.serialize()
        : OMEMOSession(ratchet: ratchet, associatedData: storedAssociatedData(format: format), start: .received(keyExchange)).serialized
}

/// Associated data as long as a session in `format` stores: two identity keys in that version's encoding.
func storedAssociatedData(format: OMEMOWireFormat = .omemo2) -> [UInt8] {
    switch format {
    case .omemo2: Array(repeating: 0, count: 64)
    case .legacy: Array(repeating: 0, count: 66)
    }
}

/// Plays the module for pre-key upkeep: reports `identity` and `consumed`, records added and
/// retired pre-keys, takes installed signed pre-keys into its identity, and publishes with the outcome `publishFails`
/// decides. The bundle needs publishing at first and again once keys are added or newly retired or the current signed
/// pre-key is replaced, until a publish succeeds.
final class StubPreKeyModule: OMEMOPreKeyMaintaining {
    private struct State {
        var identity: OMEMOModule.OMEMOIdentityData?
        var added: [[UInt32]] = []
        var retired: Set<UInt32> = []
        var publishAttempts = 0
        var needsPublish = true
        var publishFails = false
    }

    let consumed: Set<UInt32>
    private let state: OSAllocatedUnfairLock<State>

    init(identity: OMEMOModule.OMEMOIdentityData?, consumed: Set<UInt32> = []) {
        self.consumed = consumed
        self.state = OSAllocatedUnfairLock(initialState: State(identity: identity))
    }

    var ownIdentityData: OMEMOModule.OMEMOIdentityData? {
        state.withLock { $0.identity }
    }

    func consumedPreKeyIDs() -> Set<UInt32> {
        consumed
    }

    var bundleNeedsPublish: Bool {
        state.withLock { $0.needsPublish }
    }

    func addPreKeys(_ preKeys: [OMEMOPreKey]) {
        state.withLock {
            $0.added.append(preKeys.map(\.keyID))
            $0.needsPublish = true
        }
    }

    func retirePreKeys(_ keyIDs: Set<UInt32>) {
        state.withLock { state in
            guard !keyIDs.isSubset(of: state.retired) else { return }
            state.retired.formUnion(keyIDs)
            state.needsPublish = true
        }
    }

    func installSignedPreKeys(
        current: OMEMOModule.OMEMOIdentityData.SignedPreKeyData, retained: [OMEMOModule.OMEMOIdentityData.SignedPreKeyData]
    ) throws {
        state.withLock { state in
            guard let identity = state.identity else { return }
            state.needsPublish = state.needsPublish || current.keyID != identity.signedPreKeyID
            state.identity = OMEMOModule.OMEMOIdentityData(
                deviceID: identity.deviceID, identityKeyRaw: identity.identityKeyRaw, signedPreKeyID: current.keyID,
                signedPreKeyRaw: current.keyRaw, signedPreKeySignature: current.signature, preKeys: identity.preKeys,
                retainedSignedPreKeys: retained
            )
        }
    }

    func republishBundle() async throws {
        let fails = state.withLock { state in
            state.publishAttempts += 1
            if !state.publishFails { state.needsPublish = false }
            return state.publishFails
        }
        if fails { throw OMEMOModuleError.notSetUp }
    }

    func setPublishFails(_ fails: Bool) {
        state.withLock { $0.publishFails = fails }
    }

    var added: [[UInt32]] {
        state.withLock { $0.added }
    }

    var publishAttempts: Int {
        state.withLock { $0.publishAttempts }
    }

    var retired: Set<UInt32> {
        state.withLock { $0.retired }
    }
}
