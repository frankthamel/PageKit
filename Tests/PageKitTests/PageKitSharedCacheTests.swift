import Foundation
import Testing
@testable import PageKit

/// The public `PageKit` actions, on the real shared caches. Each test uses a feed of its
/// own, and they run one at a time because `clearAll()` touches every feed.
@Suite(.watchdog, .serialized) struct PageKitSharedCacheTests {
    private let feedID = "PageKitSharedCacheTests-\(UUID().uuidString)"
    private let caches = DiskPageStore.shared(for: .caches)
    private let durable = DiskPageStore.shared(for: .durable)

    private func rememberPage() {
        let page = Page<TestItem, CursorToken>(items: [TestItem(id: 1)], nextToken: nil)
        MemoryPageCache.shared.store(page, for: PageKey(feedID: feedID, token: FeedSeeding.token), cost: 10)
    }

    @Test func clearRemovesAFeedFromBothRootsAndMemory() async {
        await FeedSeeding.seed(caches, feedID: feedID, updatedAt: Date())
        await FeedSeeding.seed(durable, feedID: feedID, updatedAt: Date(), storage: .durable)
        rememberPage()

        await PageKit.clear(feedID: feedID)

        #expect(await FeedSeeding.hasManifest(caches, feedID: feedID) == false)
        #expect(await FeedSeeding.hasManifest(durable, feedID: feedID) == false)
        #expect(MemoryPageCache.shared.keyCount(for: feedID) == 0)
    }

    @Test func clearAllRemovesEveryFeed() async {
        await FeedSeeding.seed(caches, feedID: feedID, updatedAt: Date())
        rememberPage()

        await PageKit.clearAll()

        #expect(await FeedSeeding.hasManifest(caches, feedID: feedID) == false)
        #expect(MemoryPageCache.shared.keyCount(for: feedID) == 0)
    }

    @Test func clearMemoryCacheLeavesTheDisk() async {
        await FeedSeeding.seed(caches, feedID: feedID, updatedAt: Date())
        rememberPage()

        PageKit.clearMemoryCache()

        #expect(MemoryPageCache.shared.keyCount(for: feedID) == 0)
        #expect(await FeedSeeding.hasManifest(caches, feedID: feedID))
        await caches.removeFeed(feedID)
    }

    @Test func performMaintenanceDeletesAnExpiredFeed() async {
        await FeedSeeding.seed(caches, feedID: feedID, updatedAt: Date(timeIntervalSince1970: 0))

        await PageKit.performMaintenance()

        #expect(await FeedSeeding.hasManifest(caches, feedID: feedID) == false)
    }

    @Test func scheduledMaintenanceRunsTheRealSweep() async {
        await FeedSeeding.seed(caches, feedID: feedID, updatedAt: Date(timeIntervalSince1970: 0))

        await PageKit.scheduleMaintenanceOnce(gate: OnceFlag(), priority: .medium, delayNanoseconds: 0)?.value

        #expect(await FeedSeeding.hasManifest(caches, feedID: feedID) == false)
    }

    @Test func liveEnvironmentSleepsAndSchedulesMaintenance() async throws {
        let environment = PaginatorEnvironment.live(configuration: .testing, connectivity: FakeConnectivity())

        try await environment.sleep(0)
        environment.scheduleMaintenance()

        #expect(PageKit.maintenanceGate.claim() == false)
    }
}
