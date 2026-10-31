import Foundation
@testable import PageKit

/// An `NSCache` that keeps everything until told to remove it.
///
/// A real `NSCache` empties itself on a critical memory warning, however little it holds,
/// and a busy machine can send one mid-test. Tests that need a page to stay in memory
/// use this, so they pass or fail on PageKit's behaviour and not the machine's.
///
/// `@unchecked Sendable` is safe because `entries` is only touched while holding `lock`.
final class PinnedCache: NSCache<NSString, AnyObject>, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [NSString: AnyObject] = [:]

    override func object(forKey key: NSString) -> AnyObject? {
        lock.withLock { entries[key] }
    }

    override func setObject(_ object: AnyObject, forKey key: NSString, cost: Int) {
        lock.withLock { entries[key] = object }
    }

    override func removeObject(forKey key: NSString) {
        lock.withLock { entries[key] = nil }
    }

    override func removeAllObjects() {
        lock.withLock { entries.removeAll() }
    }
}

extension MemoryPageCache {
    /// A cache for tests, whose entries stay until PageKit removes them.
    static func pinned() -> MemoryPageCache {
        MemoryPageCache(costLimit: 1_000_000, cache: PinnedCache())
    }
}
