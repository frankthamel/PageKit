/// Where a feed's pages are kept on disk.
public enum DiskStorage: String, Codable, Sendable {
    /// The system caches folder. iOS may clear it when space runs low. The default.
    case caches

    /// Application Support, excluded from backup and exempt from size eviction.
    /// Use it for apps that promise offline reading.
    case durable
}
