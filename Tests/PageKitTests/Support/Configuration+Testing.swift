import Foundation
@testable import PageKit

extension PaginationConfiguration {
    /// No caches, no read-ahead and retries that do not wait.
    static var testing: PaginationConfiguration {
        var configuration = PaginationConfiguration()
        configuration.cachePolicy = .networkOnly
        configuration.lookaheadPages = 0
        configuration.retry = RetryPolicy(baseDelay: 0, maxDelay: 0)
        return configuration
    }

    /// `.testing`, on the given cache policy.
    static func testing(_ policy: CachePolicy) -> PaginationConfiguration {
        var configuration = PaginationConfiguration.testing
        configuration.cachePolicy = policy
        return configuration
    }
}

extension PaginatorEnvironment {
    /// An isolated environment: its own caches, faked connectivity and an instant sleep
    /// that still honours cancellation, as `Task.sleep` does.
    static func testing(
        memory: MemoryPageCache = .pinned(),
        connectivity: any ConnectivityMonitoring = FakeConnectivity(),
        sleep: @escaping Sleep = { _ in try Task.checkCancellation() },
        now: @escaping @Sendable () -> Date = Date.init
    ) -> PaginatorEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageKitTests-\(UUID().uuidString)", isDirectory: true)
        return PaginatorEnvironment(
            memory: memory,
            disk: DiskPageStore(root: root),
            connectivity: connectivity,
            sleep: sleep,
            now: now
        )
    }
}
