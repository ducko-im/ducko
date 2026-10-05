import DuckoCore
import DuckoXMPP

public struct MockXMPPClientFactory: XMPPClientFactory {
    let transportForAccount: @Sendable (Account) -> any XMPPTransport
    let modulesForAccount: @Sendable (Account) -> [any XMPPModule]

    public init(transport: any XMPPTransport, modules: [any XMPPModule] = []) {
        self.transportForAccount = { _ in transport }
        self.modulesForAccount = { _ in modules }
    }

    /// Per-account transport and module resolution, for tests that back two simultaneously
    /// connected accounts (e.g. asserting a broadcast reaches each account's own transport).
    public init(
        transportForAccount: @escaping @Sendable (Account) -> any XMPPTransport,
        modulesForAccount: @escaping @Sendable (Account) -> [any XMPPModule] = { _ in [] }
    ) {
        self.transportForAccount = transportForAccount
        self.modulesForAccount = modulesForAccount
    }

    /// Passes on the stream-management part of `resuming`. The modules a test supplies are used as they are, so one
    /// that carries state across a resume has to be seeded by a factory of the test's own.
    public func makeClient(
        account: Account,
        password: String,
        resuming: StreamResumeContext?,
        requireTLSOverride: Bool?,
        omemoService: OMEMOService?
    ) async -> (XMPPClient, StreamManagementModule) {
        var builder = XMPPClientBuilder(
            domain: account.jid.domainPart,
            username: account.jid.localPart ?? "",
            password: password
        )
        builder.withTransport(transportForAccount(account))
        builder.withRequireTLS(false)
        let sm = StreamManagementModule(previousState: resuming?.streamManagement)
        builder.withModule(sm)
        builder.withInterceptor(sm)
        for module in modulesForAccount(account) {
            builder.withModule(module)
        }
        return await (builder.build(), sm)
    }
}
