import Foundation

/// Deletes feeds that are too old or, in the caches root, too big.
///
/// It reads only each manifest's header, so it works with no paginator alive.
struct DiskMaintenance: Sendable {
    /// Disk eviction stops once the root is down to this share of its size limit.
    static let evictionTarget = 0.8

    private let now: @Sendable () -> Date

    /// Creates a maintenance pass.
    /// - Parameter now: The clock used to judge age. Tests pass a fixed one.
    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Cleans one storage root.
    ///
    /// 1. Feeds past their own `maxAge`, and feeds whose manifest cannot be read, are deleted.
    /// 2. If `evictsBySize` is set and what is left exceeds the largest `diskSizeLimit` recorded
    ///    in the root, the least recently updated feeds are deleted whole until the root is
    ///    at 80% of that limit.
    /// - Parameters:
    ///   - store: The root to clean.
    ///   - evictsBySize: `true` for the caches root, `false` for the durable one, which only expires by age.
    func sweep(store: DiskPageStore, evictsBySize: Bool) async {
        let current = now()
        var remaining: [(folder: String, bytes: Int, header: FeedManifestHeader)] = []
        for feed in await store.storedFeeds() {
            if let header = feed.header, current.timeIntervalSince(header.updatedAt) <= header.maxAge {
                remaining.append((feed.folder, feed.bytes, header))
            } else {
                await store.removeFolder(feed.folder)
            }
        }
        guard evictsBySize, let limit = remaining.map(\.header.diskSizeLimit).max() else { return }

        var total = remaining.reduce(0) { $0 + $1.bytes }
        guard total > limit else { return }
        let target = Double(limit) * Self.evictionTarget
        for feed in remaining.sorted(by: { $0.header.updatedAt < $1.header.updatedAt }) where Double(total) > target {
            await store.removeFolder(feed.folder)
            total -= feed.bytes
        }
    }
}
