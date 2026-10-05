import Dispatch
import Network

extension NWListener {
    /// Starts the listener on `queue` and returns the port it is bound to once it is ready. Set `newConnectionHandler`
    /// first. Any `stateUpdateHandler` is replaced.
    func startAndAwaitPort(on queue: DispatchQueue) async throws -> UInt16 {
        let states = AsyncThrowingStream<UInt16, Error>.makeStream()
        stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.port { states.continuation.yield(port.rawValue); states.continuation.finish() }
            case let .failed(error): states.continuation.finish(throwing: error)
            case .cancelled: states.continuation.finish(throwing: CancellationError())
            case .setup, .waiting: break
            @unknown default: break
            }
        }
        start(queue: queue)
        for try await port in states.stream {
            return port
        }
        throw CancellationError()
    }
}
