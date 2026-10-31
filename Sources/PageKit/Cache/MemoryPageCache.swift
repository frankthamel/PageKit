import Foundation

/// A process-wide cache of decoded pages, shared by every paginator.
///
/// Memory is a speed-up, never the source of truth: NSCache may drop any entry
/// at any moment, so a miss here falls through to disk and then the network.
///
/// `@unchecked Sendable` is safe because NSCache is internally synchronised
/// and `keys` and `limit` are only touched while holding `lock`.
final class MemoryPageCache: NSObject, NSCacheDelegate, @unchecked Sendable {
    /// The cache every paginator uses unless it is given another.
    static let shared = MemoryPageCache(costLimit: 20 * 1024 * 1024)

    private let cache = NSCache<NSString, AnyObject>()
    private let lock = NSLock()
    /// feedID -> keys, so one feed can be cleared. NSCache cannot list its keys.
    private var keys: [String: Set<NSString>] = [:]

    /// Creates a cache.
    /// - Parameters:
    ///   - costLimit: The most bytes of page content to hold.
    ///   - countLimit: The most pages to hold.
    init(costLimit: Int, countLimit: Int = 200) {
        super.init()
        cache.totalCostLimit = costLimit
        cache.countLimit = countLimit
        cache.name = "PageKit.MemoryPageCache"
        cache.delegate = self
    }

    /// The current cost limit in bytes.
    var costLimit: Int { cache.totalCostLimit }

    /// Raises the cost limit to `limit`. A lower value is ignored, so the
    /// shared cache keeps the largest limit any paginator asked for.
    func raiseCostLimit(to limit: Int) {
        lock.withLock {
            if limit > cache.totalCostLimit { cache.totalCostLimit = limit }
        }
    }

    /// Returns the page stored under `key`, or `nil` on a miss.
    ///
    /// A page stored with different `Item` or `Token` types counts as a miss.
    func page<Item: Sendable, Token: PageToken>(for key: PageKey, as type: Page<Item, Token>.Type) -> Page<Item, Token>? {
        (cache.object(forKey: key.nsKey) as? CachedPage<Item, Token>)?.page
    }

    /// Stores a page.
    /// - Parameters:
    ///   - page: The page to keep.
    ///   - key: Which page of which feed it is.
    ///   - cost: Its size in bytes, usually the length of its encoded JSON.
    func store<Item: Sendable, Token: PageToken>(_ page: Page<Item, Token>, for key: PageKey, cost: Int) {
        // Index first, so an immediate eviction of this entry cleans up after itself.
        lock.withLock { _ = keys[key.feedID, default: []].insert(key.nsKey) }
        cache.setObject(CachedPage(page: page, key: key), forKey: key.nsKey, cost: cost)
    }

    /// Drops every cached page of one feed.
    func removeFeed(_ feedID: String) {
        let feedKeys = lock.withLock { keys.removeValue(forKey: feedID) ?? [] }
        feedKeys.forEach { cache.removeObject(forKey: $0) }
    }

    /// Drops every cached page of every feed.
    func removeAll() {
        cache.removeAllObjects()
        lock.withLock { keys.removeAll() }
    }

    /// How many keys the index holds for a feed. For tests.
    func keyCount(for feedID: String) -> Int {
        lock.withLock { keys[feedID]?.count ?? 0 }
    }

    // Called by NSCache when it evicts on its own (memory pressure, limits).
    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let evicted = obj as? CachedEntry else { return }
        lock.withLock { _ = keys[evicted.feedID]?.remove(evicted.key) }
    }
}
