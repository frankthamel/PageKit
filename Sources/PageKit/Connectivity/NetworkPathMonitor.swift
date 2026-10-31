import Foundation
import Network

/// Watches the system network path with `NWPathMonitor`.
public struct NetworkPathMonitor: ConnectivityMonitoring {
    /// Creates a monitor. Nothing runs until `updates()` is iterated.
    public init() {}

    /// Starts a fresh `NWPathMonitor` per stream and cancels it when the stream ends.
    public func updates() -> AsyncStream<ConnectivityStatus> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(Self.status(from: path))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "PageKit.connectivity"))
        }
    }

    static func status(from path: NWPath) -> ConnectivityStatus {
        ConnectivityStatus(
            isOnline: path.status == .satisfied,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}
