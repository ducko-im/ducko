import DuckoXMPP

/// What the client of a reconnect takes over from the one whose stream it tries to resume.
public struct StreamResumeContext: Sendable {
    public let streamManagement: SMResumeState
    public let rooms: MUCResumeState?

    public init(streamManagement: SMResumeState, rooms: MUCResumeState?) {
        self.streamManagement = streamManagement
        self.rooms = rooms
    }
}

public protocol XMPPClientFactory: Sendable {
    func makeClient(
        account: Account,
        password: String,
        resuming: StreamResumeContext?,
        requireTLSOverride: Bool?,
        omemoService: OMEMOService?
    ) async -> (XMPPClient, StreamManagementModule)
}
