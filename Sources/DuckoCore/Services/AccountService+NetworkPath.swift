import DuckoXMPP
import Foundation

extension AccountService {
    func startNetworkMonitoring(_ source: NetworkPathSource) {
        networkMonitorTask = Task { [weak self] in
            for await hasRoute in source.updates() {
                self?.networkPathChanged(hasRoute: hasRoute)
            }
        }
    }

    func stopNetworkMonitoring() {
        networkMonitorTask?.cancel()
        networkMonitorTask = nil
    }

    /// Starts the account's scheduled retry once it is due, or, without a network route, leaves it waiting for one.
    func startScheduledRetry(for accountID: UUID) {
        guard let due = connectionResources[accountID]?.retryDue else { return }
        guard hasNetworkRoute else {
            connectionResources[accountID]?.reconnectTask = nil
            connectionStates[accountID] = .error(Self.noNetworkMessage)
            return
        }
        connectionResources[accountID]?.reconnectTask = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            connectionResources[accountID]?.retryDue = nil
            do {
                try await performConnect(accountID: accountID)
            } catch {
                // A requested disconnect, a newer connect, or a drop that schedules its own retry cancels this task.
                guard !Task.isCancelled, Self.isRetryable(error) else { return }
                scheduleReconnect(accountID: accountID)
            }
        }
    }

    /// A lost route pauses every retry that has not started connecting, keeping when it is due. A returning route
    /// starts the paused ones, each no sooner than it was due, so a flapping network cannot beat the backoff. Either
    /// way every live session is pinged, and one that does not answer ends as lost.
    func networkPathChanged(hasRoute: Bool) {
        hasNetworkRoute = hasRoute
        for (accountID, resources) in connectionResources {
            if hasRoute {
                if resources.awaitingRoute {
                    startScheduledRetry(for: accountID)
                }
            } else if resources.retryDue != nil, let retry = resources.reconnectTask {
                retry.cancel()
                startScheduledRetry(for: accountID)
            }
            if let client = resources.client {
                let timeout = networkProbeTimeout
                Task { await client.module(ofType: PingModule.self)?.checkLiveness(timeout: timeout) }
            }
        }
    }
}
