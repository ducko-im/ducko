extension XMPPClient {
    /// Closes the connection once `signInTimeout` has passed, unless the returned task is cancelled first. Before the
    /// session starts, the sign-in then fails with ``XMPPClientError/timeout``. After, the session ends as a lost
    /// connection.
    func startSignInDeadline() -> Task<Void, Never> {
        let timeout = signInTimeout
        return Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.signInDeadlineElapsed()
        }
    }

    /// Runs on the actor, so a window that ended before it ran has already cancelled its task.
    private func signInDeadlineElapsed() async {
        guard !Task.isCancelled else { return }
        signInDeadlineFired = true
        await connection.disconnect()
    }
}
