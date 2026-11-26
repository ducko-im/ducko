import DuckoXMPP

/// With `entered`, signals it once a session's setup is reached, after the session connected. With `release`, then holds
/// the setup until `release` is signaled. With `failure`, the setup then fails with it.
public final class SetupHold: XMPPModule {
    private let entered: AsyncSemaphore?
    private let release: AsyncSemaphore?
    private let failure: (any Error)?

    public init(entered: AsyncSemaphore? = nil, release: AsyncSemaphore? = nil, failure: (any Error)? = nil) {
        self.entered = entered
        self.release = release
        self.failure = failure
    }

    public func setUp(_: ModuleContext) {}

    public func handleConnect() async throws {
        await entered?.signal()
        await release?.wait()
        if let failure { throw failure }
    }
}
