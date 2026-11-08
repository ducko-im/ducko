import DuckoCore
import Foundation

/// Scoped to the command's own account: a global pick would also bring every other enabled account online.
@MainActor
func applyPresence(
    _ presenceStatus: PresenceService.PresenceStatus,
    message: String?,
    environment: AppEnvironment,
    accountID: UUID
) async {
    await environment.presenceService.applyPresence(
        presenceStatus,
        message: message,
        accountID: accountID
    ) { id in
        try await connectStored(environment, accountID: id)
    } disconnect: { id in
        await environment.accountService.disconnect(accountID: id)
    }
}
