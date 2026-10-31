/// How a feed uses its caches.
public enum CachePolicy: Sendable {
    /// Never read or write a cache, for data that must be live such as prices.
    case networkOnly

    /// Never use the network, for offline mode.
    case cacheOnly

    /// Try the network and fall back to the cache on failure.
    case networkFirst

    /// Show cached pages at once, then refresh. The default.
    case cacheThenNetwork
}
