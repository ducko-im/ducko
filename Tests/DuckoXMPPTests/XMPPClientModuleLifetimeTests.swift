import DuckoTestSupport
import Testing
@testable import DuckoXMPP

struct XMPPClientModuleLifetimeTests {
    /// A module holds the context its client gave it, so that context must not hold the module in turn.
    @Test(arguments: [false, true])
    func `a client's modules go with it`(disconnects: Bool) async throws {
        var client: XMPPClient? = XMPPClient(
            domain: "example.com", credentials: .init(username: "user", password: "pass"),
            transport: MockTransport()
        )
        var module: PingModule? = PingModule()
        weak let releasedModule = module
        if let module { await client?.register(module) }
        module = nil
        if disconnects { await client?.disconnect() }
        client = nil
        // `disconnect()` awaits a teardown task that holds the client, and so its modules, and that task can let go of it
        // a moment later.
        try await eventually { releasedModule == nil }
    }
}
