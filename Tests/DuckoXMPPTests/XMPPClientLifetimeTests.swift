import DuckoTestSupport
import Testing
@testable import DuckoXMPP

struct XMPPClientLifetimeTests {
    @Test(arguments: [false, true])
    func `registered modules do not retain their client`(registerModule: Bool) async throws {
        var client: XMPPClient? = XMPPClient(
            domain: "example.com", credentials: .init(username: "user", password: "pass"),
            transport: MockTransport()
        )
        weak let releasedClient = client
        if registerModule { await client?.register(PingModule()) }
        await client?.disconnect()
        client = nil
        // `disconnect()` awaits a teardown task that holds the client, and that task can let go of it a moment later.
        try await eventually { releasedClient == nil }
    }
}
