import Foundation
import Testing
@testable import PageKit

@Suite(.watchdog) final class PageKitClearingTests {
    private let cachesRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("PageKitClearingTests-\(UUID().uuidString)", isDirectory: true)
    private var durableRoot: URL { cachesRoot.appendingPathComponent("durable-root", isDirectory: true) }
    private let date = Date(timeIntervalSince1970: 1_000)

    deinit { try? FileManager.default.removeItem(at: cachesRoot) }

    private func makeStores() -> (caches: DiskPageStore, durable: DiskPageStore, memory: MemoryPageCache) {
        (DiskPageStore(root: cachesRoot.appendingPathComponent("caches-root", isDirectory: true)),
         DiskPageStore(root: durableRoot), .pinned())
    }

    private func remember(_ memory: MemoryPageCache, feedID: String) {
        let page = Page<TestItem, CursorToken>(items: [TestItem(id: 1)], nextToken: nil)
        memory.store(page, for: PageKey(feedID: feedID, token: FeedSeeding.token), cost: 10)
    }

    @Test func clearFeedRemovesFromBothRootsAndMemory() async {
        let (caches, durable, memory) = makeStores()
        await FeedSeeding.seed(caches, feedID: "a", updatedAt: date)
        await FeedSeeding.seed(durable, feedID: "a", updatedAt: date, storage: .durable)
        await FeedSeeding.seed(caches, feedID: "b", updatedAt: date)
        remember(memory, feedID: "a")
        remember(memory, feedID: "b")

        await PageKit.clear(feedID: "a", stores: [caches, durable], memory: memory)

        #expect(await FeedSeeding.hasManifest(caches, feedID: "a") == false)
        #expect(await FeedSeeding.hasManifest(durable, feedID: "a") == false)
        #expect(memory.keyCount(for: "a") == 0)
        #expect(await FeedSeeding.hasManifest(caches, feedID: "b"))
        #expect(memory.keyCount(for: "b") == 1)
    }

    @Test func clearAllEmptiesEverything() async {
        let (caches, durable, memory) = makeStores()
        await FeedSeeding.seed(caches, feedID: "a", updatedAt: date)
        await FeedSeeding.seed(durable, feedID: "b", updatedAt: date, storage: .durable)
        remember(memory, feedID: "a")

        await PageKit.clearAll(stores: [caches, durable], memory: memory)

        #expect(await caches.storedFeeds().isEmpty)
        #expect(await durable.storedFeeds().isEmpty)
        #expect(memory.keyCount(for: "a") == 0)
    }

    @Test func clearMemoryCacheLeavesDisk() async {
        let (caches, _, memory) = makeStores()
        await FeedSeeding.seed(caches, feedID: "a", updatedAt: date)
        remember(memory, feedID: "a")

        PageKit.clearMemoryCache(memory)

        #expect(memory.keyCount(for: "a") == 0)
        #expect(await FeedSeeding.hasManifest(caches, feedID: "a"))
    }

    @Test func performMaintenanceSweepsCachesBySizeAndDurableByAgeOnly() async {
        let (caches, durable, _) = makeStores()
        let now = Date(timeIntervalSince1970: 10_000_000)
        await FeedSeeding.seed(caches, feedID: "expired", updatedAt: now.addingTimeInterval(-7_200), maxAge: 3_600)
        await FeedSeeding.seed(durable, feedID: "expired", updatedAt: now.addingTimeInterval(-7_200), maxAge: 3_600, storage: .durable)
        await FeedSeeding.seed(durable, feedID: "big", items: 1_000, updatedAt: now, diskSizeLimit: 1, storage: .durable)

        await PageKit.performMaintenance(caches: caches, durable: durable, now: { now })

        #expect(await FeedSeeding.hasManifest(caches, feedID: "expired") == false)
        #expect(await FeedSeeding.hasManifest(durable, feedID: "expired") == false)
        #expect(await FeedSeeding.hasManifest(durable, feedID: "big"))
    }

    @Test func maintenanceRunsOnlyOnce() async {
        let gate = OnceFlag()
        let runs = Counter()
        let delays = Counter()

        let first = PageKit.scheduleMaintenanceOnce(
            gate: gate, priority: .medium, delayNanoseconds: 3_000,
            sleep: { await delays.add($0) }, perform: { await runs.add(1) }
        )
        let second = PageKit.scheduleMaintenanceOnce(
            gate: gate, delayNanoseconds: 3_000,
            sleep: { await delays.add($0) }, perform: { await runs.add(1) }
        )
        await first?.value

        #expect(first != nil)
        #expect(second == nil)
        #expect(await runs.value == 1)
        #expect(await delays.value == 3_000)
    }
}

private actor Counter {
    private(set) var value: UInt64 = 0
    func add(_ amount: UInt64) { value += amount }
    func add(_ amount: Int) { value += UInt64(amount) }
}
