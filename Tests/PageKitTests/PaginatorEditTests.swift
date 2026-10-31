import Foundation
import Testing
@testable import PageKit

/// A clock a test can move by hand.
private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

@Suite struct PaginatorEditTests {
    private let environment = PaginatorEnvironment.testing()
    private let first = IndexToken.first(size: 2)
    private var second: IndexToken { first.next }
    private var third: IndexToken { second.next }

    /// Page 1 holds 1 and 2, page 2 holds 3 and 4, and page 3 holds 5 and ends the list.
    private func threePages(calls: CallLog = CallLog()) -> MockSource {
        MockSource { token in
            await calls.record()
            switch token.page {
            case 1: return page(1, 2, next: token.next)
            case 2: return page(3, 4, next: token.next)
            default: return page(5)
            }
        }
    }

    /// `threePages`, except that a call `held` picks waits on `release` and serves its page late.
    private func holding(
        when held: @escaping @Sendable (Int) -> Bool, entered: Gate, release: Gate, calls: CallLog = CallLog()
    ) -> MockSource {
        let pages = threePages()
        return MockSource { token in
            if held(await calls.record()) {
                await entered.open()
                await release.wait()
            }
            return try await pages.loadPage(token)
        }
    }

    private func ids(_ snapshot: PaginationSnapshot<TestItem>) -> [Int] {
        snapshot.items.map(\.id)
    }

    private func diskPage(_ token: IndexToken) async -> Page<TestItem, IndexToken>? {
        await environment.disk.page(feedID: "test", token: token, schemaVersion: 1)
    }

    private func memoryPage(_ token: IndexToken) -> Page<TestItem, IndexToken>? {
        environment.memory.page(for: PageKey(feedID: "test", token: token), as: Page<TestItem, IndexToken>.self)
    }

    /// A paginator showing `pages` pages from `source`, with each one saved.
    private func opened(
        _ source: MockSource? = nil, pages: Int = 1, policy: CachePolicy = .networkFirst
    ) async -> Paginator<MockSource> {
        let paginator = Paginator.testing(source ?? threePages(), policy: policy, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        for _ in 1..<pages { await paginator.loadNextPage() }
        await paginator.waitForPendingWrites()
        return paginator
    }

    /// `environment` as a new launch finds it: the same disk, with nothing in memory.
    private var relaunchEnvironment: PaginatorEnvironment {
        PaginatorEnvironment(
            memory: MemoryPageCache(costLimit: 1_000_000), disk: environment.disk,
            connectivity: FakeConnectivity(), sleep: environment.sleep, now: environment.now
        )
    }

    /// What a new launch shows under `.cacheOnly`.
    private func relaunchedItems(pageSource: MockSource? = nil) async -> [TestItem] {
        let paginator = Paginator.testing(
            pageSource ?? threePages(), policy: .cacheOnly, environment: relaunchEnvironment
        )
        await paginator.start()
        return await paginator.settled().items
    }

    /// Page 1 holds 1 and 2. Page 2 repeats 2, as a shifted feed can, and ends the list.
    private var overlappingPages: MockSource {
        MockSource { token in
            token.page == 1 ? page(1, 2, next: token.next) : page(2, 3)
        }
    }

    private func expectIndexIsRight(_ paginator: Paginator<MockSource>) async {
        let items = await paginator.items
        #expect(await paginator.indexByID == Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) }))
        #expect(await Set(paginator.pageByItem.keys) == Set(items.map(\.id)))
    }

    /// Clears the feed the way `PageKit.clear(feedID:)` does.
    private func clearFeed() async {
        await environment.disk.removeFeed("test")
        environment.memory.removeFeed("test")
    }

    // MARK: Remove

    @Test func removeUpdatesListAndBothCaches() async {
        let paginator = await opened(pages: 2)

        await paginator.remove(id: 3)

        #expect(ids(await paginator.current()) == [1, 2, 4])
        #expect(memoryPage(second)?.items.map(\.id) == [4])
        #expect(await diskPage(second)?.items.map(\.id) == [4])
        #expect(await diskPage(second)?.nextToken == third)
        #expect(await diskPage(first)?.items.map(\.id) == [1, 2])
        await expectIndexIsRight(paginator)
    }

    @Test func removeFromAMiddlePageKeepsItsLinkToTheNext() async {
        let paginator = await opened(pages: 3)

        await paginator.remove(id: 2)

        #expect(await diskPage(first)?.nextToken == second)
        await expectIndexIsRight(paginator)
    }

    @Test func removePublishesOneSnapshotAndKeepsTheState() async {
        let paginator = await opened(pages: 2)
        let stream = paginator.snapshots()

        await paginator.remove(id: 1)
        let seen = await collect(stream) { $0.items.count == 3 }

        #expect(seen.count == 2)
        #expect(seen.last?.state == .loaded(hasMore: true))
    }

    @Test func removeKeepsTheCachePolicysPromise() async {
        let paginator = await opened(policy: .networkOnly)

        await paginator.remove(id: 1)

        #expect(ids(await paginator.current()) == [2])
        #expect(memoryPage(first) == nil)
        #expect(await diskPage(first) == nil)
    }

    @Test func removingTheLastItemIsEmpty() async {
        let paginator = await opened(MockSource { _ in page(1) })

        await paginator.remove(id: 1)

        let snapshot = await paginator.current()
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.state == .empty)
    }

