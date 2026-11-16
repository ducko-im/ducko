import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Registration forms fetched over a signed-in account's connection.
@MainActor
struct AccountServiceSignedInRegistrationTests {
    private let transport = MockTransport()
    private let service: AccountService

    init() {
        self.service = AccountService(
            store: MockPersistenceStore(), credentialStore: MockCredentialStore(),
            clientFactory: MockXMPPClientFactory(transport: transport, modules: [RegistrationModule()])
        )
    }

    /// The server or component registered with, nil for the account's own, and the JID the proof of work starts with.
    @Test(.timeLimit(.minutes(1)), arguments: [(String?.none, "example.com"), ("gateway.example.com", "gateway.example.com")])
    func `A fresh form after a refusal asks for the image again, keeps what was typed and answers the proof of work`(
        jid: String?, prefix: String
    ) async throws {
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        _ = try await driveMockConnect(service, accountID: id, transport: transport)
        let challenges = CaptchaFormFixtures.ocr() + CaptchaFormFixtures.proofOfWork(CaptchaFormFixtures.solvableLabel)
        var rejected = try RegistrationFormInfo(from: CaptchaFormFixtures.form(challenges))
        let username = try #require(rejected.dataForm.fields.firstIndex { $0.variable == "username" })
        rejected.dataForm.fields[username].values = ["juliet"]
        await transport.clearSentBytes()

        let reopening = Task { @MainActor [service] in try await service.reopenRegistrationForm(accountID: id, from: jid, after: rejected) }
        let request = try #require(await transport.waitForSent { $0.contains(XMPPNamespaces.register) })
        let sender = jid.map { " from='\($0)'" } ?? ""
        try await transport.simulateReceive(
            "<iq type='result' id='\(#require(extractIQID(from: request)))'\(sender)>\(CaptchaFormFixtures.query(challenges, from: nil))</iq>"
        )
        let fresh = try await reopening.value

        if let jid {
            #expect(request.contains("to=\"\(jid)\""))
        } else {
            #expect(!request.contains(" to="))
        }
        #expect(fresh.captcha?.challenges.map(\.variable) == ["ocr"])
        #expect(fresh.value(of: "username") == "juliet")
        #expect(fresh.captcha?.proofOfWork?.answer?.hasPrefix(prefix) == true)
        await service.disconnect(accountID: id)
    }
}
