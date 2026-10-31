import Foundation

/// Everything outside itself that a ``Paginator`` depends on, gathered so tests can
/// replace each effect.
struct PaginatorEnvironment: Sendable {
    /// The longest single wait, one day, whatever a `RetryPolicy` is set to.
    private static let maxSleep: TimeInterval = 86_400

    let memory: MemoryPageCache
    let disk: DiskPageStore
    let connectivity: any ConnectivityMonitoring
    let sleep: Sleep
    let now: @Sendable () -> Date
    /// Starts the once-per-launch disk sweep. Does nothing unless set, so that injected
    /// environments stay away from the real caches folders.
    var scheduleMaintenance: @Sendable () -> Void = {}
    /// Runs before every disk read, so tests can hold a read part way through a restore.
    var beforeDiskRead: @Sendable () async -> Void = {}
    /// Runs before every queued disk write lands, so tests can hold a write back.
    var beforeDiskWrite: @Sendable () async -> Void = {}

    /// The real caches, clock and sleep.
    /// - Parameters:
    ///   - configuration: Picks which disk location the feed uses.
    ///   - connectivity: The source of network status.
    static func live(
        configuration: PaginationConfiguration, connectivity: any ConnectivityMonitoring
    ) -> PaginatorEnvironment {
        PaginatorEnvironment(
            memory: .shared,
            disk: .shared(for: configuration.storage),
            connectivity: connectivity,
            sleep: { try await Task.sleep(nanoseconds: nanoseconds(for: $0)) },
            now: Date.init,
            scheduleMaintenance: { PageKit.scheduleMaintenanceOnce() }
        )
    }

    /// `seconds` as nanoseconds, kept to a range that cannot overflow `UInt64`.
    static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(min(seconds, maxSleep) * 1_000_000_000)
    }
}