    @Test func removingTheLastItemWithMorePagesMovesOnToThem() async {
        let paginator = await opened()

        await paginator.remove(id: 1)
        await paginator.remove(id: 2)

        #expect(ids(await paginator.first { !$0.items.isEmpty }) == [3, 4])
    }

    @Test func removingTheLastItemDuringALoadDropsTheLoad() async {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let paginator = await opened(MockSource { _ in
            if await calls.record() == 2 {
                await entered.open()
                await release.wait()
            }
            return page(1)
        })
        let refresh = Task { await paginator.refresh() }
        await entered.wait()
        let generation = await paginator.generation

        await paginator.remove(id: 1)
        #expect(await paginator.current().state == .empty)
        #expect(await paginator.generation > generation)
        await release.open()
        await refresh.value

        let snapshot = await paginator.current()
        #expect(snapshot.state == .empty)
        #expect(snapshot.items.isEmpty)
    }

    @Test func aLateFailureCannotOverwriteTheEmptyState() async {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let paginator = await opened(MockSource { _ in
            guard await calls.record() > 1 else { return page(1) }
            await entered.open()
            await release.wait()
            throw PageKitHTTPError(status: 400)
        })
        let refresh = Task { await paginator.refresh() }
        await entered.wait()

        await paginator.remove(id: 1)
        await release.open()
        await refresh.value

        #expect(await paginator.current().state == .empty)
    }

    @Test func removingAllOfTheNewestPageKeepsTheListMoving() async {
        let paginator = await opened(pages: 2)

        await paginator.remove(id: 3)
        await paginator.remove(id: 4)

        #expect(ids(await paginator.first { $0.state == .loaded(hasMore: false) }) == [1, 2, 5])
    }

    @Test func removingAllOfTheNewestPageInTheBackgroundWaits() async {
        let calls = CallLog()
        let paginator = await opened(threePages(calls: calls), pages: 2)
        await paginator.setAppActive(false)

        await paginator.remove(id: 3)
        await paginator.remove(id: 4)
        await paginator.prefetchTask?.value

        #expect(await calls.count == 2)
    }

    @Test func aPageEmptiedByRemovalStaysInTheChain() async {
        let paginator = await opened(pages: 2)

        await paginator.remove(id: 3)
        await paginator.remove(id: 4)

        #expect(await diskPage(second)?.items.isEmpty == true)
        #expect(await diskPage(second)?.nextToken == third)
    }

    // MARK: Update

    @Test func updateReplacesInPlace() async {
        let paginator = await opened(pages: 2)

        await paginator.update(TestItem(id: 3, title: "Edited"))

        let items = await paginator.current().items
        #expect(items.map(\.id) == [1, 2, 3, 4])
        #expect(items[2].title == "Edited")
        #expect(memoryPage(second)?.items.first?.title == "Edited")
        #expect(await diskPage(second)?.items.first?.title == "Edited")
        await expectIndexIsRight(paginator)
    }

    @Test(arguments: [true, false])
    func unknownIDIsANoOp(isRemoval: Bool) async {
        let paginator = await opened()
        let stream = paginator.snapshots()

        if isRemoval {
            await paginator.remove(id: 99)
        } else {
            await paginator.update(TestItem(id: 99))
        }
        await paginator.remove(id: 1)
        let seen = await collect(stream) { $0.items.count == 1 }

        #expect(seen.count == 2)
        #expect(await paginator.localEdits.count == 1)
    }

    // MARK: Relaunch

