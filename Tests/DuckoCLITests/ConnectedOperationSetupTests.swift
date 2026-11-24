import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoCLI

/// A one-shot command connects, waits for the first OMEMO setup attempt, runs, and disconnects, whatever the attempt's
/// outcome.
@MainActor
struct ConnectedOperationSetupTests {
    @Test func `a one-shot command runs only once the first setup attempt had its outcome, also a refusal`() async throws {
        let transport = MockTransport()
        // The setup's read of the account's list is held, and its device-list publish refused.
        await transport.blockSends { $0.contains(XMPPNamespaces.omemoDevices) && $0.contains("<items") }
        await transport.autoReply { stanza in
            guard stanza.hasPrefix("<iq"), stanza.contains(XMPPNamespaces.omemoDevices), let id = extractIQID(from: stanza) else { return nil }
            if stanza.contains("<publish") {
                return "<iq type='error' id='\(id)'><error type='cancel'><forbidden xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            }
            return "<iq type='result' id='\(id)'/>"
        }
        let pepModule = PEPModule()
        let factory = MockXMPPClientFactory(transport: transport, modules: [pepModule, OMEMOModule(pepModule: pepModule)])
        let environment = AppEnvironment(
            store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore(), clientFactory: factory
        )
        let accountID = try await environment.accountService.createAccount(jidString: "alice@example.com", host: "example.com", port: 5222)
        let account = try #require(environment.accountService.accounts.first { $0.id == accountID })
        let ran = OSAllocatedUnfairLock(initialState: false)

        let command = Task { @MainActor in
            try await ConnectedOperation.run(environment: environment, account: account, password: "secret") {
                ran.withLock { $0 = true }
                // The refused publish went out before the command ran.
                return await transport.sentBytes.contains {
                    let stanza = String(decoding: $0, as: UTF8.self)
                    return stanza.contains("<publish") && stanza.contains(XMPPNamespaces.omemoDevices)
                }
            }
        }
        await Self.simulateNoTLSConnect(transport)
        await transport.waitForBlockedSend()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!ran.withLock { $0 })

        await transport.releaseBlockedSends()
        #expect(try await command.value)
        #expect(environment.accountService.connectedClient(for: accountID) == nil)
    }

    /// Plays the server's side of a sign-in without TLS, binding `alice@example.com/ducko`.
    private static func simulateNoTLSConnect(_ transport: MockTransport) async {
        await transport.waitForSent(count: 1)
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(testFeaturesNoTLS)
        await transport.waitForSent(count: 2)
        await transport.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        await transport.waitForSent(count: 3)
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(testFeaturesBind)
        await transport.waitForSent(count: 4)
        await transport.simulateReceive("""
        <iq type='result' id='ducko-1'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>alice@example.com/ducko</jid></bind></iq>
        """)
    }
}

struct OMEMOSetupRetryLineTests {
    /// Under `--output json`, stdout carries only JSON records, so a retry that does not start prints an error record.
    @Test(arguments: [(OMEMOSetupRetryOutcome.started, "command_result"), (.notConnected, "error"), (.notNeeded, "error")])
    func `each outcome prints one JSON record`(outcome: OMEMOSetupRetryOutcome, type: String) throws {
        let line = omemoSetupRetryLine(outcome, accountID: UUID(), formatter: JSONFormatter())
        let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        #expect(record["type"] == type)
        #expect(!line.contains("\n"))
    }
}
