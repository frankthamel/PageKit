import Foundation
@testable import PageKit

/// A connectivity source a test can flip by hand. Supports any number of listeners.
final class FakeConnectivity: ConnectivityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [UUID: AsyncStream<ConnectivityStatus>.Continuation] = [:]
    private var current: ConnectivityStatus

    /// Creates a fake that starts with the given status.
    init(initial: ConnectivityStatus = .online) {
        current = initial
    }

    /// Each listener first receives the current status, then every later change.
    func updates() -> AsyncStream<ConnectivityStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectivityStatus.self)
        lock.lock()
        listeners[id] = continuation
        let snapshot = current
        lock.unlock()
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            self?.lock.lock()
            self?.listeners[id] = nil
            self?.lock.unlock()
        }
        return stream
    }

    /// Flips the status and delivers it to every listener.
    func set(_ status: ConnectivityStatus) {
        lock.lock()
        current = status
        let active = Array(listeners.values)
        lock.unlock()
        active.forEach { $0.yield(status) }
    }

    /// Shorthand for flipping between plain online and offline.
    func setOnline(_ isOnline: Bool) {
        set(ConnectivityStatus(isOnline: isOnline))
    }
}