    @Test func deletedItemStaysDeletedAfterRelaunch() async {
        let paginator = await opened(pages: 2)
        await paginator.remove(id: 3)
        await paginator.update(TestItem(id: 1, title: "Edited"))
        await paginator.cancel()

        let items = await relaunchedItems()
        #expect(items.map(\.id) == [1, 2, 4])
        #expect(items[0].title == "Edited")
    }

    @Test func removingEverythingLeavesNothingToRestore() async {
        let paginator = await opened(MockSource { _ in page(1) })
        await paginator.remove(id: 1)
        await paginator.cancel()

        #expect(await relaunchedItems().isEmpty)
    }

    @Test func aRemovedDuplicateStaysGoneAfterRelaunch() async {
        let paginator = await opened(overlappingPages, pages: 2)
        #expect(ids(await paginator.current()) == [1, 2, 3])

        await paginator.remove(id: 2)
        await paginator.cancel()

        #expect(await relaunchedItems().map(\.id) == [1, 3])
    }

    @Test func aDuplicateFromARestoredListStaysGoneToo() async {
        await opened(overlappingPages, pages: 2).cancel()
        let paginator = Paginator.testing(overlappingPages, policy: .cacheOnly, environment: relaunchEnvironment)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.remove(id: 2)
        await paginator.cancel()

        #expect(await relaunchedItems().map(\.id) == [1, 3])
    }

