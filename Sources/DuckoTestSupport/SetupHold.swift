import DuckoXMPP

/// With `release`, holds a session's setup, once it is connected, until `release` is signaled. With `failure`, the
/// setup then fails with it.
public final class SetupHold: XMPPModule {
    private let release: AsyncSemaphore?
    private let failure: (any Error)?

    public init(release: AsyncSemaphore? = nil, failure: (any Error)? = nil) {
        self.release = release
        self.failure = failure
    }

    public func setUp(_: ModuleContext) {}

    public func handleConnect() async throws {
        await release?.wait()
        if let failure { throw failure }
    }
}
