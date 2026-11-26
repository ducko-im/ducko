import DuckoXMPP

extension XMPPClient {
    /// Connects to the account's configured host and port, or looks its server up when either is missing. A port
    /// outside 1...65535 stored with a host fails as `invalidPort` rather than reaching the connection.
    func connect(to account: Account) async throws {
        guard let host = account.host, let port = account.port else {
            try await connect()
            return
        }
        guard let checked = UInt16(exactly: port), checked > 0 else {
            throw AccountService.AccountServiceError.invalidPort(port)
        }
        try await connect(host: host, port: checked)
    }
}