    @Test func aParkedPageCannotBringARemovedItemBack() async {
        var configuration = PaginationConfiguration.testing(.cacheThenNetwork)
        configuration.lookaheadPages = 1
        let paginator = Paginator(source: overlappingPages, configuration: configuration, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        await paginator.remove(id: 2)
        await paginator.loadNextPage()
        await paginator.waitForPendingWrites()
        await paginator.cancel()

        #expect(ids(await paginator.current()) == [1, 3])
        #expect(await diskPage(second)?.items.map(\.id) == [3])
    }

    @Test func aFallbackPageCannotBringARemovedItemBack() async {
        let failing = CallLog()
        let paginator = await opened(MockSource { token in
            if token.page == 1 { return page(1, 2, next: token.next) }
            if await failing.record() == 1 { return page(2, 3) }
            throw PageKitHTTPError(status: 400)
        }, pages: 2)
        await paginator.refresh()
        await paginator.waitForPendingWrites()
        await environment.disk.save(
            page(2, 3) as Page<TestItem, IndexToken>, feedID: "test", token: second, schemaVersion: 1
        )

        await paginator.remove(id: 2)
        await paginator.loadNextPage()

        #expect(ids(await paginator.current()) == [1, 3])
    }

    @Test func aTrailingPageEmptiedByEditsDoesNotStallARelaunch() async {
        let paginator = await opened(pages: 2)
        await paginator.setAppActive(false)
        await paginator.remove(id: 3)
        await paginator.remove(id: 4)
        await paginator.cancel()

        let relaunched = Paginator.testing(threePages(), policy: .cacheThenNetwork, environment: relaunchEnvironment)
        await relaunched.start()

        #expect(ids(await relaunched.first { $0.state == .loaded(hasMore: false) }) == [1, 2, 5])
    }

    @Test func aPageEmptiedInTheBackgroundMovesOnInTheForeground() async {
        let paginator = await opened(pages: 2)
        await paginator.setAppActive(false)
        await paginator.remove(id: 3)
        await paginator.remove(id: 4)

        await paginator.setAppActive(true)

        #expect(ids(await paginator.first { $0.state == .loaded(hasMore: false) }) == [1, 2, 5])
    }

    // MARK: Edits during a load

    @Test func removingDuringANextPageLoadDoesNotStopIt() async {
        let entered = Gate()
        let release = Gate()
        let paginator = await opened(holding(when: { $0 == 2 }, entered: entered, release: release))
        let load = Task { await paginator.loadNextPage() }
        await entered.wait()

        await paginator.remove(id: 1)
        #expect(await paginator.current().state == .loadingNextPage)
        await release.open()
        await load.value

        #expect(ids(await paginator.current()) == [2, 3, 4])
        await expectIndexIsRight(paginator)
    }

    @Test func aPageRequestedBeforeARemovalCannotBringTheItemBack() async {
        let entered = Gate()
        let release = Gate()
        let paginator = await opened(holding(when: { $0 == 3 }, entered: entered, release: release), pages: 2)
        await paginator.waitForPendingWrites()
        let refresh = Task { await paginator.refresh() }
        await entered.wait()

        await paginator.remove(id: 3)
        await paginator.remove(id: 1)
        await release.open()
        await refresh.value
        await paginator.waitForPendingWrites()

        #expect(ids(await paginator.current()) == [2])
        #expect(await diskPage(first)?.items.map(\.id) == [2])
        #expect(memoryPage(first)?.items.map(\.id) == [2])
    }

    @Test func aPageRequestedBeforeAnUpdateCannotUndoIt() async {
        let entered = Gate()
        let release = Gate()
        let paginator = await opened(holding(when: { $0 == 2 }, entered: entered, release: release))
        let refresh = Task { await paginator.refresh() }
        await entered.wait()

        await paginator.update(TestItem(id: 1, title: "Edited"))
        await release.open()
        await refresh.value
        await paginator.waitForPendingWrites()

        #expect(await paginator.current().items.first?.title == "Edited")
        #expect(await diskPage(first)?.items.first?.title == "Edited")
    }

    @Test func aRevalidationUnderWayKeepsTheEditAndClearsStale() async {
        _ = await opened(pages: 1).cancel()
        let entered = Gate()
        let release = Gate()
        let paginator = Paginator.testing(
            holding(when: { $0 == 1 }, entered: entered, release: release),
            policy: .cacheThenNetwork, environment: environment
        )
        await paginator.start()
        await entered.wait()

        await paginator.remove(id: 2)
        await release.open()
        let revalidated = await paginator.first { !$0.isStale }

        #expect(ids(revalidated) == [1])
    }

    @Test func aReadAheadUnderWayLivesThroughAnEdit() async {
        let entered = Gate()
        let release = Gate()
        var configuration = PaginationConfiguration.testing(.cacheThenNetwork)
        configuration.lookaheadPages = 1
        let paginator = Paginator(
            source: holding(when: { $0 == 2 }, entered: entered, release: release),
            configuration: configuration, environment: environment
        )
        await paginator.start()
        await entered.wait()

        await paginator.remove(id: 2)
        await release.open()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        #expect(await diskPage(second)?.items.map(\.id) == [3, 4])
        #expect(ids(await paginator.current()) == [1])
    }

    @Test func removingTheLastItemDuringARevalidationEndsStale() async {
        await opened(MockSource { _ in page(1) }).cancel()
        let entered = Gate()
        let release = Gate()
        let paginator = Paginator.testing(MockSource { _ in
            await entered.open()
            await release.wait()
            return page(1)
        }, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        await entered.wait()

        await paginator.remove(id: 1)
        await release.open()

        #expect(await !paginator.current().isStale)
    }

    @Test func aRequestAfterAnEditIsBelieved() async {
        let paginator = await opened()
        await paginator.remove(id: 1)

        await paginator.refresh()

        #expect(ids(await paginator.current()) == [1, 2])
    }

    // MARK: Clears and evictions

    @Test(arguments: [true, false])
    func anEditAfterAClearChangesOnlyTheList(isRemoval: Bool) async {
        let paginator = await opened(pages: 2)
        await clearFeed()

        if isRemoval {
            await paginator.remove(id: 3)
        } else {
            await paginator.update(TestItem(id: 3, title: "Edited"))
        }

        #expect(await paginator.current().items.count == (isRemoval ? 3 : 4))
        #expect(memoryPage(second) == nil)
        #expect(await diskPage(second) == nil)
        #expect(await environment.disk.manifest(feedID: "test", as: IndexToken.self, schemaVersion: 1) == nil)
    }

    @Test func aClearDuringAnEditsWriteKeepsThePageOffDisk() async {
        let entered = Gate()
        let release = Gate()
        let writes = CallLog()
        var held = environment
        held.beforeDiskWrite = {
            guard await writes.record() == 3 else { return }
            await entered.open()
            await release.wait()
        }
        let paginator = Paginator.testing(threePages(), policy: .networkFirst, environment: held)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForPendingWrites()

        let edit = Task { await paginator.remove(id: 1) }
        await entered.wait()
        await clearFeed()
        await release.open()
        await edit.value

        #expect(await diskPage(first) == nil)
    }

    @Test func anEditAfterAnInPlaceRevalidationIsSaved() async {
        let connectivity = FakeConnectivity()
        let environment = PaginatorEnvironment.testing(connectivity: connectivity)
        let paginator = Paginator.testing(threePages(), policy: .networkFirst, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForPendingWrites()
        await environment.disk.removeFeed("test")
        environment.memory.removeFeed("test")

        connectivity.setOnline(false)
        _ = await paginator.first { $0.isOffline }
        connectivity.setOnline(true)
        _ = await paginator.first { !$0.isOffline }
        await paginator.waitForReconnect()
        await paginator.remove(id: 1)

        let saved: Page<TestItem, IndexToken>? = await environment.disk.page(
            feedID: "test", token: first, schemaVersion: 1
        )
        #expect(saved?.items.map(\.id) == [2])
    }

    @Test func anEditReachesAPageHeldOnlyOnDisk() async {
        let paginator = await opened()
        environment.memory.removeFeed("test")

        await paginator.remove(id: 1)

        #expect(await diskPage(first)?.items.map(\.id) == [2])
        #expect(memoryPage(first) == nil)
    }

    @Test func anEditReachesAPageHeldOnlyInMemory() async {
        let paginator = await opened()
        await environment.disk.removePages(feedID: "test", except: [IndexToken]())

        await paginator.remove(id: 1)

        #expect(memoryPage(first)?.items.map(\.id) == [2])
        #expect(await diskPage(first) == nil)
    }

    @Test func anEditDoesNotExtendTheChainsAge() async {
        let clock = Clock()
        let environment = PaginatorEnvironment.testing(now: { clock.now })
        let paginator = Paginator.testing(threePages(), policy: .networkFirst, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForPendingWrites()
        let saved = await environment.disk.manifest(feedID: "test", as: IndexToken.self, schemaVersion: 1)

        clock.now = clock.now.addingTimeInterval(90)
        await paginator.update(TestItem(id: 2, title: "Edited"))

        let edited = await environment.disk.manifest(feedID: "test", as: IndexToken.self, schemaVersion: 1)
        #expect(edited?.updatedAt == saved?.updatedAt)
    }

    @Test func anEditQueuedBeforeAClearCannotOverwriteANewerPage() async {
        let entered = Gate()
        let release = Gate()
        let writes = CallLog()
        var held = environment
        held.beforeDiskWrite = {
            guard await writes.record() == 3 else { return }
            await entered.open()
            await release.wait()
        }
        let paginator = Paginator.testing(threePages(), policy: .networkFirst, environment: held)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForPendingWrites()

        let edit = Task { await paginator.remove(id: 1) }
        await entered.wait()
        await clearFeed()
        await environment.disk.save(
            page(8) as Page<TestItem, IndexToken>, feedID: "test", token: first, schemaVersion: 1
        )
        await release.open()
        await edit.value

        #expect(await diskPage(first)?.items.map(\.id) == [8])
    }

    @Test func aListLoadedAfterAClearIsSavedAgain() async {
        let paginator = await opened()
        await clearFeed()
        await paginator.refresh()

        await paginator.remove(id: 1)

        #expect(await diskPage(first)?.items.map(\.id) == [2])
    }

    @Test func aRestoredListHonoursAClearToo() async {
        await opened().cancel()
        let paginator = await opened(policy: .cacheOnly)
        await clearFeed()

        await paginator.remove(id: 1)

        #expect(await diskPage(first) == nil)
    }

    @Test func aRestoredListFromAfterAClearIsSaved() async {
        await clearFeed()
        await opened().cancel()
        let paginator = await opened(policy: .cacheOnly)

        await paginator.remove(id: 1)

        #expect(await diskPage(first)?.items.map(\.id) == [2])
    }

    @Test func aNextPageFromAfterAClearDoesNotReopenTheOlderPages() async {
        let paginator = await opened()
        await clearFeed()
        await paginator.loadNextPage()
        await paginator.waitForPendingWrites()

        await paginator.remove(id: 1)

        #expect(await diskPage(first) == nil)
        #expect(memoryPage(first) == nil)
    }

    @Test func anEditWithThePageFileGoneDoesNotBringOldItemsBack() async {
        let paginator = await opened(pages: 2)
        await environment.disk.removePages(feedID: "test", except: [IndexToken]())
        environment.memory.removeFeed("test")

        await paginator.remove(id: 3)
        await paginator.cancel()

        #expect(ids(await paginator.current()) == [1, 2, 4])
        #expect(await diskPage(second) == nil)
        #expect(memoryPage(second) == nil)
        #expect(await relaunchedItems().isEmpty)
    }

    // MARK: After cancel

    @Test func anEditAfterCancelDoesNothing() async {
        let paginator = await opened()
        await paginator.cancel()

        await paginator.remove(id: 1)
        await paginator.update(TestItem(id: 2, title: "Edited"))

        #expect(ids(await paginator.current()) == [1, 2])
        #expect(await diskPage(first)?.items.map(\.id) == [1, 2])
        #expect(await diskPage(first)?.items.last?.title == nil)
    }
}
