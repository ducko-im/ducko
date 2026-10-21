extension XMPPClient {
    /// The SCRAM mechanism whose server signature this client checked during sign-in, or `nil` when no sign-in got that
    /// far. It stays set when the connection fails afterwards, such as at resource binding, because the server proved it
    /// knows the password either way.
    public nonisolated var verifiedSCRAMMechanism: String? {
        verifiedSCRAMMechanismLock.withLock { $0 }
    }

    func recordVerifiedSCRAMMechanism(_ mechanism: String?) {
        guard let mechanism else { return }
        verifiedSCRAMMechanismLock.withLock { $0 = mechanism }
    }
}
