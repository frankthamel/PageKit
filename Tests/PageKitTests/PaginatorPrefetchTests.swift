import Foundation
import Testing
@testable import PageKit

/// Tracks how many requests overlap.
private actor ConcurrencyProbe {
    private(set) var peak = 0
    private var running = 0

    /// Records a request starting and returns how many are now running.
    func enter() -> Int {
        running += 1
        peak = max(peak, running)
        return running
    }

    func leave() {
        running -= 1
    }
}

/// A token of the app's own making. It predicts its successor, as `IndexToken` does.
private struct ChapterToken: PageToken {
    let chapter: Int

    var predictedNext: ChapterToken? { ChapterToken(chapter: chapter + 1) }
}

private struct ChapterSource: PageSource {
    let feedID = "test.chapters"
    let firstToken = ChapterToken(chapter: 1)
    let handler: @Sendable (ChapterToken) async throws -> Page<TestItem, ChapterToken>

    func loadPage(_ token: ChapterToken) async throws -> Page<TestItem, ChapterToken> {
        try await handler(token)
    }
}

/// Reports a good connection only once `gate` opens, as a slow first status does.
private struct HeldConnectivity: ConnectivityMonitoring {
    let gate: Gate

    func updates() -> AsyncStream<ConnectivityStatus> {
        AsyncStream { continuation in
            Task {
                await gate.wait()
                continuation.yield(.online)
                continuation.finish()
            }
        }
    }
}

@Suite struct PaginatorPrefetchTests {
    private let first = IndexToken.first(size: 2)
    private var second: IndexToken { first.next }
    private var third: IndexToken { second.next }

    /// Each page holds two items. `pages` is where the list ends.
    private func numbered(pages: Int = 4, calls: CallLog = CallLog()) -> MockSource {
        MockSource { token in
            await calls.record()
            let start = token.page * 2 - 1
            return page(start, start + 1, next: token.page < pages ? token.next : nil)
        }
    }

    /// Serves `numbered` pages, but holds page 2 until `release` opens. Page 2 ignores cancellation.
    private func holdingSecondPage(entered: Gate, release: Gate, calls: CallLog = CallLog()) -> MockSource {
        MockSource { token in
            await calls.record()
            if token.page == 2 {
                await entered.open()
                await release.wait()
            }
            let start = token.page * 2 - 1
            return page(start, start + 1, next: token.next)
        }
    }

    private func paginator<Source: PageSource>(
        _ source: Source,
        policy: CachePolicy = .cacheThenNetwork,
        lookahead: Int = 1,
        environment: PaginatorEnvironment = .testing(),
        configure: (inout PaginationConfiguration) -> Void = { _ in }
    ) -> Paginator<Source> {
        var configuration = PaginationConfiguration.testing(policy)
        configuration.lookaheadPages = lookahead
        configure(&configuration)
        return Paginator(source: source, configuration: configuration, environment: environment)
    }

    /// Starts the feed and waits for page 1, and for the read-ahead it sets off.
    private func opened<Source>(_ paginator: Paginator<Source>) async {
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()
    }

    private func ids(_ snapshot: PaginationSnapshot<TestItem>) -> [Int] {
        snapshot.items.map(\.id)
    }

    private func memoryPage(
        _ token: IndexToken, in environment: PaginatorEnvironment
    ) -> Page<TestItem, IndexToken>? {
        environment.memory.page(for: PageKey(feedID: "test", token: token), as: Page<TestItem, IndexToken>.self)
    }

    private func diskPage(
        _ token: IndexToken, in environment: PaginatorEnvironment
    ) async -> Page<TestItem, IndexToken>? {
        await environment.disk.page(feedID: "test", token: token, schemaVersion: 1)
    }

    private func expectParked(
        _ token: IndexToken, in environment: PaginatorEnvironment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(memoryPage(token, in: environment) != nil, sourceLocation: sourceLocation)
        #expect(await diskPage(token, in: environment) != nil, sourceLocation: sourceLocation)
    }

    private func expectNotCached(
        _ token: IndexToken, in environment: PaginatorEnvironment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(memoryPage(token, in: environment) == nil, sourceLocation: sourceLocation)
        #expect(await diskPage(token, in: environment) == nil, sourceLocation: sourceLocation)
    }

