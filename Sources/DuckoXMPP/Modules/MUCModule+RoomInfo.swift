import Logging

private let log = Logger(label: "im.ducko.xmpp.muc")

/// Each room's disco#info, asked for before every join and kept for the rest of the session.
public extension MUCModule {
    /// How long a join waits for the room's disco#info before it sends the join presence.
    internal static let joinRoomInfoTimeout: Duration = .seconds(2)

    /// The room's disco#info, once its answer is stored.
    func knownRoomInfo(for room: BareJID) -> ServiceDiscoveryModule.InfoResult? {
        state.withLock { $0.knownRoomInfo[room] }
    }

    /// The room's disco#info: the stored answer, or else the room's own within `timeout`, which is then stored. Nil
    /// when the room does not answer in time or answers with an error, which means its features are unknown.
    func roomInfo(for room: BareJID, timeout: Duration) async -> ServiceDiscoveryModule.InfoResult? {
        if let known = knownRoomInfo(for: room) { return known }
        guard let context = state.withLock({ $0.context }) else { return nil }
        let info = await withTaskGroup(of: ServiceDiscoveryModule.InfoResult?.self) { group in
            group.addTask { await Self.queryRoomInfo(room, context: context) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            // Cancelling the unanswered query resolves its pending request, so the group ends at once.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let info else { return nil }
        state.withLock { $0.knownRoomInfo[room] = info }
        return info
    }

    private static func queryRoomInfo(_ room: BareJID, context: ModuleContext) async -> ServiceDiscoveryModule.InfoResult? {
        do {
            return try await ServiceDiscoveryModule.queryInfo(for: .bare(room), context: context)
        } catch {
            log.debug("Service discovery of \(room) failed: \(error)")
            return nil
        }
    }
}
