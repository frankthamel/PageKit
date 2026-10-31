import Foundation

/// Library-wide actions that are not tied to one paginator.
///
/// Use them for a "Clear cache" button, on sign-out, or from a background task.
public enum PageKit {
    private static let maintenanceDelay: UInt64 = 5_000_000_000
    static let maintenanceGate = OnceFlag()

    /// Deletes one feed from memory and from both disk locations.
    /// - Parameter feedID: The `feedID` the paginator was created with.
    public static func clear(feedID: String) async {
        await clear(feedID: feedID, stores: allStores, memory: .shared)
    }

    /// Deletes every cached feed from memory and from both disk locations.
    public static func clearAll() async {
        await clearAll(stores: allStores, memory: .shared)
    }

    /// Deletes feeds that are past their `maxAge`, then trims the caches folder
    /// to its size limit by deleting the least recently updated feeds.
    ///
    /// `.durable` feeds are never trimmed by size. It runs by itself shortly
    /// after the first feed opens, and can also be called from a background
    /// task such as `BGAppRefreshTask`.
    public static func performMaintenance() async {
        await performMaintenance(caches: .shared(for: .caches), durable: .shared(for: .durable))
    }

    /// Empties the in-memory page cache. Pages saved on disk stay.
    public static func clearMemoryCache() {
        clearMemoryCache(.shared)
    }

    // MARK: Internal overloads, for tests

    static func clear(feedID: String, stores: [DiskPageStore], memory: MemoryPageCache) async {
        memory.removeFeed(feedID)
        for store in stores { await store.removeFeed(feedID) }
    }

    static func clearAll(stores: [DiskPageStore], memory: MemoryPageCache) async {
        memory.removeAll()
        for store in stores { await store.removeAll() }
    }

    static func clearMemoryCache(_ memory: MemoryPageCache) {
        memory.removeAll()
    }

    static func performMaintenance(
        caches: DiskPageStore, durable: DiskPageStore, now: @escaping @Sendable () -> Date = Date.init
    ) async {
        let maintenance = DiskMaintenance(now: now)
        await maintenance.sweep(store: caches, evictsBySize: true)
        await maintenance.sweep(store: durable, evictsBySize: false)
    }

    /// Starts maintenance in the background, a few seconds after the first feed opens.
    /// Only the first call per launch does anything; later calls return `nil`.
    /// - Returns: The task that was started, so tests can wait for it.
    @discardableResult
    static func scheduleMaintenanceOnce(
        gate: OnceFlag = maintenanceGate,
        delayNanoseconds: UInt64 = maintenanceDelay,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        perform: @escaping @Sendable () async -> Void = { await performMaintenance() }
    ) -> Task<Void, Never>? {
        guard gate.claim() else { return nil }
        return Task(priority: .background) {
            await sleep(delayNanoseconds)
            await perform()
        }
    }

    private static var allStores: [DiskPageStore] {
        [.shared(for: .caches), .shared(for: .durable)]
    }
}

/// A flag that can be claimed exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// `true` for the first caller, `false` for every later one.
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