    private func clear(_ environment: PaginatorEnvironment) async {
        await PageKit.clear(feedID: "test", stores: [environment.disk], memory: environment.memory)
    }

    // MARK: Distance trigger

    @Test func appearingWithinDistanceTriggersNextPage() async {
        let paginator = paginator(numbered(), lookahead: 0)
        await opened(paginator)

        await paginator.itemAppeared(id: 1)

        #expect(ids(await paginator.first { $0.items.count == 4 }) == [1, 2, 3, 4])
    }

    @Test func appearingOutsideDistanceDoesNothing() async {
        let calls = CallLog()
        let paginator = paginator(numbered(calls: calls), lookahead: 0) { $0.prefetchDistance = 1 }
        await opened(paginator)

        await paginator.itemAppeared(id: 1)

        #expect(await paginator.prefetchTask == nil)
        #expect(await calls.count == 1)

        await paginator.itemAppeared(id: 2)

        #expect(await paginator.first { $0.items.count == 4 }.items.count == 4)
    }

    @Test func unknownIDDoesNothing() async {
        let calls = CallLog()
        let paginator = paginator(numbered(calls: calls), lookahead: 0)
        await opened(paginator)

        await paginator.itemAppeared(id: 99)

        #expect(await paginator.prefetchTask == nil)
        #expect(await calls.count == 1)
    }

    @Test func noPrefetchWhileFailed() async {
        let calls = CallLog()
        let source = MockSource { token in
            await calls.record()
            guard token.page == 1 else { throw PageKitHTTPError(status: 404) }
            return page(1, 2, next: token.next)
        }
        let paginator = paginator(source, lookahead: 0)
        await opened(paginator)
        await paginator.loadNextPage()
        let failedAfter = await calls.count

        for _ in 1...10 { await paginator.itemAppeared(id: 2) }

        #expect(await paginator.prefetchTask == nil)
        #expect(await calls.count == failedAfter)
    }

    @Test func noPrefetchAtEnd() async {
        let calls = CallLog()
        let paginator = paginator(numbered(pages: 1, calls: calls), lookahead: 0)
        await opened(paginator)

        await paginator.itemAppeared(id: 2)

        #expect(await paginator.prefetchTask == nil)
        #expect(await calls.count == 1)
    }

    @Test func noPrefetchInBackground() async {
        let calls = CallLog()
        let paginator = paginator(numbered(calls: calls), lookahead: 0)
        await opened(paginator)

        await paginator.setAppActive(false)
        await paginator.itemAppeared(id: 2)

        #expect(await paginator.prefetchTask == nil)
        #expect(await calls.count == 1)

        await paginator.setAppActive(true)
        await paginator.itemAppeared(id: 2)

        #expect(await paginator.first { $0.items.count == 4 }.items.count == 4)
    }

    /// Pages served from memory never suspend, so a queued load finishes before the next
    /// one runs. Without a single slot, every appearance would load a page of its own.
    @Test func repeatedAppearancesLoadOnePage() async {
        let environment = PaginatorEnvironment.testing()
        let paginator = paginator(numbered(), lookahead: 3, environment: environment)
        await opened(paginator)

        await paginator.itemAppeared(id: 2, times: 10)
        _ = await paginator.first { $0.items.count >= 4 }
        await paginator.waitForReadAhead()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
    }

    @Test func blankPageStopsTheTriggerButNotAnExplicitLoad() async {
        let calls = CallLog()
        let source = MockSource { token in
            await calls.record()
            switch token.page {
            case 1: return page(1, 2, next: token.next)
            case 2: return page(next: token.next)
            default: return page(3, 4)
            }
        }
        let paginator = paginator(source, lookahead: 0)
        await opened(paginator)
        await paginator.loadNextPage()

        for _ in 1...10 { await paginator.itemAppeared(id: 2) }

        #expect(await paginator.prefetchTask == nil)
        #expect(await calls.count == 2)

        await paginator.loadNextPage()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
    }

    @Test func cancelStopsAQueuedPrefetch() async {
        let calls = CallLog()
        let paginator = paginator(numbered(calls: calls), lookahead: 0)
        await opened(paginator)

        await paginator.itemAppearedThenCancel(id: 2)

        #expect(await paginator.current().state == .loaded(hasMore: true))
        #expect(await calls.count == 1)
    }

