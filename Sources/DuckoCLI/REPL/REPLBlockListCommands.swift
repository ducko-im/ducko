import DuckoCore
import Foundation

func handleBlockREPLCommand(_ jidString: String, context: REPLContext, unblocking: Bool) async {
    do {
        if unblocking {
            try await context.environment.rosterService.unblockContact(jidString: jidString, accountID: context.accountID)
            print("Unblocked \(jidString).")
        } else {
            try await context.environment.rosterService.blockContact(jidString: jidString, accountID: context.accountID)
            print("Blocked \(jidString).")
        }
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleBlockListREPLCommand(context: REPLContext) async {
    do {
        let entries = try await context.environment.rosterService.loadBlockList(accountID: context.accountID)
        guard !entries.isEmpty else {
            print(context.formatter.formatEmptyResult(.blockList(accountID: context.accountID)))
            return
        }
        for entry in entries {
            print(context.formatter.formatBlockListEntry(entry))
        }
    } catch {
        print(context.formatter.formatError(error))
    }
}
