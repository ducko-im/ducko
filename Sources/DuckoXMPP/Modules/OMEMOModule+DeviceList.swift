import Logging

private let log = Logger(label: "im.ducko.xmpp.omemo")

/// Reading and caching device lists, keeping this device on the account's list, and fetching a contact's list again
/// when a message comes from a device not on it (XEP-0384).
extension OMEMOModule {
    // MARK: - Own Device List

    /// Adds this device to the server's list unless it is there. `listed` is a list the caller has just read, which is
    /// not read again. Returns `false` when the server's list could not be read. Nothing is then published or cached,
    /// since publishing over an unread list would drop the other devices from it.
    func ensureOwnDeviceInList(
        _ deviceID: OMEMODeviceID, listed: [UInt32]? = nil
    ) async throws -> Bool {
        var devices: [UInt32]
        if let listed {
            devices = listed
        } else {
            do {
                devices = try await fetchDeviceListFromPEP(nil) ?? []
            } catch {
                log.warning("OMEMO own device list fetch failed; leaving the device list unchanged")
                log.debug("OMEMO own device list fetch failed: \(error)")
                return false
            }
        }
        if !devices.contains(deviceID.value) {
            devices.append(deviceID.value)
            try await publishDeviceList(devices)
        }
        let finalDevices = devices
        state.withLock {
            if let ownJID = $0.context?.connectedJID()?.bareJID {
                $0.deviceLists[ownJID] = finalDevices
            }
        }
        return true
    }

    /// Retries adding this device to the server's list after the connect-time read failed, so a transient failure
    /// does not leave the device unadvertised for the whole session.
    func retryOwnDeviceRegistration(_ deviceID: OMEMODeviceID) {
        let delays = registrationRetryDelays
        let previous = state.withLock { state in
            fillOwnListSlot(&state) { module in
                for delay in delays {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    if await (try? module.ensureOwnDeviceInList(deviceID)) == true { return }
                }
            }
        }
        previous?.cancel()
    }

    /// Adds this device back to the account's list, which a notification showed without it (XEP-0384). Waits while
    /// the connect's own publishes of the list, a registration retry or another re-announce run: each reads the list,
    /// changes it and publishes it, so two at once could put back a device the other removed.
    func reannounceOwnDevice() {
        state.withLock { state in
            guard let deviceID = state.ownIdentity?.deviceID else { return }
            guard state.isConnectSettled, state.ownListTask == nil else {
                state.reannouncePending = true
                return
            }
            state.reannouncePending = false
            _ = fillOwnListSlot(&state) { module in await module.reannounce(deviceID) }
        }
    }

    /// Lets re-announces start once the connect's own publishes of the list are done, and runs one a notification
    /// asked for meanwhile.
    func settleConnect() {
        let isPending = state.withLock { state in
            state.isConnectSettled = true
            return state.reannouncePending
        }
        if isPending {
            reannounceOwnDevice()
        }
    }

    /// Puts `work` in the slot for the one task that publishes this device's list after the connect, and returns the
    /// task it replaced. Called under the lock, so a notification cannot start a second task meanwhile. A task cannot
    /// be asked whether it ended, so each one empties the slot itself, after the re-announces asked for while it ran.
    private func fillOwnListSlot(
        _ state: inout State, with work: @escaping @Sendable (OMEMOModule) async -> Void
    ) -> Task<Void, Never>? {
        state.ownListTaskGeneration &+= 1
        let generation = state.ownListTaskGeneration
        let previous = state.ownListTask
        state.ownListTask = Task { [weak self] in
            guard let self else { return }
            await work(self)
            await runPendingReannounces(slotGeneration: generation)
        }
        return previous
    }

    /// Runs each re-announce asked for while the slot's task ran, then empties the slot, unless a newer task took it.
    private func runPendingReannounces(slotGeneration: UInt64) async {
        while let deviceID = state.withLock({ state -> OMEMODeviceID? in
            guard state.ownListTaskGeneration == slotGeneration else { return nil }
            guard !Task.isCancelled, state.isConnectSettled, state.reannouncePending, let identity = state.ownIdentity else {
                state.ownListTask = nil
                return nil
            }
            state.reannouncePending = false
            return identity.deviceID
        }) {
            await reannounce(deviceID)
        }
    }

    private func reannounce(_ deviceID: OMEMODeviceID) async {
        do {
            _ = try await ensureOwnDeviceInList(deviceID)
        } catch {
            log.warning("OMEMO could not add this device back to the account's device list")
            log.debug("OMEMO could not add this device back to the account's device list: \(error)")
        }
    }

    /// Fetches device IDs for a JID. Cache hit is silent; pass `forceRefresh: true` to pull from PEP and emit
    /// `.omemoDeviceListReceived` (so trust store / UI observe it as they would a +notify). A missing node is cached as
    /// an empty list, without an event, so an encryption already under way wraps no key for the JID's devices. An empty
    /// cached list is fetched again even without `forceRefresh`, since without a subscription no notification would
    /// tell when the JID publishes devices.
    public func fetchDeviceList(
        for jid: BareJID, forceRefresh: Bool = false
    ) async throws -> [UInt32] {
        if !forceRefresh, let cached = state.withLock({ $0.deviceLists[jid] }), !cached.isEmpty {
            return cached
        }
        guard let devices = try await fetchDeviceListFromPEP(jid) else {
            state.withLock { $0.deviceLists[jid] = [] }
            return []
        }
        let context = state.withLock { state in
            state.deviceLists[jid] = devices
            return state.context
        }
        if forceRefresh {
            context?.emitEvent(.omemoDeviceListReceived(jid: jid, devices: devices))
        }
        return devices
    }

    /// `jid`'s device list, or the account's when it is nil. Nil when the node is missing.
    func fetchDeviceListFromPEP(
        _ jid: BareJID?
    ) async throws -> [UInt32]? {
        let items: [PEPItem]
        do {
            items = try await pepModule.retrieveItems(node: XMPPNamespaces.omemoDevices, from: jid)
        } catch let error as XMPPStanzaError where error.condition == .itemNotFound {
            return nil
        }
        guard let item = items.first else { return [] }
        return parseDeviceList(item.payload)
    }

    func publishDeviceList(
        _ devices: [UInt32]
    ) async throws {
        let payload = buildDeviceListElement(devices)
        try await pepModule.publishItem(
            node: XMPPNamespaces.omemoDevices,
            itemID: "current",
            payload: payload,
            options: pepPublishOptions(maxItems: "1")
        )
    }

    // MARK: - Unannounced Senders

    /// Fetches `sender`'s device list again when a message comes from a device the cached list leaves out, so the
    /// device can be trusted and encrypted to. Each sender's list is fetched this way once per connection, so devices
    /// that stay off it, the old devices of archived messages, or made-up device ids cost one fetch and not one per
    /// message. A contact's later devices reach the cache through device-list notifications. The fetch builds no session.
    func refreshDeviceListIfUnannounced(sender: BareJID, deviceID: UInt32) {
        let isUnannounced = state.withLock { state in
            guard state.deviceLists[sender]?.contains(deviceID) != true else { return false }
            return state.refreshedListSenders.insert(sender).inserted
        }
        guard isUnannounced else { return }
        Task { [weak self] in
            do {
                _ = try await self?.fetchDeviceList(for: sender, forceRefresh: true)
            } catch {
                log.warning("OMEMO device list of a message's sender could not be fetched")
                log.debug("OMEMO device list of \(sender) could not be fetched: \(error)")
            }
        }
    }
}
