import Dispatch
import Network

/// Reports whether the network has a route: once when monitoring starts, then on every path change, including one
/// between two paths that both have a route, such as Wi-Fi to Ethernet.
public struct NetworkPathSource: Sendable {
    let updates: @Sendable () -> AsyncStream<Bool>

    public init(updates: @escaping @Sendable () -> AsyncStream<Bool>) {
        self.updates = updates
    }

    /// The system's path monitor, which stops once the stream ends.
    public static let system = NetworkPathSource {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                // A path that requires a connection comes up only when something dials, so it counts as a route.
                continuation.yield(path.status != .unsatisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "im.ducko.core.network-path"))
        }
    }
}
