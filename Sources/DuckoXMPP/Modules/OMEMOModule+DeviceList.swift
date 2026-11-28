import Logging

private let log = Logger(label: "im.ducko.xmpp.omemo")

/// Reading and caching device lists, keeping this device on the account's lists, and fetching a contact's list again
/// when a message comes from a device not on it (XEP-0384).
extension OMEMOModule {
    // MARK: - Notifications

    func handleDeviceListNotification(
        _ message: XMPPMessage
    ) {
        let context = state.withLock { $0.context }
        // A device list is published from its owner's bare JID (XEP-0163), so any other sender publishes nothing.
        guard let event = message.element.child(
                  named: "event", namespace: XMPPNamespaces.pubsubEvent
              ), let itemsEl = event.child(named: "items"),
              let version = Self.deviceListVersion(ofNode: itemsEl.attribute("node")),
              let from = message.bareSender(orOwn: context?.connectedJID()?.bareJID), let item = itemsEl.child(named: "item"),
              let payload = item.children.compactMap({
                  if case let .element(el) = $0 { return el }
                  return nil
              }).first
        else { return }
        let devices = parseDeviceList(payload)
        let leavesOutThisDevice = state.withLock { state in
            state.deviceLists[version, default: [:]][from] = devices
            guard let identity = state.ownIdentity, from == identity.connectedJID.bareJID else { return false }
            return !devices.contains(identity.deviceID.value) && state.reannouncesOwnDevice(in: version)
        }
        context?.emitEvent(
            .omemoDeviceListReceived(jid: from, devices: devices, version: version)
        )
        if leavesOutThisDevice {
            reannounceOwnDevice(in: version)
        }
    }

    private static func deviceListVersion(ofNode node: String?) -> OMEMOWireFormat? {
        OMEMOWireFormat.allCases.first { deviceListNode($0) == node }
    }

    // MARK: - Own Device List

    /// Adds this device to the server's list in `version` unless it is there. `listed` is a list the caller has just
    /// read, which is not read again. Returns `false` when the server's list could not be read. Nothing is then
    /// published or cached, since publishing over an unread list would drop the other devices from it.
    func ensureOwnDeviceInList(
        _ deviceID: OMEMODeviceID, listed: [UInt32]? = nil, version: OMEMOWireFormat
    ) async throws -> Bool {
        var devices: [UInt32]
        if let listed {
            devices = listed
        } else {
            do {
                devices = try await fetchDeviceListFromPEP(nil, version: version) ?? []
            } catch {
                log.warning("\(version.logLabel) own device list fetch failed; leaving the device list unchanged")
                log.debug("\(version.logLabel) own device list fetch failed: \(error)")
                return false
            }
        }
        if !devices.contains(deviceID.value) {
            devices.append(deviceID.value)
            try await publishDeviceList(devices, version: version)
        }
        let finalDevices = devices
        state.withLock {
            if let ownJID = $0.context?.connectedJID()?.bareJID {
                $0.deviceLists[version, default: [:]][ownJID] = finalDevices
            }
        }
        return true
    }

    /// Adds this device back to the account's list in `version`, which a notification showed without it (XEP-0384).
    /// Waits while the connection's first setup attempt, a later one or another re-announce runs: each reads a list,
    /// changes it and publishes it, so two at once could put back a device the other removed.
    func reannounceOwnDevice(in version: OMEMOWireFormat) {
        state.withLock { state in
            guard let deviceID = state.ownIdentity?.deviceID else { return }
            guard state.isConnectSettled, state.ownListTask == nil else {
                state.pendingReannounces.insert(version)
                return
            }
            state.pendingReannounces.remove(version)
            fillOwnListSlot(&state) { module in await module.reannounce(deviceID, in: version) }
        }
    }

    /// Puts `work` in the slot for the one task that publishes this device's list after the connect. Called under the
    /// lock, so a notification cannot start a second task meanwhile. A task cannot be asked whether it ended, so each
    /// one empties the slot itself, after the re-announces asked for while it ran.
    func fillOwnListSlot(
        _ state: inout State, with work: @escaping @Sendable (OMEMOModule) async -> Void
    ) {
        state.ownListTaskGeneration &+= 1
        let generation = state.ownListTaskGeneration
        state.ownListTask = Task { [weak self] in
            guard let self else { return }
            await work(self)
            await runPendingReannounces(slotGeneration: generation)
        }
    }

