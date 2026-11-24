import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Drives receipt admission and the owned worker without a live network connection.
@MainActor
final class RosterServiceFixture {
    let store: MockPersistenceStore
    let service: RosterService
    private var receipts: [UUID: UInt64] = [:]

    /// With `accountService`, the service reads which accounts are enabled from it, and `prepare` loads the test
    /// account into it enabled.
    init(store: MockPersistenceStore, service: RosterService? = nil, accountService: AccountService? = nil) {
        self.store = store
        self.service = service ?? RosterService(store: store)
        if let accountService {
            self.service.setAccountService(accountService)
        }
    }

    func prepare(accountID: UUID) async throws {
        guard receipts[accountID] == nil else { return }
        if try await !store.fetchAccounts().contains(where: { $0.id == accountID }) {
            try await store.saveAccount(Account(id: accountID, jid: BareJID.parse("user@example.com")!, isEnabled: true, connectOnLaunch: false, createdAt: Date()))
        }
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: MockTransport())
        service.beginSession(accountID: accountID, sessionID: UUID(), client: client)
        receipts[accountID] = 0
    }

    func deliver(_ contents: RosterUpdate.Contents, accountID: UUID, version: String? = nil) async {
        do {
            try await prepare(accountID: accountID)
            if receipts[accountID] == 0, case .delta = contents {
                await deliver(.cachedBaseline, accountID: accountID)
            }
            let receipt = (receipts[accountID] ?? 0) + 1
            receipts[accountID] = receipt
            let origin: RosterUpdate.Origin = switch contents {
            case .snapshot, .cachedBaseline, .initialQueryFailed: receipt == 1 ? .initial : .readback("fixture-\(receipt)")
            case .delta: .push
            }
            let task = service.receiveRosterEvent(.rosterUpdated(RosterUpdate(receipt: receipt, origin: origin, contents: contents, version: version)), accountID: accountID)
            await task?.value
        } catch {
            Issue.record(error)
        }
    }
}
