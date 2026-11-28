import Logging

private let log = Logger(label: "im.ducko.xmpp.omemo")

/// Publishing this device for legacy OMEMO (XEP-0384 v0.3) under the id and keys it has for OMEMO 2: its bundle in a
/// node of its own, then its id on the account's legacy device list. Nothing prunes the legacy list or bundle nodes,
/// since an id there can belong to another client.
extension OMEMOModule {
    /// The fewest pre-keys a legacy bundle may list (XEP-0384 v0.3).
    static let minimumLegacyPreKeyCount = 20

    /// Publishes the legacy bundle and device-list entry when they lag, in the own-list slot once the task there has
    /// ended, so the list is never read and published alongside a setup attempt or a re-announce.
    func publishLegacyDeviceInOwnListSlot() async throws {
        guard laggingLegacyPublication() != nil else { return }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, any Error>, Never>) in
            state.withLock { state in
                let previous = state.ownListTask
                fillOwnListSlot(&state) { module in
                    await previous?.value
                    do {
                        try await module.publishLegacyDevice()
                        continuation.resume(returning: .success(()))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        }
        try result.get()
    }

    /// Publishes the legacy device from the own-list slot the completing setup attempt ran in. A failure leaves the
    /// publication lagging, so pre-key upkeep retries it. The connection ending cancels the slot's task, which is no
    /// failure: the next connection publishes again.
    func publishLegacyDeviceAfterSetup() async {
        do {
            try await publishLegacyDevice()
        } catch where Task.isCancelled || error is CancellationError {
            log.debug("OMEMO legacy bundle publication stopped as the connection ended: \(error)")
        } catch {
            log.warning("OMEMO legacy bundle could not be published")
            log.debug("OMEMO legacy bundle could not be published: \(error)")
        }
    }

    /// Publishes the legacy bundle, then adds this device to the account's legacy list unless it is there, when the
    /// publication lags. Runs in the own-list slot. The publication counts only once both succeed.
    private func publishLegacyDevice() async throws {
        guard let (identity, preKeyIDs) = laggingLegacyPublication() else { return }
        let bundle = try OMEMOPreKeyManager.buildLegacyBundle(
            deviceID: identity.deviceID,
            identityKeyPair: identity.identityKeyPair,
            signedPreKey: identity.signedPreKey,
            preKeys: identity.preKeys.filter { preKeyIDs.contains($0.keyID) }
        )
        try await pepModule.publishItem(
            node: XMPPNamespaces.omemoLegacyBundles(deviceID: identity.deviceID.value), itemID: "current",
            payload: buildLegacyBundleElement(bundle), options: pepPublishOptions(maxItems: "1")
        )
        state.withLock { $0.isWritingLegacyListEntry = true }
        defer { state.withLock { $0.isWritingLegacyListEntry = false } }
        guard try await ensureOwnDeviceInList(identity.deviceID, version: .legacy) else { return }
        state.withLock { state in
            // A disconnect during the publish reset this module, so what it published no longer counts.
            guard state.ownIdentity != nil else { return }
            state.publishedLegacyPreKeyIDs = preKeyIDs
            state.publishedLegacySignedPreKeyID = identity.signedPreKey.keyID
        }
    }

    /// The identity and the pre-key ids a legacy publish would carry, or nil when the publication does not lag.
    private func laggingLegacyPublication() -> (identity: OwnIdentity, preKeyIDs: Set<UInt32>)? {
        state.withLock { state in
            guard let identity = state.ownIdentity else { return nil }
            let preKeyIDs = Self.publishablePreKeyIDs(of: identity, used: state.usedPreKeyIDs)
            guard state.legacyPublicationLags(signedPreKeyID: identity.signedPreKey.keyID, preKeyIDs: preKeyIDs) else { return nil }
            return (identity, preKeyIDs)
        }
    }
}

extension OMEMOModule.State {
    /// Whether the last legacy publication lags the signed pre-key and pre-keys this device can hand out. With fewer
    /// than `minimumLegacyPreKeyCount` pre-keys it stays pending instead, until upkeep tops them up.
    func legacyPublicationLags(signedPreKeyID: UInt32, preKeyIDs: Set<UInt32>) -> Bool {
        preKeyIDs.count >= OMEMOModule.minimumLegacyPreKeyCount
            && (publishedLegacyPreKeyIDs != preKeyIDs || publishedLegacySignedPreKeyID != signedPreKeyID)
    }

    /// Whether a notification that leaves this device off the account's list in `version` makes it add the device back.
    /// Until a legacy publication succeeded, the pending one adds it. While one writes the list, which it may have read
    /// before the notification's change, the re-announce runs after it and reads the list again.
    func reannouncesOwnDevice(in version: OMEMOWireFormat) -> Bool {
        switch version {
        case .omemo2: true
        case .legacy: publishedLegacySignedPreKeyID != nil || isWritingLegacyListEntry
        }
    }
}
