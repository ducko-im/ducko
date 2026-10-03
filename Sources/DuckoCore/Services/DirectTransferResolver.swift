import DuckoXMPP
import Foundation

/// Works out which of a contact's online sessions a direct file transfer can go to. A session is asked whether it
/// takes direct transfers until it answers, and the answer is kept for as long as the session is known to be online.
@MainActor @Observable
final class DirectTransferResolver {
    /// The most sessions of one contact a single refresh asks. The contact chooses how many sessions to announce, and
    /// every question is a stanza this account sends.
    private static let maxSessionsAsked = 8

    private struct Question: Hashable {
        let accountID: UUID
        let session: FullJID
    }

    /// What each asked session answered. A session that has not answered yet is absent.
    private var supportByAccount: [UUID: [FullJID: Bool]] = [:]

    /// The questions still waiting for their answer. A refresh started meanwhile waits for them as well and does not
    /// send them again, and an answer counts only while its question is still here.
    private var asking: [Question: Task<Bool?, Never>] = [:]

    weak var accountService: AccountService?
    weak var chatService: ChatService?
    weak var presenceService: PresenceService?

    /// The session a direct transfer to `jid` goes to, from the answers received so far: the one the contact last
    /// wrote from when it takes direct transfers, else the session the contact shows first among those that do.
    func target(for jid: BareJID, accountID: UUID) -> FullJID? {
        Self.chooseSession(
            among: sessions(of: jid, accountID: accountID),
            lockedResource: chatService?.lockedResource(for: jid, accountID: accountID)
        ) { supportByAccount[accountID]?[$0] == true }
    }

    /// `sessions` come in the order the contact shows them.
    static func chooseSession(among sessions: [FullJID], lockedResource: String?, supports: (FullJID) -> Bool) -> FullJID? {
        let capable = sessions.filter(supports)
        return capable.first { $0.resourcePart == lockedResource } ?? capable.first
    }

    /// Asks the online sessions of `jid` that have no answer on record and no question on its way, up to
    /// `maxSessionsAsked`, in the order the contact shows them. Returns once every question on its way to one of them
    /// has been answered or has gone unanswered.
    func refresh(for jid: BareJID, accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID),
              let disco = await client.module(ofType: ServiceDiscoveryModule.self) else { return }
        // Chosen only now, with nothing suspending before the questions are on record: two refreshes at once would
        // otherwise both find the same sessions unasked.
        let unanswered = sessions(of: jid, accountID: accountID).filter { supportByAccount[accountID]?[$0] == nil }
        let unasked = unanswered.filter { asking[Question(accountID: accountID, session: $0)] == nil }
        for session in unasked.prefix(Self.maxSessionsAsked) {
            // Asked in a task of its own, which a cancelled caller does not end, so a caller that restarts on every
            // presence change does not drop and resend the questions in flight.
            asking[Question(accountID: accountID, session: session)] = Task { await Self.supportsDirectTransfer(session, asking: disco) }
        }
        // Every question on its way to one of the sessions is waited for, this refresh's own or an earlier one's, and
        // each answer is taken as it comes in, so a silent session does not hold back the others.
        let waiting = unanswered.compactMap { session in
            asking[Question(accountID: accountID, session: session)].map { (session, $0) }
        }
        await withTaskGroup(of: (FullJID, Task<Bool?, Never>, Bool?).self) { group in
            for (session, question) in waiting {
                group.addTask { await (session, question, question.value) }
            }
            for await (session, question, supports) in group {
                let key = Question(accountID: accountID, session: session)
                // A session that went offline while it was being asked had its question dropped: the answer may not
                // hold for whatever comes back under its name. And another refresh waiting on the same question may
                // have taken the answer already.
                guard asking[key] == question else { continue }
                asking[key] = nil
                guard let supports, sessions(of: jid, accountID: accountID).contains(session) else { continue }
                supportByAccount[accountID, default: [:]][session] = supports
            }
        }
    }

    /// `nil` when the session gave no answer, which is not a no: it is asked again on a later refresh.
    private nonisolated static func supportsDirectTransfer(_ session: FullJID, asking disco: ServiceDiscoveryModule) async -> Bool? {
        do {
            return try await disco.queryInfo(for: .full(session)).features.contains(XMPPNamespaces.jingleFileTransfer)
        } catch is XMPPStanzaError {
            // A session that answers with an error does not take direct transfers.
            return false
        } catch {
            return nil
        }
    }

    /// A session that went offline may come back as a different app under the same resource.
    func forget(_ session: FullJID, accountID: UUID) {
        supportByAccount[accountID]?.removeValue(forKey: session)
        asking[Question(accountID: accountID, session: session)] = nil
    }

    func forgetContact(_ jid: BareJID, accountID: UUID) {
        supportByAccount[accountID] = supportByAccount[accountID]?.filter { $0.key.bareJID != jid }
        asking = asking.filter { $0.key.accountID != accountID || $0.key.session.bareJID != jid }
    }

    func forgetAccount(_ accountID: UUID) {
        supportByAccount.removeValue(forKey: accountID)
        asking = asking.filter { $0.key.accountID != accountID }
    }

    private func sessions(of jid: BareJID, accountID: UUID) -> [FullJID] {
        (presenceService?.onlineResources(of: jid, accountID: accountID) ?? [])
            .compactMap { FullJID(bareJID: jid, resourcePart: $0) }
    }
}
