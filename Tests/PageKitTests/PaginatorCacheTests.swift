import Foundation
import Testing
@testable import PageKit

@Suite struct PaginatorCacheTests {
    private let serverFailure = PageKitHTTPError(status: 500)
    private let environment = PaginatorEnvironment.testing()
    private let firstToken = IndexToken.first(size: 2)
    private var secondToken: IndexToken { firstToken.next }
    private var thirdToken: IndexToken { secondToken.next }

    /// Page 1 holds items 1 and 2, page 2 holds 3 and 4, and page 3 holds 5 and ends the list.
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

    /// Serves `first` for page 1, counting calls. Every other page fails the test.
    private func firstPageOnly(_ first: Page<TestItem, IndexToken>, calls: CallLog = CallLog()) -> MockSource {
        MockSource { token in
            await calls.record()
            #expect(token.page == 1)
            return first
        }
    }

    private func failing(with error: any Error = PageKitHTTPError(status: 500), calls: CallLog = CallLog()) -> MockSource {
        MockSource { _ in
            await calls.record()
            throw error
        }
    }

    private func ids(_ snapshot: PaginationSnapshot<TestItem>) -> [Int] {
        snapshot.items.map(\.id)
    }

    /// Loads `pages` pages from `source` and saves them, so a later paginator finds a chain.
    private func seedChain(pages: Int, source: MockSource? = nil, environment: PaginatorEnvironment? = nil) async {
        let environment = environment ?? self.environment
        let paginator = Paginator.testing(source ?? threePages(), policy: .networkFirst, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        for _ in 1..<max(pages, 1) { await paginator.loadNextPage() }
        await paginator.waitForPendingWrites()
    }

    private func diskPage(_ token: IndexToken, feedID: String = "test") async -> Page<TestItem, IndexToken>? {
        await environment.disk.page(feedID: feedID, token: token, schemaVersion: 1)
    }

    private func memoryPage(_ token: IndexToken, feedID: String = "test") -> Page<TestItem, IndexToken>? {
        environment.memory.page(for: PageKey(feedID: feedID, token: token), as: Page<TestItem, IndexToken>.self)
    }

    private func manifest(feedID: String = "test") async -> FeedManifest<IndexToken>? {
        await environment.disk.manifest(feedID: feedID, as: IndexToken.self, schemaVersion: 1)
    }

    /// Writes page 2 to disk without adding it to the manifest, which is how a parked read-ahead page sits.
    private func park(_ parked: Page<TestItem, IndexToken>, as token: IndexToken) async {
        await environment.disk.save(parked, feedID: "test", token: token, schemaVersion: 1)
    }

    /// An environment that stops at disk read number `read`, counted from 1, until `release` opens.
    private func holdingRead(_ read: Int, entered: Gate, release: Gate) -> PaginatorEnvironment {
        let reads = CallLog()
        var held = environment
        held.beforeDiskRead = {
            guard await reads.record() == read else { return }
            await entered.open()
            await release.wait()
        }
        return held
    }

    // MARK: Opening a feed

    @Test func secondOpenServesFromMemoryWithoutCallingSource() async {
        await seedChain(pages: 2)
        // With the page files gone, only memory can supply these pages.
        await environment.disk.removePages(feedID: "test", except: [IndexToken]())
        let calls = CallLog()

        let paginator = Paginator.testing(firstPageOnly(page(9), calls: calls), policy: .cacheOnly, environment: environment)
        await paginator.start()
        let snapshot = await paginator.settled()

        #expect(ids(snapshot) == [1, 2, 3, 4])
        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(await calls.count == 0)
    }

    @Test func cacheThenNetworkCallsSourceOnceForFirstPageOnly() async {
        await seedChain(pages: 2)
        let calls = CallLog()
        let source = firstPageOnly(page(1, 2, next: secondToken), calls: calls)

        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()

        #expect(ids(await paginator.revalidated()) == [1, 2, 3, 4])
        #expect(await calls.count == 1)
    }

    @Test func cacheThenNetworkRestoresChainAsStale() async {
        await seedChain(pages: 2)
        let source = firstPageOnly(page(1, 2, next: secondToken))
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        let stream = paginator.snapshots()

        await paginator.start()
        let seen = await collect(stream) { !$0.isStale && !$0.items.isEmpty }

        // The spinner never shows: observers go straight from idle to the cached chain.
        #expect(seen.count == 3)
        #expect(seen[0].state == .idle)
        #expect(ids(seen[1]) == [1, 2, 3, 4])
        #expect(seen[1].isStale)
        #expect(seen[1].state == .loaded(hasMore: true))
    }

    @Test func unchangedFirstPageKeepsTheChain() async {
        await seedChain(pages: 2)
        let source = firstPageOnly(page(1, 2, next: secondToken))

        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        let snapshot = await paginator.revalidated()
        await paginator.waitForPendingWrites()

        #expect(ids(snapshot) == [1, 2, 3, 4])
        #expect(await diskPage(secondToken) != nil)
        #expect(await manifest()?.tokens == [firstToken, secondToken])
    }

    @Test func changedFirstPageReplacesListAndDeletesLaterPages() async {
        await seedChain(pages: 2)
        let source = firstPageOnly(page(7, 1, next: secondToken))

        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        let snapshot = await paginator.revalidated()
        await paginator.waitForPendingWrites()

        #expect(ids(snapshot) == [7, 1])
        #expect(await diskPage(secondToken) == nil)
        #expect(memoryPage(secondToken) == nil)
        #expect(await diskPage(firstToken)?.items.map(\.id) == [7, 1])
        #expect(await manifest()?.tokens == [firstToken])
    }

    @Test func reorderedFirstPageCountsAsChanged() async {
        await seedChain(pages: 2)
        let source = firstPageOnly(page(2, 1, next: secondToken))

        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()

        #expect(ids(await paginator.revalidated()) == [2, 1])
    }

    @Test func sameIDsNewContentUpdatesInPlace() async {
        let old = MockSource { _ in Page(items: [TestItem(id: 1, title: "old"), TestItem(id: 2)], nextToken: nil) }
        await seedChain(pages: 1, source: old)
        let new = Page(items: [TestItem(id: 1, title: "new"), TestItem(id: 2)], nextToken: IndexToken?.none)

        let paginator = Paginator.testing(firstPageOnly(new), policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        let snapshot = await paginator.revalidated()
        await paginator.waitForPendingWrites()

        #expect(snapshot.items.first?.title == "new")
        #expect(await diskPage(firstToken)?.items.first?.title == "new")
    }

    @Test func unchangedFirstPageUpdatesTheNextTokenOfAOnePageChain() async {
        let ended = MockSource { _ in page(1, 2) }
        await seedChain(pages: 1, source: ended)
        let source = firstPageOnly(page(1, 2, next: secondToken))

        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()

        #expect(await paginator.revalidated().state == .loaded(hasMore: true))
    }

    @Test func failedRevalidationKeepsItemsAndSetsLastError() async {
        await seedChain(pages: 2)

        let paginator = Paginator.testing(failing(), policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        let snapshot = await paginator.first { $0.lastError != nil }

        #expect(ids(snapshot) == [1, 2, 3, 4])
        #expect(snapshot.lastError == .server(status: 500))
        #expect(snapshot.isStale)
        #expect(snapshot.state == .loaded(hasMore: true))
    }

    @Test func retryAfterFailedRevalidationKeepsTheChain() async {
        await seedChain(pages: 2)
        let calls = CallLog()
        let source = MockSource { [self] _ in
            if await calls.record() <= RetryPolicy.default.maxAttempts { throw serverFailure }
            return page(1, 2, next: secondToken)
        }
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        _ = await paginator.first { $0.lastError != nil }

        await paginator.retry()
        let snapshot = await paginator.current()

        #expect(ids(snapshot) == [1, 2, 3, 4])
        #expect(snapshot.lastError == nil)
        #expect(!snapshot.isStale)

        let callsSoFar = await calls.count
        await paginator.retry()
        #expect(await calls.count == callsSoFar)
    }

    @Test func revalidationDoesNotForgetAFailedNextPage() async {
        await seedChain(pages: 1)
        let entered = Gate()
        let release = Gate()
        let nextCalls = CallLog()
        let source = MockSource { [self] token in
            guard token.page == 2 else {
                await entered.open()
                await release.wait()
                return page(1, 2, next: secondToken)
            }
            if await nextCalls.record() <= RetryPolicy.default.maxAttempts { throw serverFailure }
            return page(3, 4)
        }
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        await entered.wait()
        await paginator.loadNextPage()
        await release.open()
        _ = await paginator.first { !$0.isStale }

        await paginator.retry()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
    }

    @Test func offlineLaunchShowsDiskPages() async {
        await seedChain(pages: 2)
        environment.memory.removeAll()

        let offline = failing(with: URLError(.notConnectedToInternet))
        let paginator = Paginator.testing(offline, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        let snapshot = await paginator.first { $0.lastError != nil }

        #expect(ids(snapshot) == [1, 2, 3, 4])
        #expect(snapshot.lastError == .offline)
        #expect(snapshot.isStale)
    }

    @Test func nothingCachedLoadsFromTheNetwork() async {
        let paginator = Paginator.testing(threePages(), policy: .cacheThenNetwork, environment: environment)
        let stream = paginator.snapshots()

        await paginator.start()
        let seen = await collect(stream) { $0.state == .loaded(hasMore: true) }

        #expect(seen.map(\.state) == [.idle, .loadingFirstPage, .loaded(hasMore: true)])
        #expect(!seen[2].isStale)
    }

    @Test func missingLaterPageShortensTheChain() async {
        await seedChain(pages: 3)
        environment.memory.removeAll()
        await environment.disk.removePages(feedID: "test", except: [firstToken, thirdToken])
        let source = firstPageOnly(page(1, 2, next: secondToken))

        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        let snapshot = await paginator.revalidated()

        #expect(ids(snapshot) == [1, 2])
        #expect(snapshot.state == .loaded(hasMore: true))
    }

    @Test func missingFirstPageIsACacheMiss() async {
        await seedChain(pages: 2)
        environment.memory.removeAll()
        await environment.disk.removePages(feedID: "test", except: [secondToken])
        let source = firstPageOnly(page(8, next: secondToken))
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        let stream = paginator.snapshots()

        await paginator.start()
        let seen = await collect(stream) { $0.state == .loaded(hasMore: true) }

        #expect(seen.map(\.state) == [.idle, .loadingFirstPage, .loaded(hasMore: true)])
        #expect(ids(seen[2]) == [8])
    }

    @Test func cachedEmptyListIsACacheMiss() async {
        await seedChain(pages: 1, source: MockSource { _ in page() })
        let source = firstPageOnly(page(1))
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        let stream = paginator.snapshots()

        await paginator.start()
        let seen = await collect(stream) { $0.state == .loaded(hasMore: false) }

        #expect(seen.map(\.state) == [.idle, .loadingFirstPage, .loaded(hasMore: false)])
    }

    @Test func feedPastItsMaxAgeIsNotRestored() async {
        let launch = Date()
        let aged = PaginatorEnvironment(
            memory: environment.memory, disk: environment.disk, connectivity: environment.connectivity,
            sleep: environment.sleep, now: { launch.addingTimeInterval(8 * 24 * 3600) }
        )
        await seedChain(pages: 2)
        let source = firstPageOnly(page(8))

        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: aged)
        await paginator.start()
        let snapshot = await paginator.settled()
        await paginator.waitForPendingWrites()

        #expect(ids(snapshot) == [8])
        #expect(await diskPage(secondToken) == nil)
    }

    @Test func chainFromAnotherFirstTokenIsACacheMiss() async {
        await seedChain(pages: 1)
        struct Resized: PageSource {
            let feedID = "test"
            let firstToken = IndexToken.first(size: 50)
            func loadPage(_ token: IndexToken) async throws -> Page<TestItem, IndexToken> { page(8) }
        }

        let paginator = Paginator(source: Resized(), configuration: .testing(.cacheThenNetwork), environment: environment)
        await paginator.start()

        #expect(ids(await paginator.settled()) == [8])
    }

    // MARK: Next page

    @Test func nextPageComesFromDiskWhenCached() async {
        await seedChain(pages: 1)
        await park(page(3, 4), as: secondToken)
        environment.memory.removeAll()
        let calls = CallLog()
        let source = firstPageOnly(page(1, 2, next: secondToken), calls: calls)
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        _ = await paginator.revalidated()

        await paginator.loadNextPage()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
        #expect(await calls.count == 1)
        #expect(memoryPage(secondToken) != nil)
    }

    @Test func nextPageComesFromTheNetworkOnACacheMiss() async {
        await seedChain(pages: 1)
        let paginator = Paginator.testing(threePages(), policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        _ = await paginator.revalidated()

        await paginator.loadNextPage()
        await paginator.waitForPendingWrites()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
        #expect(await diskPage(secondToken) != nil)
    }

    @Test func pageFromCacheLeavesTheFeedsAgeAlone() async {
        await seedChain(pages: 1)
        await park(page(3, 4), as: secondToken)
        let savedAt = await manifest()?.updatedAt
        let paginator = Paginator.testing(failing(), policy: .cacheOnly, environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.loadNextPage()
        await paginator.waitForPendingWrites()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
        #expect(await manifest()?.updatedAt == savedAt)
    }

    @Test func pageFromCacheClearsLastError() async {
        await seedChain(pages: 1)
        await park(page(3, 4), as: secondToken)
        let paginator = Paginator.testing(failing(), policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        _ = await paginator.first { $0.lastError != nil }

        await paginator.loadNextPage()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
        #expect(await paginator.current().lastError == nil)
    }

    // MARK: Network first

    @Test func networkFirstFallsBackToCacheOnFailure() async {
        await seedChain(pages: 2)
        let calls = CallLog()

        let paginator = Paginator.testing(failing(calls: calls), policy: .networkFirst, environment: environment)
        await paginator.start()
        let snapshot = await paginator.settled()

        #expect(ids(snapshot) == [1, 2, 3, 4])
        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(snapshot.lastError == .server(status: 500))
        #expect(snapshot.isStale)
        #expect(await calls.count > 0)
    }

    @Test func networkFirstPrefersTheNetwork() async {
        await seedChain(pages: 1)

        let paginator = Paginator.testing(firstPageOnly(page(8)), policy: .networkFirst, environment: environment)
        await paginator.start()

        #expect(ids(await paginator.settled()) == [8])
    }

    @Test func networkFirstWithNothingCachedFails() async {
        let paginator = Paginator.testing(failing(), policy: .networkFirst, environment: environment)
        await paginator.start()

        #expect(await paginator.settled().state == .failed(.server(status: 500), isFirstPage: true))
    }

    @Test func networkFirstNextPageFallsBackToCache() async {
        let calls = CallLog()
        let source = MockSource { [self] token in
            guard token.page == 1 else {
                await calls.record()
                throw serverFailure
            }
            return page(1, 2, next: token.next)
        }
        let paginator = Paginator.testing(source, policy: .networkFirst, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForPendingWrites()
        await park(page(3, 4), as: secondToken)

        await paginator.loadNextPage()
        let snapshot = await paginator.current()

        #expect(await calls.count > 0)
        #expect(ids(snapshot) == [1, 2, 3, 4])
        #expect(snapshot.isStale)
        #expect(snapshot.state == .loaded(hasMore: false))
    }

    @Test func networkFirstNextPageFailsWhenNotCached() async {
        let source = MockSource { [self] token in
            guard token.page == 1 else { throw serverFailure }
            return page(1, 2, next: token.next)
        }
        let paginator = Paginator.testing(source, policy: .networkFirst, environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.loadNextPage()

        #expect(await paginator.current().state == .failed(.server(status: 500), isFirstPage: false))
    }

    @Test func networkFirstRefreshDoesNotFallBack() async {
        await seedChain(pages: 2)
        let calls = CallLog()
        let source = MockSource { [self] token in
            if await calls.record() > 1 { throw serverFailure }
            return page(1, 2, next: token.next)
        }
        let paginator = Paginator.testing(source, policy: .networkFirst, environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.refresh()
        let snapshot = await paginator.current()

        #expect(ids(snapshot) == [1, 2])
        #expect(snapshot.lastError == .server(status: 500))
    }

    @Test func failedRetryOfAFallbackLoadKeepsTheChainAsItIs() async {
        await seedChain(pages: 2)
        let paginator = Paginator.testing(failing(), policy: .networkFirst, environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.retry()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
        #expect(await paginator.pageOrder == [firstToken, secondToken])
    }

    @Test func cancelDuringAFallbackReadLeavesNoFailure() async {
        let entered = Gate()
        let release = Gate()
        let held = holdingRead(1, entered: entered, release: release)
        let source = MockSource { [self] token in
            guard token.page == 1 else { throw serverFailure }
            return page(1, 2, next: token.next)
        }
        let paginator = Paginator.testing(source, policy: .networkFirst, environment: held)
        await paginator.start()
        _ = await paginator.settled()

        let next = Task { await paginator.loadNextPage() }
        await entered.wait()
        await paginator.cancel()
        await release.open()
        await next.value

        #expect(await paginator.current().state == .loaded(hasMore: true))
    }

    @Test func retryOfAFallbackLoadReplacesTheList() async {
        await seedChain(pages: 2)
        let calls = CallLog()
        let source = MockSource { [self] token in
            if await calls.record() <= RetryPolicy.default.maxAttempts { throw serverFailure }
            return page(8, next: token.next)
        }
        let paginator = Paginator.testing(source, policy: .networkFirst, environment: environment)
        await paginator.start()
        #expect(ids(await paginator.settled()) == [1, 2, 3, 4])

        await paginator.retry()
        let snapshot = await paginator.current()

        #expect(ids(snapshot) == [8])
        #expect(!snapshot.isStale)
        #expect(snapshot.lastError == nil)
    }

    // MARK: Network only

    @Test func networkOnlyNeitherReadsNorWritesCache() async {
        await seedChain(pages: 1)
        let source = MockSource { [self] token in
            token.page == 1 ? page(7, next: secondToken) : page(8)
        }

        let paginator = Paginator.testing(source, policy: .networkOnly, environment: environment)
        await paginator.start()
        let first = await paginator.settled()
        await paginator.loadNextPage()
        await paginator.refresh()
        await paginator.waitForPendingWrites()

        #expect(ids(first) == [7])
        #expect(await diskPage(firstToken)?.items.map(\.id) == [1, 2])
        #expect(memoryPage(firstToken)?.items.map(\.id) == [1, 2])
        #expect(await diskPage(secondToken) == nil)
    }

    @Test func networkOnlyFailureDoesNotFallBack() async {
        await seedChain(pages: 1)

        let paginator = Paginator.testing(failing(), policy: .networkOnly, environment: environment)
        await paginator.start()

        #expect(await paginator.settled().state == .failed(.server(status: 500), isFirstPage: true))
    }

    @Test func networkOnlyReadsNoPage() async {
        await seedChain(pages: 1)
        let paginator = Paginator.testing(failing(), policy: .networkOnly, environment: environment)

        #expect(await paginator.readPage(firstToken) == nil)
    }

    @Test func networkOnlyLeavesTheDiskEmpty() async {
        let paginator = Paginator.testing(threePages(), policy: .networkOnly, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForPendingWrites()

        #expect(await environment.disk.storedFeeds().isEmpty)
        #expect(environment.memory.keyCount(for: "test") == 0)
    }

    // MARK: Cache only

    @Test func cacheOnlyEndsWhenChainEnds() async {
        await seedChain(pages: 1)
        let calls = CallLog()
        let paginator = Paginator.testing(threePages(calls: calls), policy: .cacheOnly, environment: environment)
        await paginator.start()
        #expect(await paginator.settled().state == .loaded(hasMore: true))

        await paginator.loadNextPage()
        let snapshot = await paginator.current()

        #expect(snapshot.state == .loaded(hasMore: false))
        #expect(ids(snapshot) == [1, 2])
        #expect(await calls.count == 0)
    }

    @Test func cacheOnlyWithNothingCachedIsEmpty() async {
        let calls = CallLog()
        let paginator = Paginator.testing(threePages(calls: calls), policy: .cacheOnly, environment: environment)

        await paginator.start()

        #expect(await paginator.settled().state == .empty)
        #expect(await calls.count == 0)
    }

    @Test func cacheOnlyItemsAreNotMarkedStale() async {
        await seedChain(pages: 1)
        let paginator = Paginator.testing(failing(), policy: .cacheOnly, environment: environment)

        await paginator.start()

        #expect(await paginator.settled().isStale == false)
    }

    @Test func cacheOnlyRefreshNeverCallsTheSource() async {
        await seedChain(pages: 2)
        let calls = CallLog()
        let paginator = Paginator.testing(failing(calls: calls), policy: .cacheOnly, environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.refresh()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
        #expect(await calls.count == 0)
    }

    // MARK: Refresh

    @Test func failedRefreshKeepsOldPagesOnDisk() async {
        await seedChain(pages: 2)
        let source = firstPageOnly(page(1, 2, next: secondToken))
        let calls = CallLog()
        let flaky = MockSource { [self] token in
            if await calls.record() > 1 { throw serverFailure }
            return try await source.loadPage(token)
        }
        let paginator = Paginator.testing(flaky, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        _ = await paginator.revalidated()

        await paginator.refresh()
        await paginator.waitForPendingWrites()

        #expect(await paginator.current().lastError == .server(status: 500))
        #expect(await diskPage(firstToken) != nil)
        #expect(await diskPage(secondToken) != nil)
        #expect(await manifest()?.tokens == [firstToken, secondToken])
    }

    @Test func refreshDeletesLaterPagesAfterSuccess() async {
        await seedChain(pages: 2)
        let source = firstPageOnly(page(1, 2, next: secondToken))
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        _ = await paginator.revalidated()

        await paginator.refresh()
        await paginator.waitForPendingWrites()

        #expect(ids(await paginator.current()) == [1, 2])
        #expect(await diskPage(secondToken) == nil)
        #expect(memoryPage(secondToken) == nil)
        #expect(await diskPage(firstToken) != nil)
        #expect(await manifest()?.tokens == [firstToken])
    }

    // MARK: Writing

    @Test func manifestRecordsLimitsAndLastNextToken() async {
        var configuration = PaginationConfiguration.testing(.cacheThenNetwork)
        configuration.maxAge = 1_234
        configuration.diskSizeLimit = 5_678
        configuration.storage = .durable
        configuration.schemaVersion = 3
        let date = Date(timeIntervalSince1970: 5_000)
        let dated = PaginatorEnvironment.testing(now: { date })
        let paginator = Paginator(source: threePages(), configuration: configuration, environment: dated)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.loadNextPage()
        await paginator.waitForPendingWrites()
        let saved = await dated.disk.manifest(feedID: "test", as: IndexToken.self, schemaVersion: 3)

        #expect(saved?.tokens == [firstToken, secondToken])
        #expect(saved?.lastNextToken == thirdToken)
        #expect(saved?.maxAge == 1_234)
        #expect(saved?.diskSizeLimit == 5_678)
        #expect(saved?.storage == .durable)
        #expect(saved?.schemaVersion == 3)
        #expect(saved?.updatedAt == date)
    }

    @Test func manifestIsWrittenWithTheFirstPage() async {
        await seedChain(pages: 1)

        let feeds = await environment.disk.storedFeeds()

        #expect(feeds.count == 1)
        #expect(feeds.first?.header != nil)
        #expect(await diskPage(firstToken) != nil)
    }

    @Test func memoryWarningEmptiesCacheButNotList() async {
        let paginator = Paginator.testing(threePages(), policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        #expect(environment.memory.keyCount(for: "test") == 1)

        PageKit.clearMemoryCache(environment.memory)
        await paginator.loadNextPage()

        #expect(memoryPage(firstToken) == nil)
        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
    }

    @Test func feedsDoNotShareCacheEntries() async {
        await seedChain(pages: 1, source: MockSource(feedID: "a") { token in page(1, next: token.next) })
        let calls = CallLog()
        let other = MockSource(feedID: "b") { _ in
            await calls.record()
            return page(2)
        }

        let paginator = Paginator.testing(other, policy: .cacheOnly, environment: environment)
        await paginator.start()

        #expect(await paginator.settled().state == .empty)
        #expect(await diskPage(firstToken, feedID: "a") != nil)
        #expect(await diskPage(firstToken, feedID: "b") == nil)
    }

    @Test func readPagePromotesADiskPageToMemory() async {
        await seedChain(pages: 1)
        environment.memory.removeAll()
        let paginator = Paginator.testing(failing(), policy: .cacheOnly, environment: environment)

        let read = await paginator.readPage(firstToken)

        #expect(read?.items.map(\.id) == [1, 2])
        #expect(memoryPage(firstToken) != nil)
    }

    // MARK: Interleaving

    @Test(arguments: [1, 2]) func secondStartDuringRestoreDoesNothing(read: Int) async {
        await seedChain(pages: 1)
        environment.memory.removeAll()
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let source = firstPageOnly(page(1, 2, next: secondToken), calls: calls)
        let held = holdingRead(read, entered: entered, release: release)
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: held)

        await paginator.start()
        await entered.wait()
        await paginator.start()
        let startTask = await paginator.startTask
        await release.open()
        _ = await paginator.revalidated()

        #expect(startTask == nil)
        #expect(await calls.count == 1)
    }

    /// Read 1 is the manifest, 2 is page 1 and 3 is page 2, by which time page 1 is in hand.
    @Test(arguments: [1, 2, 3]) func cancelDuringRestoreLeavesNoTrace(read: Int) async {
        await seedChain(pages: 2)
        environment.memory.removeAll()
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let source = firstPageOnly(page(1), calls: calls)
        let held = holdingRead(read, entered: entered, release: release)
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: held)

        let open = Task { await paginator.open() }
        await entered.wait()
        await paginator.cancel()
        await release.open()
        await open.value

        let snapshot = await paginator.current()
        #expect(snapshot.state == .idle)
        #expect(snapshot.items.isEmpty)
        #expect(await paginator.state == .idle)
        #expect(await calls.count == 0)
        // The page being read when the cancel came must not go back into memory.
        #expect(memoryPage(read == 3 ? secondToken : firstToken) == nil)
    }

    @Test func startWorksAgainAfterACancelledRestore() async {
        await seedChain(pages: 1)
        environment.memory.removeAll()
        let entered = Gate()
        let release = Gate()
        let source = firstPageOnly(page(1, 2, next: secondToken))
        let held = holdingRead(1, entered: entered, release: release)
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: held)

        await paginator.start()
        await entered.wait()
        await paginator.cancel()
        await paginator.start()
        await release.open()

        #expect(ids(await paginator.revalidated()) == [1, 2])
    }

    @Test func refreshDuringRestoreWins() async {
        await seedChain(pages: 1)
        environment.memory.removeAll()
        let entered = Gate()
        let release = Gate()
        let source = firstPageOnly(page(8))
        let held = holdingRead(1, entered: entered, release: release)
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: held)

        let open = Task { await paginator.open() }
        await entered.wait()
        await paginator.refresh()
        await release.open()
        await open.value

        #expect(ids(await paginator.current()) == [8])
        #expect(await paginator.current().state == .loaded(hasMore: false))
    }

    @Test func lateCancellationDoesNotEndARestore() async {
        await seedChain(pages: 1)
        environment.memory.removeAll()
        let entered = Gate()
        let release = Gate()
        let source = firstPageOnly(page(1, 2, next: secondToken))
        let held = holdingRead(1, entered: entered, release: release)
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: held)
        let earlierLoad = await paginator.latestLoad
        let generation = await paginator.generation

        await paginator.start()
        await entered.wait()
        await paginator.abandonLoad(earlierLoad, generation: generation, token: firstToken)
        await release.open()

        #expect(ids(await paginator.revalidated()) == [1, 2])
    }

    @Test func nextPageBeginsWhileRevalidationRuns() async {
        await seedChain(pages: 1)
        let entered = Gate()
        let release = Gate()
        let source = MockSource { [self] token in
            guard token.page == 1 else { return page(3, 4) }
            await entered.open()
            await release.wait()
            return page(1, 2, next: secondToken)
        }
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        await entered.wait()

        await paginator.loadNextPage()
        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
        await release.open()
        let snapshot = await paginator.revalidated()

        #expect(ids(snapshot) == [1, 2, 3, 4])
        #expect(snapshot.state == .loaded(hasMore: false))
    }

    @Test func changedFirstPageDropsANextPageStillLoading() async {
        await seedChain(pages: 1)
        let enteredNext = Gate()
        let releaseNext = Gate()
        let enteredFirst = Gate()
        let releaseFirst = Gate()
        let source = MockSource { token in
            if token.page == 1 {
                await enteredFirst.open()
                await releaseFirst.wait()
                return page(7)
            }
            await enteredNext.open()
            await releaseNext.wait()
            return page(3, 4)
        }
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        await enteredFirst.wait()
        let next = Task { await paginator.loadNextPage() }
        await enteredNext.wait()

        await releaseFirst.open()
        #expect(await paginator.revalidated().state == .loaded(hasMore: false))
        await releaseNext.open()
        await next.value
        await paginator.waitForPendingWrites()

        let snapshot = await paginator.current()
        #expect(ids(snapshot) == [7])
        #expect(snapshot.state == .loaded(hasMore: false))
        #expect(await diskPage(secondToken) == nil)
    }

    @Test func unchangedFirstPageLeavesANextPageLoading() async {
        await seedChain(pages: 1)
        let enteredNext = Gate()
        let releaseNext = Gate()
        let enteredFirst = Gate()
        let releaseFirst = Gate()
        let source = MockSource { [self] token in
            if token.page == 1 {
                await enteredFirst.open()
                await releaseFirst.wait()
                return page(1, 2, next: secondToken)
            }
            await enteredNext.open()
            await releaseNext.wait()
            return page(3, 4)
        }
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        await enteredFirst.wait()
        let next = Task { await paginator.loadNextPage() }
        await enteredNext.wait()

        await releaseFirst.open()
        #expect(await paginator.first { !$0.isStale }.state == .loadingNextPage)
        await releaseNext.open()
        await next.value

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
    }

    @Test func failedRevalidationLeavesANextPageLoading() async {
        await seedChain(pages: 1)
        let enteredNext = Gate()
        let releaseNext = Gate()
        let enteredFirst = Gate()
        let releaseFirst = Gate()
        let source = MockSource { [self] token in
            if token.page == 1 {
                await enteredFirst.open()
                await releaseFirst.wait()
                throw serverFailure
            }
            await enteredNext.open()
            await releaseNext.wait()
            return page(3, 4)
        }
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        await enteredFirst.wait()
        let next = Task { await paginator.loadNextPage() }
        await enteredNext.wait()

        await releaseFirst.open()
        #expect(await paginator.first { $0.lastError != nil }.state == .loadingNextPage)
        await releaseNext.open()
        await next.value

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
    }

    @Test func cancelDuringRevalidationKeepsTheCachedList() async {
        await seedChain(pages: 1)
        let entered = Gate()
        let release = Gate()
        let source = MockSource { _ in
            await entered.open()
            await release.wait()
            return page(8)
        }
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)

        let open = Task { await paginator.open() }
        await entered.wait()
        await paginator.cancel()
        await release.open()
        await open.value
        await paginator.waitForPendingWrites()

        #expect(ids(await paginator.current()) == [1, 2])
        #expect(await diskPage(firstToken)?.items.map(\.id) == [1, 2])
    }

    @Test func cancelDuringAFailingRevalidationReportsNothing() async {
        await seedChain(pages: 1)
        let entered = Gate()
        let release = Gate()
        let source = MockSource { _ in
            await entered.open()
            await release.wait()
            throw PageKitHTTPError(status: 404)
        }
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: environment)

        let open = Task { await paginator.open() }
        await entered.wait()
        await paginator.cancel()
        await release.open()
        await open.value

        #expect(await paginator.current().lastError == nil)
    }

    @Test func cancelDuringACachedNextPageReadDropsIt() async {
        await seedChain(pages: 1)
        await park(page(3, 4), as: secondToken)
        environment.memory.removeAll()
        let entered = Gate()
        let release = Gate()
        // One read each for the manifest and page 1 comes before the held one.
        let held = holdingRead(3, entered: entered, release: release)
        let calls = CallLog()
        let source = firstPageOnly(page(1, 2, next: secondToken), calls: calls)
        let paginator = Paginator.testing(source, policy: .cacheThenNetwork, environment: held)
        await paginator.start()
        _ = await paginator.revalidated()

        let next = Task { await paginator.loadNextPage() }
        await entered.wait()
        await paginator.cancel()
        await release.open()
        await next.value

        #expect(ids(await paginator.current()) == [1, 2])
        #expect(await paginator.current().state == .loaded(hasMore: true))
        #expect(memoryPage(secondToken) == nil)
        #expect(await calls.count == 1)
    }

    // MARK: Maintenance

    @Test(arguments: [CachePolicy.networkOnly, .cacheOnly, .networkFirst, .cacheThenNetwork])
    func startSchedulesMaintenance(policy: CachePolicy) async {
        let scheduled = ScheduleCount()
        var counted = environment
        counted.scheduleMaintenance = { scheduled.increment() }
        let paginator = Paginator.testing(threePages(), policy: policy, environment: counted)

        await paginator.start()
        await paginator.start()

        #expect(scheduled.value == 1)
    }
}

/// Counts synchronous calls, because `scheduleMaintenance` is not async.
private final class ScheduleCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
