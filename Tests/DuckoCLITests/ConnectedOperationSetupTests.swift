import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoCLI

/// A one-shot command connects, waits for the first OMEMO setup attempt and the publications after it, runs, and
/// disconnects, whatever the attempt's outcome.
@MainActor
struct ConnectedOperationSetupTests {
    @Test func `a one-shot command runs only once the first setup attempt had its outcome, also a refusal`() async throws {
        let transport = MockTransport()
        // The setup's read of the account's list is held, the legacy list is empty, and the device-list publish refused.
        await transport.blockSends { $0.contains(XMPPNamespaces.omemoDevices) && $0.contains("<items") }
        await transport.autoReply { stanza in
            guard stanza.hasPrefix("<iq"), let id = extractIQID(from: stanza) else { return nil }
            if stanza.contains(XMPPNamespaces.omemoLegacyDeviceList) {
                return "<iq type='result' id='\(id)'/>"
            }
            guard stanza.contains(XMPPNamespaces.omemoDevices) else { return nil }
            if stanza.contains("<publish") {
                return "<iq type='error' id='\(id)'><error type='cancel'><forbidden xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            }
            return "<iq type='result' id='\(id)'/>"
        }
        let (environment, account) = try await Self.makeEnvironment(transport: transport)
        let ran = OSAllocatedUnfairLock(initialState: false)

        let command = Task { @MainActor in
            try await ConnectedOperation.run(environment: environment, account: account, password: "secret") {
                ran.withLock { $0 = true }
                // The refused publish went out before the command ran.
                return await Self.hasSentPublish(to: XMPPNamespaces.omemoDevices, on: transport)
            }
        }
        await Self.simulateNoTLSConnect(transport)
        await transport.waitForBlockedSend()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!ran.withLock { $0 })

        await transport.releaseBlockedSends()
        #expect(try await command.value)
        #expect(environment.accountService.connectedClient(for: account.id) == nil)
    }

    @Test func `a one-shot command runs only once this device is published for legacy OMEMO`() async throws {
        let transport = MockTransport()
        // Every PubSub request succeeds, and the legacy device-list publish that ends the legacy publication is held.
        await transport.blockSends { $0.contains("<publish") && $0.contains(XMPPNamespaces.omemoLegacyDeviceList) }
        await transport.autoReply { stanza in
            guard stanza.hasPrefix("<iq"), stanza.contains(XMPPNamespaces.pubsub), let id = extractIQID(from: stanza) else { return nil }
            return "<iq type='result' id='\(id)'/>"
        }
        let (environment, account) = try await Self.makeEnvironment(transport: transport)
        let ran = OSAllocatedUnfairLock(initialState: false)

        let command = Task { @MainActor in
            try await ConnectedOperation.run(environment: environment, account: account, password: "secret") {
                ran.withLock { $0 = true }
                return await Self.hasSentPublish(to: XMPPNamespaces.omemoLegacyDeviceList, on: transport)
            }
        }
        await Self.simulateNoTLSConnect(transport)
        // A command that disconnected before the publish went out would leave nothing to hold.
        let held = try await boundedOutcome { await transport.waitForBlockedSend() }
        try #require(held != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!ran.withLock { $0 })

        await transport.releaseBlockedSends()
        #expect(try await command.value)
        #expect(environment.accountService.connectedClient(for: account.id) == nil)
    }

    /// An environment whose one account, `alice@example.com`, connects through `transport` with a fresh OMEMO module.
    private static func makeEnvironment(transport: MockTransport) async throws -> (AppEnvironment, DuckoCore.Account) {
        let pepModule = PEPModule()
        let factory = MockXMPPClientFactory(transport: transport, modules: [pepModule, OMEMOModule(pepModule: pepModule)])
        let environment = AppEnvironment(
            store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore(), clientFactory: factory
        )
        let accountID = try await environment.accountService.createAccount(jidString: "alice@example.com", host: "example.com", port: 5222)
        let account = try #require(environment.accountService.accounts.first { $0.id == accountID })
        return (environment, account)
    }

    private static func hasSentPublish(to node: String, on transport: MockTransport) async -> Bool {
        await transport.sentBytes.contains {
            let stanza = String(decoding: $0, as: UTF8.self)
            return stanza.contains("<publish") && stanza.contains(node)
        }
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
