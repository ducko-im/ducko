import DuckoCore
import Foundation

/// Resolves the account-disambiguation label shown on a roster row or chat tab when the same peer
/// JID is rostered under more than one account. The single place this rule lives so the row, the
/// tab chip, and the width/auto-size measurements all agree.
enum AccountIndicator {
    /// The minimal label distinguishing `accountID` from the other accounts that also roster `bareJID`,
    /// or `nil` when the peer is on only one account (no indicator needed). Prefers a user-set display
    /// name; otherwise the localpart, falling back to the full bare JID when another roster-sharing
    /// account has the same localpart (e.g. `bob@` on two different servers).
    @MainActor
    static func label(
        for accountID: UUID,
        bareJID: String,
        accountService: AccountService,
        rosterService: RosterService
    ) -> String? {
        let duplicatedAccountIDs = rosterService.accountIDs(forBareJID: bareJID)
        guard duplicatedAccountIDs.count > 1,
              let account = accountService.accounts.first(where: { $0.id == accountID }) else { return nil }

        if let displayName = account.displayName { return displayName }

        let localpart = account.jid.localPart ?? account.jid.description
        let localpartCollides = accountService.accounts.contains {
            duplicatedAccountIDs.contains($0.id)
                && $0.id != accountID
                && ($0.jid.localPart ?? $0.jid.description) == localpart
        }
        return localpartCollides ? account.jid.description : localpart
    }

    /// The disambiguation label for a chat tab: only a direct 1:1 (not a room or MUC PM) whose bare
    /// JID is duplicated earns one. The single home for the "is this a direct 1:1 tab" gate so the
    /// tab chip's render and the tab bar's width math agree. `nil` for rooms/PMs or a non-duplicated peer.
    @MainActor
    static func tabLabel(
        for key: ConversationKey,
        conversation: Conversation?,
        accountService: AccountService,
        rosterService: RosterService
    ) -> String? {
        let isDirect = conversation?.isDirectChat ?? true
        guard isDirect, let accountID = key.accountID else { return nil }
        return label(for: accountID, bareJID: key.jid, accountService: accountService, rosterService: rosterService)
    }

    /// Account-qualifies an accessibility identifier (`base|{account-jid}`) when `qualify` is true and
    /// the account resolves; otherwise returns `base` unchanged. Keeps two same-JID rows/tabs
    /// individually addressable while single-account users keep the plain `base` id.
    @MainActor
    static func qualified(
        _ base: String,
        accountID: UUID?,
        qualify: Bool,
        accountService: AccountService
    ) -> String {
        guard qualify, let accountID,
              let account = accountService.accounts.first(where: { $0.id == accountID }) else { return base }
        return "\(base)|\(account.jid.description)"
    }
}
