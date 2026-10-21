import DuckoTestSupport
import Testing
@testable import DuckoXMPP

struct XMPPClientModuleLifetimeTests {
    /// A module holds the context its client gave it, so that context must not hold the module in turn.
    @Test(arguments: [false, true])
    func `a client's modules go with it`(disconnects: Bool) async {
        var client: XMPPClient? = XMPPClient(
            domain: "example.com", credentials: .init(username: "user", password: "pass"),
            transport: MockTransport()
        )
        var module: PingModule? = PingModule()
        weak var releasedModule = module
        if let module { await client?.register(module) }
        module = nil
        if disconnects { await client?.disconnect() }
        client = nil
        #expect(releasedModule == nil)
    }
}
