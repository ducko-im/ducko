import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

private enum PreparationSuspension: CaseIterable, Sendable {
    case beforeStart, afterStart, discovery
}

private final class PreparationProbe: Sendable {
    private struct Captured {
        var listener: SOCKS5Listener?
        var iqs: [XMPPIQ] = []
        var events: [XMPPEvent] = []
    }

    private let captured = OSAllocatedUnfairLock(initialState: Captured())
    let entered = AsyncSemaphore()
    let release = AsyncSemaphore()
    let suspension: PreparationSuspension

    init(suspension: PreparationSuspension) {
        self.suspension = suspension
    }

    func start(_ listener: SOCKS5Listener) async throws -> UInt16 {
        captured.withLock { $0.listener = listener }
        if suspension == .beforeStart { await pause() }
        let port = try await listener.start()
        if suspension == .afterStart { await pause() }
        return port
    }

    private func pause() async {
        await entered.signal()
        await release.wait()
    }

    func context() -> ModuleContext {
        ModuleContext(
            sendStanza: { _, onAccepted in onAccepted?() },
            sendIQ: { [self] iq, _ in
                captured.withLock { $0.iqs.append(iq) }
                if suspension == .discovery, iq.childElement?.namespace == XMPPNamespaces.discoItems { await pause() }
                return nil
            },
            emitEvent: { [self] event in captured.withLock { $0.events.append(event) } },
            generateID: { "preparation-iq" },
            connectedJID: { FullJID.parse("alice@example.com/test") }, domain: "example.com"
        )
    }

    func verifyNoPublishedSessionAndClosedListener() async throws {
        let snapshot = captured.withLock { $0 }
        #expect(!snapshot.iqs.contains { $0.childElement?.attribute("action") == "session-initiate" })
        #expect(snapshot.events.isEmpty)
        let listener = try #require(snapshot.listener)
        do {
            let unexpected = try await listener.accept(expectedDstAddr: "unused", timeout: 0.1)
            await unexpected.close()
            Issue.record("A discarded listener accepted a connection")
        } catch let SOCKS5Listener.ListenerError.acceptFailed(message) {
            #expect(message == "Not listening")
        }
        await listener.close()
    }
}

struct JinglePreparationTests {
    @Test(arguments: PreparationSuspension.allCases, [false, true])
    private func `disconnect or cancellation detaches preparation and closes a late listener`(suspension: PreparationSuspension, cancel: Bool) async throws {
        let probe = PreparationProbe(suspension: suspension)
        let module = JingleModule(localAddresses: { [.init(ip: "127.0.0.1", isIPv4: true)] }, startListener: { try await probe.start($0) })
        module.setUp(probe.context())
        let peer = try #require(FullJID.parse("bob@example.com/test"))
        let operation = Task { try await module.initiateFileTransfer(to: peer, file: JingleFileDescription(name: "sample.txt", size: 3)) }
        defer { operation.cancel(); Task { await probe.release.signal(); await module.handleDisconnect() } }
        let arrived = try await boundedOutcome { await probe.entered.wait() }
        try #require(arrived != nil)
        if cancel {
            operation.cancel()
        } else {
            await module.handleDisconnect()
        }
        await probe.release.signal()
        let finished = try await boundedOutcome {
            do {
                _ = try await operation.value
                Issue.record("Detached preparation returned a live session")
            } catch is CancellationError {
                #expect(cancel)
            } catch let error as JingleModule.JingleError {
                #expect(error == .sessionNotFound)
            }
        }
        try #require(finished != nil)
        try finished?.get()
        try await probe.verifyNoPublishedSessionAndClosedListener()
        await module.handleDisconnect()
    }
}
