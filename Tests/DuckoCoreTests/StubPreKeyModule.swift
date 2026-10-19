import struct os.OSAllocatedUnfairLock
@testable import DuckoCore
@testable import DuckoXMPP

/// Key material that decodes: any 32 bytes make an Ed25519 seed and an X25519 private key.
func makeIdentityData(deviceID: UInt32 = 4242, preKeyIDs: [UInt32] = [1]) -> OMEMOModule.OMEMOIdentityData {
    OMEMOModule.OMEMOIdentityData(
        deviceID: deviceID,
        identityKeyRaw: Array(repeating: 0xA1, count: 32),
        signedPreKeyID: 7,
        signedPreKeyRaw: Array(repeating: 0xB2, count: 32),
        signedPreKeySignature: Array(repeating: 0xC3, count: 64),
        preKeys: preKeyIDs.map { OMEMOModule.OMEMOIdentityData.PreKeyData(keyID: $0, keyRaw: Array(repeating: 0xD4, count: 32)) }
    )
}

/// Plays the module for first-time persistence and pre-key upkeep: reports `identity` and `consumed`, records added and
/// retired pre-keys, and publishes with the outcome `publishFails` decides. The bundle needs publishing at first and
/// again once keys are added or newly retired, until a publish succeeds.
final class StubPreKeyModule: OMEMOPreKeyMaintaining {
    private struct State {
        var added: [[UInt32]] = []
        var retired: Set<UInt32> = []
        var publishAttempts = 0
        var needsPublish = true
        var publishFails = false
    }

    let identity: OMEMOModule.OMEMOIdentityData?
    let consumed: Set<UInt32>
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(identity: OMEMOModule.OMEMOIdentityData?, consumed: Set<UInt32> = []) {
        self.identity = identity
        self.consumed = consumed
    }

    var ownIdentityData: OMEMOModule.OMEMOIdentityData? {
        identity
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