    // MARK: Read-ahead

    @Test func onlyOneReadAheadRuns() async {
        let entered = Gate()
        let release = Gate()
        let paginator = paginator(holdingSecondPage(entered: entered, release: release))
        await paginator.start()
        await entered.wait()
        let running = await paginator.readAheadTask

        await paginator.scheduleReadAhead()

        #expect(await paginator.readAheadTask == running)
        await release.open()
    }

    /// The list moves on while a read-ahead is running, so the new page's `scheduleReadAhead`
    /// finds that one still set. Whatever ends it must pick up from the new `nextToken`.
    @Test func readAheadOvertakenByALoadRunsAgainFromTheNewEnd() async {
        let entered = Gate()
        let release = Gate()
        let reads = CallLog()
        var environment = PaginatorEnvironment.testing()
        // Read 1 finds no manifest. Read 2 is the read-ahead looking for page 2.
        environment.beforeDiskRead = {
            guard await reads.record() == 2 else { return }
            await entered.open()
            await release.wait()
        }
        let paginator = paginator(numbered(), environment: environment)
        await paginator.start()
        await entered.wait()

        await paginator.loadNextPage()
        await release.open()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        await expectParked(third, in: environment)
    }

    @Test func readAheadWaitsForTheFirstStatus() async {
        let connected = Gate()
        let environment = PaginatorEnvironment.testing(connectivity: HeldConnectivity(gate: connected))
        let paginator = paginator(numbered(), environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        #expect(await paginator.readAheadTask == nil)

        await connected.open()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        await expectParked(second, in: environment)
    }

    @Test func readAheadParksPageInCacheNotInList() async {
        let calls = CallLog()
        let environment = PaginatorEnvironment.testing()
        let paginator = paginator(numbered(calls: calls), environment: environment)

        await opened(paginator)

        #expect(ids(await paginator.current()) == [1, 2])
        #expect(await calls.count == 2)
        await expectParked(second, in: environment)
        await expectNotCached(third, in: environment)
    }

    @Test func readPageAppendsWithoutSecondSourceCall() async {
        let calls = CallLog()
        let paginator = paginator(numbered(pages: 2, calls: calls))
        await opened(paginator)

        await paginator.loadNextPage()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
        #expect(await calls.count == 2)
    }

    @Test func fetchJoinsAReadAheadUnderWay() async throws {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let paginator = paginator(holdingSecondPage(entered: entered, release: release, calls: calls))
        await paginator.start()
        await entered.wait()

        let joined = try await paginator.fetch(second, openingOnSuspend: release)

        #expect(joined.items.map(\.id) == [3, 4])
        #expect(await calls.count == 2)
    }

    @Test func cursorReadAheadIsSequential() async {
        let probe = ConcurrencyProbe()
        let requested = CallLog()
        let source = CursorMockSource { token in
            switch token.value {
            case nil: return page(1, 2, next: CursorToken(value: "b", size: 2))
            case "b":
                await requested.record()
                _ = await probe.enter()
                await Task.yield()
                await probe.leave()
                return page(3, 4, next: CursorToken(value: "c", size: 2))
            default:
                await requested.record()
                _ = await probe.enter()
                await probe.leave()
                return page(5, 6, next: CursorToken(value: "d", size: 2))
            }
        }
        let paginator = paginator(source, lookahead: 2)

        await opened(paginator)

        #expect(await requested.count == 2)
        #expect(await probe.peak == 1)
    }

    @Test func indexReadAheadRunsInParallelCappedAtTwo() async {
        let probe = ConcurrencyProbe()
        let bothRunning = Gate()
        let requested = CallLog()
        let source = MockSource { token in
            guard token.page > 1 else { return page(1, 2, next: token.next) }
            await requested.record()
            if await probe.enter() == 2 { await bothRunning.open() }
            await bothRunning.wait()
            await Task.yield()
            await probe.leave()
            return page(token.page * 10, next: token.next)
        }
        let paginator = paginator(source, lookahead: 3)

        await opened(paginator)

        #expect(await requested.count == 3)
        #expect(await probe.peak == 2)
    }

    @Test func noTypeCheckOnTokens() async {
        let probe = ConcurrencyProbe()
        let bothRunning = Gate()
        let source = ChapterSource { token in
            guard token.chapter > 1 else { return page(1, next: token.predictedNext) }
            if await probe.enter() == 2 { await bothRunning.open() }
            await bothRunning.wait()
            await Task.yield()
            await probe.leave()
            return page(token.chapter, next: token.predictedNext)
        }
        let paginator = paginator(source, lookahead: 2)

        await opened(paginator)

        #expect(await probe.peak == 2)
    }

    @Test func aPredictionTheServerContradictsIsNotParked() async {
        let environment = PaginatorEnvironment.testing()
        let source = MockSource { token in
            switch token.page {
            case 1: return page(1, 2, next: token.next)
            case 2: return page(3, 4)
            default: return page(98, 99)
            }
        }
        let paginator = paginator(source, lookahead: 2, environment: environment)

        await opened(paginator)

        await expectParked(second, in: environment)
        await expectNotCached(third, in: environment)
    }

    @Test func aPredictedPageIsNotParkedPastAFailure() async {
        let environment = PaginatorEnvironment.testing()
        let source = MockSource { token in
            switch token.page {
            case 1: return page(1, 2, next: token.next)
            case 2: throw PageKitHTTPError(status: 404)
            default: return page(5, 6)
            }
        }
        let paginator = paginator(source, lookahead: 2, environment: environment)

        await opened(paginator)

        await expectNotCached(second, in: environment)
        await expectNotCached(third, in: environment)
    }

    @Test func pagesAlreadyParkedCountTowardsLookahead() async {
        let calls = CallLog()
        let environment = PaginatorEnvironment.testing()
        let paginator = paginator(numbered(pages: 9, calls: calls), lookahead: 2, environment: environment)
        await opened(paginator)
        #expect(await calls.count == 3)

        await paginator.loadNextPage()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        // Pages 1 to 3 once each, plus page 4: page 3 was already parked.
        #expect(await calls.count == 4)
        await expectParked(first.next.next.next, in: environment)
    }

    @Test func readAheadSkippedOnExpensiveNetwork() async {
        let calls = CallLog()
        let connectivity = FakeConnectivity(initial: ConnectivityStatus(isOnline: true, isExpensive: true))
        let paginator = paginator(numbered(calls: calls), environment: .testing(connectivity: connectivity))

        await opened(paginator)

        #expect(await calls.count == 1)
    }

    @Test func readAheadSkippedOnConstrainedNetwork() async {
        let calls = CallLog()
        let connectivity = FakeConnectivity(initial: ConnectivityStatus(isOnline: true, isConstrained: true))
        let paginator = paginator(numbered(calls: calls), environment: .testing(connectivity: connectivity))

        await opened(paginator)

        #expect(await calls.count == 1)
    }

    @Test func readAheadSkippedWhenOffline() async {
        let calls = CallLog()
        let connectivity = FakeConnectivity(initial: ConnectivityStatus(isOnline: false))
        let paginator = paginator(numbered(calls: calls), environment: .testing(connectivity: connectivity)) {
            $0.allowsReadAheadOnExpensiveNetwork = true
        }

        await opened(paginator)

        #expect(await calls.count == 1)
    }

    @Test(arguments: [
        ConnectivityStatus(isOnline: true, isExpensive: true),
        ConnectivityStatus(isOnline: true, isConstrained: true),
    ]) func readAheadAllowedWhenAppOptsIn(status: ConnectivityStatus) async {
        let calls = CallLog()
        let connectivity = FakeConnectivity(initial: status)
        let paginator = paginator(numbered(calls: calls), environment: .testing(connectivity: connectivity)) {
            $0.allowsReadAheadOnExpensiveNetwork = true
        }

        await opened(paginator)

        #expect(await calls.count == 2)
    }

    @Test func distanceTriggerStillRunsOnExpensiveNetwork() async {
        let connectivity = FakeConnectivity(initial: ConnectivityStatus(isOnline: true, isExpensive: true))
        let paginator = paginator(numbered(), environment: .testing(connectivity: connectivity))
        await opened(paginator)

        await paginator.itemAppeared(id: 2)

        #expect(await paginator.first { $0.items.count == 4 }.items.count == 4)
    }

    @Test func lookaheadZeroDisablesReadAhead() async {
        let calls = CallLog()
        let paginator = paginator(numbered(calls: calls), lookahead: 0)

        await opened(paginator)

        #expect(await paginator.readAheadTask == nil)
        #expect(await calls.count == 1)
    }

    @Test(arguments: [(CachePolicy.networkOnly, 1), (.networkFirst, 1), (.cacheOnly, 0)])
    func onlyCacheThenNetworkReadsAhead(policy: CachePolicy, expectedCalls: Int) async {
        let calls = CallLog()
        let environment = PaginatorEnvironment.testing()
        await opened(paginator(numbered(), lookahead: 0, environment: environment))

        await opened(paginator(numbered(calls: calls), policy: policy, environment: environment))

        #expect(await calls.count == expectedCalls)
    }

    @Test func noReadAheadInBackground() async {
        let calls = CallLog()
        let paginator = paginator(numbered(calls: calls))

        await paginator.setAppActive(false)
        await opened(paginator)

        #expect(await calls.count == 1)
    }

    @Test func goingToTheBackgroundStopsTheReadAheadAfterTheCurrentPage() async {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let source = CursorMockSource { token in
            await calls.record()
            switch token.value {
            case nil: return page(1, next: CursorToken(value: "b", size: 2))
            case "b":
                await entered.open()
                await release.wait()
                return page(2, next: CursorToken(value: "c", size: 2))
            default: return page(3)
            }
        }
        let paginator = paginator(source, lookahead: 2)
        await paginator.start()
        await entered.wait()

        await paginator.setAppActive(false)
        await release.open()
        await paginator.waitForReadAhead()

        #expect(await calls.count == 2)
    }

    @Test func readAheadFailureDoesNotChangeState() async {
        let calls = CallLog()
        let source = MockSource { token in
            guard token.page == 1 else {
                await calls.record()
                throw PageKitHTTPError(status: 500)
            }
            return page(1, 2, next: token.next)
        }
        let paginator = paginator(source)

        await opened(paginator)
        let snapshot = await paginator.current()

        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(snapshot.lastError == nil)
        #expect(await paginator.lastFailedOperation == nil)
        #expect(await paginator.readAheadTask == nil)
        // One request with its retries. A failure must not start the read-ahead over.
        #expect(await calls.count == RetryPolicy.default.maxAttempts)
    }

    @Test func readAheadRunsOnceARestoredFirstPageIsConfirmed() async {
        let environment = PaginatorEnvironment.testing()
        let seeded = paginator(numbered(), lookahead: 0, environment: environment)
        await opened(seeded)

        let paginator = paginator(numbered(), environment: environment)
        await paginator.start()
        _ = await paginator.revalidated()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        await expectParked(second, in: environment)
    }

    // MARK: Keeping every cached page in the chain

    @Test func manifestDoesNotClaimParkedPages() async {
        let environment = PaginatorEnvironment.testing()
        let paginator = paginator(numbered(), environment: environment)

        await opened(paginator)

        let manifest = await environment.disk.manifest(feedID: "test", as: IndexToken.self, schemaVersion: 1)
        #expect(manifest?.tokens == [first])
        #expect(manifest?.lastNextToken == second)
    }

    @Test func parkedPageIsReachableAfterARelaunch() async {
        let environment = PaginatorEnvironment.testing()
        await opened(paginator(numbered(), environment: environment))
        environment.memory.removeAll()
        let calls = CallLog()
        let source = MockSource { [numbered = numbered()] token in
            if token.page == 2 { await calls.record() }
            return try await numbered.loadPage(token)
        }

        let reopened = paginator(source, lookahead: 0, environment: environment)
        await reopened.start()
        let restored = await reopened.revalidated()
        await reopened.loadNextPage()

        #expect(ids(restored) == [1, 2])
        #expect(ids(await reopened.current()) == [1, 2, 3, 4])
        #expect(await calls.count == 0)
    }

    @Test func refreshDropsAReadAheadUnderWay() async {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let environment = PaginatorEnvironment.testing()
        let source = MockSource { token in
            let call = await calls.record()
            if token.page == 2 {
                await entered.open()
                await release.wait()
                return page(3, 4)
            }
            return call == 1 ? page(1, 2, next: token.next) : page(7, 8)
        }
        let paginator = paginator(source, environment: environment)
        await paginator.start()
        await entered.wait()
        let readAhead = await paginator.readAheadTask

        await paginator.refresh()
        await release.open()
        await readAhead?.value
        await paginator.waitForPendingWrites()

        #expect(ids(await paginator.current()) == [7, 8])
        await expectNotCached(second, in: environment)
    }

    @Test func refreshDropsAParkedPage() async {
        let calls = CallLog()
        let environment = PaginatorEnvironment.testing()
        let source = MockSource { token in
            let call = await calls.record()
            if call == 1 { return page(1, 2, next: token.next) }
            return token.page == 1 && call > 2 ? page(7, 8) : page(3, 4)
        }
        let paginator = paginator(source, environment: environment)
        await opened(paginator)
        await expectParked(second, in: environment)

        await paginator.refresh()
        await paginator.waitForPendingWrites()

        await expectNotCached(second, in: environment)
    }

    @Test func failedRefreshKeepsAParkedPage() async {
        let calls = CallLog()
        let environment = PaginatorEnvironment.testing()
        let source = MockSource { token in
            let call = await calls.record()
            if call > 2 { throw PageKitHTTPError(status: 404) }
            return token.page == 1 ? page(1, 2, next: token.next) : page(3, 4)
        }
        let paginator = paginator(source, environment: environment)
        await opened(paginator)

        await paginator.refresh()

        await expectParked(second, in: environment)
    }

    @Test func changedFirstPageDropsAParkedPage() async {
        let environment = PaginatorEnvironment.testing()
        await opened(paginator(numbered(), environment: environment))
        await expectParked(second, in: environment)

        let reopened = paginator(MockSource { _ in page(7, 8) }, environment: environment)
        await reopened.start()
        _ = await reopened.revalidated()
        await reopened.waitForPendingWrites()

        await expectNotCached(second, in: environment)
    }

    /// The replaced chain's files go through the write queue, so a read-ahead starting
    /// straight after a refresh must not read one back into memory before it lands.
    @Test func aReadAheadCannotReadBackAPageBeingDiscarded() async {
        let plain = PaginatorEnvironment.testing()
        let entered = Gate()
        let release = Gate()
        let writes = CallLog()
        var held = plain
        // Page 1 queues a discard and a write, and read-ahead queues one. The next is the refresh's discard.
        held.beforeDiskWrite = {
            guard await writes.record() == 4 else { return }
            await entered.open()
            await release.wait()
        }
        let calls = CallLog()
        let source = MockSource { token in
            let call = await calls.record()
            if token.page == 2 { return call == 2 ? page(3, 4, next: token.next) : page(30, 40) }
            return call == 1 ? page(1, 2, next: token.next) : page(7, 8, next: token.next)
        }
        let paginator = paginator(source, environment: held)
        await opened(paginator)

        await paginator.refresh()
        await entered.wait()
        await release.open()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        #expect(memoryPage(second, in: plain)?.items.map(\.id) == [30, 40])
        #expect(await diskPage(second, in: plain)?.items.map(\.id) == [30, 40])
    }

    @Test func cancelDropsAReadAheadUnderWay() async {
        let entered = Gate()
        let release = Gate()
        let environment = PaginatorEnvironment.testing()
        let paginator = paginator(holdingSecondPage(entered: entered, release: release), environment: environment)
        await paginator.start()
        await entered.wait()
        let readAhead = await paginator.readAheadTask

        await paginator.cancel()
        await release.open()
        await readAhead?.value
        await paginator.waitForPendingWrites()

        await expectNotCached(second, in: environment)
        #expect(await paginator.readAheadTask == nil)
    }

    @Test func cancelWhileReadingTheCacheStopsAReadAhead() async {
        let entered = Gate()
        let release = Gate()
        let reads = CallLog()
        var environment = PaginatorEnvironment.testing()
        // Read 1 finds no manifest. Read 2 is the read-ahead looking for page 2.
        environment.beforeDiskRead = {
            guard await reads.record() == 2 else { return }
            await entered.open()
            await release.wait()
        }
        let calls = CallLog()
        let paginator = paginator(numbered(calls: calls), environment: environment)
        await paginator.start()
        await entered.wait()
        let readAhead = await paginator.readAheadTask

        await paginator.cancel()
        await release.open()
        await readAhead?.value

        #expect(await calls.count == 1)
    }

    @Test func readAheadStopsWalkingAtAClear() async {
        let entered = Gate()
        let release = Gate()
        let laterCalls = CallLog()
        let environment = PaginatorEnvironment.testing()
        let source = CursorMockSource { token in
            switch token.value {
            case nil: return page(1, next: CursorToken(value: "b", size: 2))
            case "b":
                await entered.open()
                await release.wait()
                return page(2, next: CursorToken(value: "c", size: 2))
            default:
                await laterCalls.record()
                return page(3, next: CursorToken(value: "d", size: 2))
            }
        }
        let paginator = paginator(source, lookahead: 2, environment: environment)
        await paginator.start()
        await entered.wait()

        await PageKit.clear(feedID: source.feedID, stores: [environment.disk], memory: environment.memory)
        await release.open()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        #expect(await laterCalls.count == 0)
        #expect(await environment.disk.storedFeeds().isEmpty)
        #expect(environment.memory.keyCount(for: source.feedID) == 0)
    }

    /// Read 3 is the read-ahead looking for page 3, and the clear lands while it is held.
    /// With `pageOnDisk`, the read still finds the page, as a read just ahead of a clear would.
    @Test(arguments: [false, true]) func readAheadStopsAtAClearDuringACacheRead(pageOnDisk: Bool) async {
        let entered = Gate()
        let release = Gate()
        let reads = CallLog()
        var environment = PaginatorEnvironment.testing()
        environment.beforeDiskRead = {
            guard await reads.record() == 3 else { return }
            await entered.open()
            await release.wait()
        }
        let laterCalls = CallLog()
        let third = CursorToken(value: "c", size: 2)
        let fourth = CursorToken(value: "d", size: 2)
        let source = CursorMockSource { token in
            switch token.value {
            case nil: return page(1, next: CursorToken(value: "b", size: 2))
            case "b": return page(2, next: third)
            default:
                await laterCalls.record()
                return page(9, next: fourth)
            }
        }
        let paginator = paginator(source, lookahead: 3, environment: environment)
        await paginator.start()
        await entered.wait()

        await PageKit.clear(feedID: source.feedID, stores: [environment.disk], memory: environment.memory)
        if pageOnDisk {
            let found: Page<TestItem, CursorToken> = page(3, next: fourth)
            await environment.disk.save(found, feedID: source.feedID, token: third, schemaVersion: 1)
        }
        await release.open()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        #expect(await laterCalls.count == 0)
        #expect(environment.memory.keyCount(for: source.feedID) == 0)
        if !pageOnDisk { #expect(await environment.disk.storedFeeds().isEmpty) }
    }

    /// The walk begins after the clear, so its own epoch is new, but the request it joins
    /// for page 2 is older. Page 3 starts in the same turn as that join, which proves it.
    @Test func walkJoiningARequestFromBeforeAClearStopsThere() async {
        let joined = Gate()
        let release = Gate()
        let environment = PaginatorEnvironment.testing()
        let source = MockSource { token in
            switch token.page {
            case 1: return page(1, 2, next: token.next)
            case 2: await release.wait()
            default: await joined.open()
            }
            return page(token.page * 10, next: token.next)
        }
        let paginator = paginator(source, lookahead: 2, environment: environment)
        await paginator.setAppActive(false)
        await opened(paginator)
        _ = await paginator.request(second)
        await clear(environment)

        await paginator.setAppActive(true)
        await paginator.scheduleReadAhead()
        await joined.wait()
        await release.open()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        await expectNotCached(second, in: environment)
        await expectNotCached(third, in: environment)
    }

    @Test func cancelBeforeAReadAheadBeginsStopsIt() async {
        let calls = CallLog()
        let paginator = paginator(numbered(calls: calls))
        await paginator.setAppActive(false)
        await opened(paginator)
        await paginator.setAppActive(true)

        await paginator.scheduleReadAheadThenCancel()

        #expect(await calls.count == 1)
        #expect(await paginator.readAheadTask == nil)
    }

    @Test func clearBeforeAReadAheadBeginsStopsIt() async {
        let calls = CallLog()
        let environment = PaginatorEnvironment.testing()
        let paginator = paginator(numbered(calls: calls), environment: environment)
        await paginator.setAppActive(false)
        await opened(paginator)
        await paginator.setAppActive(true)

        await paginator.scheduleReadAheadThenClear()

        #expect(await calls.count == 1)
    }

    @Test func readAheadRequestedBeforeAClearIsNotCached() async {
        let entered = Gate()
        let release = Gate()
        let environment = PaginatorEnvironment.testing()
        let paginator = paginator(holdingSecondPage(entered: entered, release: release), environment: environment)
        await paginator.start()
        await entered.wait()

        await clear(environment)
        await release.open()
        await paginator.waitForReadAhead()
        await paginator.waitForPendingWrites()

        await expectNotCached(second, in: environment)
    }

    @Test func joiningAReadAheadFromBeforeAClearKeepsItsEpoch() async {
        let entered = Gate()
        let release = Gate()
        let environment = PaginatorEnvironment.testing()
        let epochBefore = environment.disk.clearEpoch(for: "test")
        let paginator = paginator(holdingSecondPage(entered: entered, release: release), environment: environment)
        await paginator.start()
        await entered.wait()
        await clear(environment)

        let joined = await paginator.request(second)
        await release.open()
        await paginator.waitForReadAhead()

        #expect(joined.clearEpoch == epochBefore)
        #expect(environment.disk.clearEpoch(for: "test") != epochBefore)
    }

    // MARK: A load sharing a read-ahead's request

    /// Cancellation reaches the load by two routes, and either may land first.
    @Test func cancellingALoadBesideAReadAheadLeavesTheListCorrect() async {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let source = MockSource { token in
            guard token.page == 2 else { return page(1, 2, next: token.next) }
            if await calls.record() == 1 {
                await entered.open()
                await release.wait()
                try Task.checkCancellation()
            }
            return page(3, 4)
        }
        let paginator = paginator(source)
        await paginator.start()
        await entered.wait()
        let readAhead = await paginator.readAheadTask

        let load = Task { await paginator.loadNextPage() }
        _ = await paginator.first { $0.state == .loadingNextPage }
        load.cancel()
        let snapshot = await paginator.first { !$0.state.isLoading }
        await release.open()
        await load.value
        await readAhead?.value
        await paginator.waitForPendingWrites()

        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(ids(snapshot) == [1, 2])
        #expect(await paginator.readAheadTask == nil)
        #expect(await paginator.inFlight.isEmpty)

        // If `abandonLoad` ran before the load's guards, it cancelled the shared request and
        // a new one fetches page 2. If the guards saw the cancellation first, they restored
        // the state, `abandonLoad` did nothing, and the read-ahead parked page 2.
        await paginator.loadNextPage()

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
    }

    /// Holding the load inside its disk read keeps its guards back, so `abandonLoad` is
    /// sure to run first and cancel the request the read-ahead is waiting on.
    @Test func abandoningALoadEndsTheReadAheadsRequest() async {
        let sourceEntered = Gate(), sourceRelease = Gate()
        let readEntered = Gate(), readRelease = Gate()
        let calls = CallLog()
        let reads = CallLog()
        var environment = PaginatorEnvironment.testing()
        // Read 1 finds no manifest, read 2 is the read-ahead, and read 3 is the load.
        environment.beforeDiskRead = {
            guard await reads.record() == 3 else { return }
            await readEntered.open()
            await readRelease.wait()
        }
        let source = MockSource { token in
            guard token.page == 2 else { return page(1, 2, next: token.next) }
            await calls.record()
            await sourceEntered.open()
            await sourceRelease.wait()
            try Task.checkCancellation()
            return page(3, 4)
        }
        let paginator = paginator(source, environment: environment)
        await paginator.start()
        await sourceEntered.wait()
        let readAhead = await paginator.readAheadTask

        let load = Task { await paginator.loadNextPage() }
        await readEntered.wait()
        load.cancel()
        let snapshot = await paginator.first { !$0.state.isLoading }
        await sourceRelease.open()
        await readAhead?.value
        await readRelease.open()
        await load.value
        await paginator.waitForPendingWrites()

        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(ids(snapshot) == [1, 2])
        #expect(await calls.count == 1)
        await expectNotCached(second, in: environment)
    }
}
