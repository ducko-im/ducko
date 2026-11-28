import DuckoCore
import DuckoData
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

/// `/omemo-devices` prints what `omemo devices` prints for the one address it names.
@MainActor
struct OMEMODevicesREPLTests {
    private static let storedFingerprint = "0fd5e4fad8f18fa13f85465f9dc312c5c17d0c8242439220b6db11a5498f3ae9"
    private static let displayFingerprint = "d9f71a68 33945da8 bda259e2 9a179ad2 e5092fe1 4d7372af 800da323 3b16ce4f"

    /// A REPL session for `alice@example.com`, offline, whose store holds bob's devices `deviceIDs`, trusted.
    private static func context(formatter: any CLIFormatter, storing deviceIDs: [UInt32]) async throws -> REPLContext {
        let omemoStore = try SwiftDataOMEMOStore(modelContainer: ModelContainerFactory.makeContainer(inMemory: true))
        for deviceID in deviceIDs {
            try await omemoStore.saveTrust(OMEMOTrust(
                accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: deviceID,
                fingerprint: storedFingerprint, trustLevel: .trusted
            ))
        }
        let environment = AppEnvironment(
            store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore(), omemoStore: omemoStore
        )
        let accountID = try await environment.accountService.createAccount(jidString: "alice@example.com", host: "example.com", port: 5222)
        return try REPLContext(formatter: formatter, environment: environment, accountID: accountID, accountJID: #require(BareJID.parse("alice@example.com")))
    }

    @Test func `each device is listed with its fingerprint and trust`() async throws {
        let context = try await Self.context(formatter: PlainFormatter(), storing: [7, 8])

        let lines = await omemoDevicesREPLLines("bob@example.com", context: context)

        #expect(lines.sorted() == [
            "  7  \(Self.displayFingerprint)  [trusted]",
            "  8  \(Self.displayFingerprint)  [trusted]"
        ])
    }

    @Test func `a device is one JSON record with its raw fingerprint and versions`() async throws {
        let context = try await Self.context(formatter: JSONFormatter(), storing: [7])

        let lines = await omemoDevicesREPLLines("bob@example.com", context: context)

        let line = try #require(lines.first)
        #expect(lines.count == 1)
        var object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object.removeValue(forKey: "versions") as? [String] == [])
        #expect(object as? [String: String] == [
            "type": "omemo_device", "jid": "bob@example.com", "device_id": "7",
            "fingerprint": Self.storedFingerprint, "display_fingerprint": Self.displayFingerprint, "trust": "trusted"
        ])
    }

    @Test func `an address without devices prints the empty result`() async throws {
        let context = try await Self.context(formatter: JSONFormatter(), storing: [])

        let lines = await omemoDevicesREPLLines("bob@example.com", context: context)

        #expect(lines == [JSONFormatter().formatEmptyResult(.omemoDevices(jid: "bob@example.com", accountID: context.accountID))])
    }

    @Test(arguments: ["bob@example.com 7", "bob@example.com  extra"])
    func `more than one argument prints the usage`(arguments: String) async throws {
        let context = try await Self.context(formatter: PlainFormatter(), storing: [7])

        let lines = await omemoDevicesREPLLines(arguments, context: context)

        #expect(lines == [PlainFormatter().formatUsageError("Usage: /omemo-devices <jid>")])
    }
}
