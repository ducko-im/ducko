import Foundation
import Testing
@testable import DuckoXMPP

/// An OMEMO 2 session record that an earlier Ducko stored, in `Fixtures/OMEMO2/session-upgrade.json`: bob's session
/// after he read alice's key exchange and her third message, skipping her second, and replied. The fixture carries her
/// second message and the one she sent after reading his reply.
struct OMEMOSessionUpgradeTests {
    private struct Fixture: Decodable {
        struct Message: Decodable {
            let keyMaterial: Data
            let authenticatedMessage: Data
        }

        let session: Data
        let associatedData: Data
        let messages: [Message]
    }

    private static func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "session-upgrade", withExtension: "json", subdirectory: "Fixtures/OMEMO2"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func `a stored session record restores and serializes to the same bytes`() throws {
        let fixture = try Self.fixture()

        let session = try OMEMOSession(serialized: Array(fixture.session), associatedData: Array(fixture.associatedData))

        #expect(session.serialized == Array(fixture.session))
    }

    @Test func `a restored session decrypts the peer's skipped and next messages`() throws {
        let fixture = try Self.fixture()
        var session = try OMEMOSession(serialized: Array(fixture.session), associatedData: Array(fixture.associatedData))
        try #require(fixture.messages.count == 2)

        for message in fixture.messages {
            let decrypted = try session.decrypt(.omemo2(OMEMOAuthenticatedMessage(serialized: Array(message.authenticatedMessage))))

            #expect(decrypted == Array(message.keyMaterial))
        }
    }
}
