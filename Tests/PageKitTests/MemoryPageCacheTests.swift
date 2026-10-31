import Testing
@testable import PageKit

@Suite(.watchdog) struct MemoryPageCacheTests {
    private struct UnencodableToken: PageToken {
        init() {}
        init(from decoder: any Decoder) throws { self.init() }
        func encode(to encoder: any Encoder) throws {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "No"))
        }
    }

    @Test func aTokenThatCannotBeEncodedStillMakesAKey() {
        #expect(PageKey(feedID: "a", token: UnencodableToken()).token == String(describing: UnencodableToken()))
    }

    private typealias TestPage = Page<TestItem, IndexToken>

    private func key(_ feed: String, _ page: Int = 1) -> PageKey {
        PageKey(feedID: feed, token: IndexToken(page: page, size: 20))
    }

    private func makePage(_ id: Int = 1) -> TestPage {
        Page(items: [TestItem(id: id)], nextToken: nil)
    }

    @Test func storesAndReturnsAPage() {
        let cache = MemoryPageCache.pinned()
        cache.store(makePage(7), for: key("a"), cost: 10)

        let hit = cache.page(for: key("a"), as: TestPage.self)
        #expect(hit?.items == [TestItem(id: 7)])
    }

    @Test func wrongTypeIsAMiss() {
        let cache = MemoryPageCache.pinned()
        cache.store(makePage(), for: key("a"), cost: 10)

        let miss = cache.page(for: key("a"), as: Page<TestItem, CursorToken>.self)
        #expect(miss == nil)
    }

    @Test func removeFeedLeavesOtherFeeds() {
        let cache = MemoryPageCache.pinned()
        cache.store(makePage(), for: key("a", 1), cost: 10)
        cache.store(makePage(), for: key("a", 2), cost: 10)
        cache.store(makePage(), for: key("b"), cost: 10)

        cache.removeFeed("a")

        #expect(cache.page(for: key("a", 1), as: TestPage.self) == nil)
        #expect(cache.page(for: key("a", 2), as: TestPage.self) == nil)
        #expect(cache.page(for: key("b"), as: TestPage.self) != nil)
    }

    @Test func removeAllEmptiesEverything() {
        let cache = MemoryPageCache.pinned()
        cache.store(makePage(), for: key("a"), cost: 10)
        cache.store(makePage(), for: key("b"), cost: 10)

        cache.removeAll()

        #expect(cache.page(for: key("a"), as: TestPage.self) == nil)
        #expect(cache.page(for: key("b"), as: TestPage.self) == nil)
        #expect(cache.keyCount(for: "a") == 0)
    }

    @Test func evictionKeepsTheKeyIndexHonest() {
        let cache = MemoryPageCache(costLimit: 1_000_000, countLimit: 1)
        // A real cache that holds entries has to outlive any eviction. See `MemoryPageCache`.
        _ = Unmanaged.passRetained(cache)
        cache.store(makePage(), for: key("a", 1), cost: 10)
        cache.store(makePage(), for: key("a", 2), cost: 10)

        cache.removeFeed("a")
        #expect(cache.keyCount(for: "a") == 0)

        cache.store(makePage(), for: key("a", 1), cost: 10)
        cache.store(makePage(), for: key("a", 2), cost: 10)
        // A memory warning may take the survivor as well, even between the two reads, so the
        // index must match what is really there, and only a lasting mismatch counts.
        let indexIsHonest = (0..<1_000).contains { _ in
            let survivors = [1, 2].filter { cache.page(for: key("a", $0), as: TestPage.self) != nil }
            return cache.keyCount(for: "a") == survivors.count
        }
        #expect(indexIsHonest)
    }

    @Test func restoringSameKeyKeepsItInTheIndex() {
        let cache = MemoryPageCache.pinned()
        cache.store(makePage(1), for: key("a"), cost: 10)
        cache.store(makePage(2), for: key("a"), cost: 10)

        #expect(cache.keyCount(for: "a") == 1)
        cache.removeFeed("a")
        #expect(cache.page(for: key("a"), as: TestPage.self) == nil)
    }

    @Test func costLimitOnlyRises() {
        let cache = MemoryPageCache(costLimit: 100)
        cache.raiseCostLimit(to: 500)
        #expect(cache.costLimit == 500)
        cache.raiseCostLimit(to: 200)
        #expect(cache.costLimit == 500)
    }
}
