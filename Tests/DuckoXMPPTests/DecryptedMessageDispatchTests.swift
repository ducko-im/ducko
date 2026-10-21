import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

/// A message rebuilt from an encrypted one reaches every module the client holds, as a received stanza does.
struct DecryptedMessageDispatchTests {
    private final class RecordingModule: XMPPModule {
        let context = OSAllocatedUnfairLock<ModuleContext?>(initialState: nil)
        let decrypted = OSAllocatedUnfairLock<[String?]>(initialState: [])

        func setUp(_ context: ModuleContext) {
            self.context.withLock { $0 = context }
        }

        func handleDecryptedMessage(_ message: XMPPMessage) {
            decrypted.withLock { $0.append(message.id) }
        }
    }

    private final class OtherModule: XMPPModule {
        let decrypted = OSAllocatedUnfairLock<[String?]>(initialState: [])

        func setUp(_: ModuleContext) {}

        func handleDecryptedMessage(_ message: XMPPMessage) {
            decrypted.withLock { $0.append(message.id) }
        }
    }

    @Test func `a module's decrypted message goes to every registered module`() async throws {
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: MockTransport())
        let first = RecordingModule()
        let second = OtherModule()
        await client.register(first)
        await client.register(second)

        try #require(first.context.withLock { $0 }).dispatchDecryptedMessage(XMPPMessage(type: .chat, id: "m1"))

        #expect(first.decrypted.withLock { $0 } == ["m1"])
        #expect(second.decrypted.withLock { $0 } == ["m1"])
    }
}