    /// Runs each re-announce asked for while the slot's task ran, then empties the slot, unless a newer task took it.
    private func runPendingReannounces(slotGeneration: UInt64) async {
        while let (deviceID, version) = state.withLock({ state -> (OMEMODeviceID, OMEMOWireFormat)? in
            guard state.ownListTaskGeneration == slotGeneration else { return nil }
            guard !Task.isCancelled, state.isConnectSettled, let identity = state.ownIdentity,
                  let version = state.pendingReannounces.popFirst()
            else {
                state.ownListTask = nil
                return nil
            }
            return (identity.deviceID, version)
        }) {
            await reannounce(deviceID, in: version)
        }
    }

    private func reannounce(_ deviceID: OMEMODeviceID, in version: OMEMOWireFormat) async {
        do {
            _ = try await ensureOwnDeviceInList(deviceID, version: version)
        } catch {
            log.warning("\(version.logLabel) could not add this device back to the account's device list")
            log.debug("\(version.logLabel) could not add this device back to the account's device list: \(error)")
        }
    }

    /// Fetches device IDs for a JID. Cache hit is silent; pass `forceRefresh: true` to pull from PEP and emit
    /// `.omemoDeviceListReceived` (so trust store / UI observe it as they would a +notify). A missing node is cached as
    /// an empty list, without an event, so an encryption already under way wraps no key for the JID's devices. An empty
    /// cached list is fetched again even without `forceRefresh`, since without a subscription no notification would
    /// tell when the JID publishes devices. `version` picks which of the JID's lists.
    public func fetchDeviceList(
        for jid: BareJID, forceRefresh: Bool = false, version: OMEMOWireFormat
    ) async throws -> [UInt32] {
        if !forceRefresh, let cached = state.withLock({ $0.deviceLists[version]?[jid] }), !cached.isEmpty {
            return cached
        }
        guard let devices = try await fetchDeviceListFromPEP(jid, version: version) else {
            state.withLock { $0.deviceLists[version, default: [:]][jid] = [] }
            return []
        }
        let context = state.withLock { state in
            state.deviceLists[version, default: [:]][jid] = devices
            return state.context
        }
        if forceRefresh {
            context?.emitEvent(.omemoDeviceListReceived(jid: jid, devices: devices, version: version))
        }
        return devices
    }

    /// `jid`'s device list in `version`, or the account's when it is nil. Nil when the node is missing.
    func fetchDeviceListFromPEP(
        _ jid: BareJID?, version: OMEMOWireFormat
    ) async throws -> [UInt32]? {
        let items: [PEPItem]
        do {
            items = try await pepModule.retrieveItems(node: Self.deviceListNode(version), from: jid)
        } catch let error as XMPPStanzaError where error.condition == .itemNotFound {
            return nil
        }
        guard let item = items.first else { return [] }
        return parseDeviceList(item.payload)
    }

    func publishDeviceList(
        _ devices: [UInt32], version: OMEMOWireFormat
    ) async throws {
        let payload = switch version {
        case .omemo2: buildDeviceListElement(devices)
        case .legacy: buildLegacyDeviceListElement(devices)
        }
        try await pepModule.publishItem(
            node: Self.deviceListNode(version),
            itemID: "current",
            payload: payload,
            options: pepPublishOptions(maxItems: "1")
        )
    }

    private static func deviceListNode(_ version: OMEMOWireFormat) -> String {
        switch version {
        case .omemo2: XMPPNamespaces.omemoDevices
        case .legacy: XMPPNamespaces.omemoLegacyDeviceList
        }
    }

    // MARK: - Unannounced Senders

    /// Fetches `sender`'s device list again when a message comes from a device the cached list leaves out, so the
    /// device can be trusted and encrypted to. Each sender's list is fetched this way once per connection, so devices
    /// that stay off it, the old devices of archived messages, or made-up device ids cost one fetch and not one per
    /// message. A contact's later devices reach the cache through device-list notifications. The fetch builds no session.
    /// `version` is the message's, whose list is the one fetched.
    func refreshDeviceListIfUnannounced(sender: BareJID, deviceID: UInt32, version: OMEMOWireFormat) {
        let isUnannounced = state.withLock { state in
            guard state.deviceLists[version]?[sender]?.contains(deviceID) != true else { return false }
            return state.refreshedListSenders[version, default: []].insert(sender).inserted
        }
        guard isUnannounced else { return }
        Task { [weak self] in
            do {
                _ = try await self?.fetchDeviceList(for: sender, forceRefresh: true, version: version)
            } catch {
                log.warning("\(version.logLabel) device list of a message's sender could not be fetched")
                log.debug("\(version.logLabel) device list of \(sender) could not be fetched: \(error)")
            }
        }
    }
}

private extension OMEMOWireFormat {
    /// The version as log lines name it.
    var logLabel: String {
        switch self {
        case .omemo2: "OMEMO 2"
        case .legacy: "OMEMO legacy"
        }
    }
}
