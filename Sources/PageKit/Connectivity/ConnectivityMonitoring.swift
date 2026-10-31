/// Reports changes in network connectivity. Wrapped in a protocol so tests can fake it.
public protocol ConnectivityMonitoring: Sendable {
    /// A stream that yields the current status first, then every change.
    func updates() -> AsyncStream<ConnectivityStatus>
}
