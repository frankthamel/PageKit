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
}

extension PaginatorEnvironment {
    /// An isolated environment: its own caches, faked connectivity and an instant sleep
    /// that still honours cancellation, as `Task.sleep` does.
    static func testing(
        memory: MemoryPageCache = MemoryPageCache(costLimit: 1_000_000),
        connectivity: any ConnectivityMonitoring = FakeConnectivity()
    ) -> PaginatorEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageKitTests-\(UUID().uuidString)", isDirectory: true)
        return PaginatorEnvironment(
            memory: memory,
            disk: DiskPageStore(root: root),
            connectivity: connectivity,
            sleep: { _ in try Task.checkCancellation() },
            now: Date.init
        )
    }
}
