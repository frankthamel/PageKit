import Foundation

/// Tunes a ``Paginator``. Every value has a safe default, so most apps change nothing.
public struct PaginationConfiguration: Sendable {
    /// How the memory and disk caches are used.
    public var cachePolicy: CachePolicy = .cacheThenNetwork

    /// Start loading the next page when this many items remain.
    public var prefetchDistance = 5

    /// How many pages to read ahead in the background.
    public var lookaheadPages = 1

    /// The memory cache budget, in bytes.
    public var memoryCostLimit = 20 * 1024 * 1024

    /// The disk cache budget, in bytes.
    public var diskSizeLimit = 50 * 1024 * 1024

    /// Disk entries older than this, in seconds, are deleted.
    public var maxAge: TimeInterval = 7 * 24 * 3600

    /// How failed loads are retried.
    public var retry = RetryPolicy.default

    /// Bump this when the item's shape changes, so old cached files are discarded.
    public var schemaVersion = 1

    /// Where pages are kept on disk.
    public var storage = DiskStorage.caches

    /// Whether to read ahead on expensive (cellular or hotspot) connections.
    /// Off by default to protect the user's data plan.
    public var allowsReadAheadOnExpensiveNetwork = false

    /// Creates a configuration with every default.
    public init() {}
}
