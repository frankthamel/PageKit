import Foundation
import Testing
@testable import PageKit

/// A switch a source can read, to change what it serves part way through a test.
private actor Outage {
    private(set) var isOn: Bool

    init(isOn: Bool = false) {
        self.isOn = isOn
    }

    func set(_ isOn: Bool) {
        self.isOn = isOn
    }
}

@Suite struct PaginatorOfflineTests {
    private let offline = URLError(.notConnectedToInternet)
    private let connectivity = FakeConnectivity()
    private let first = IndexToken.first(size: 2)
    private var second: IndexToken { first.next }

    private var environment: PaginatorEnvironment { .testing(connectivity: connectivity) }

    /// Page 1 holds 1 and 2, page 2 holds 3 and 4, and page 3 holds 5 and ends the list.
    /// While `outage` is on, every page from `failingFrom` on fails as an offline device does.
    private func threePages(
        outage: Outage = Outage(), failingFrom: Int = 1, calls: CallLog = CallLog()
    ) -> MockSource {
        MockSource { [offline] token in
            await calls.record()
            if await outage.isOn, token.page >= failingFrom { throw offline }
            switch token.page {
            case 1: return page(1, 2, next: token.next)
            case 2: return page(3, 4, next: token.next)
            default: return page(5)
            }
        }
    }

    private func paginator(
        _ source: MockSource, policy: CachePolicy = .networkOnly, environment: PaginatorEnvironment
    ) -> Paginator<MockSource> {
        Paginator.testing(source, policy: policy, environment: environment)
    }

    private func ids(_ snapshot: PaginationSnapshot<TestItem>) -> [Int] {
        snapshot.items.map(\.id)
    }

    /// Goes offline and back, then waits for all that reconnecting started.
    private func flipOfflineAndBack(_ paginator: Paginator<MockSource>) async {
        connectivity.setOnline(false)
        _ = await paginator.first { $0.isOffline }
        connectivity.setOnline(true)
        _ = await paginator.first { !$0.isOffline }
        await paginator.waitForReconnect()
    }

    /// Saves `pages` pages, so a later paginator on `environment` has a chain to restore.
    private func seed(pages: Int, in environment: PaginatorEnvironment) async {
        let seeding = paginator(threePages(), policy: .networkFirst, environment: environment)
        await seeding.start()
        _ = await seeding.settled()
        for _ in 1..<pages { await seeding.loadNextPage() }
        await seeding.waitForPendingWrites()
        await seeding.cancel()
    }

    // MARK: isOffline

    @Test func isOfflineFollowsConnectivity() async {
        let paginator = paginator(threePages(), environment: environment)
        await paginator.start()
        let loaded = await paginator.settled()
        #expect(!loaded.isOffline)

        connectivity.setOnline(false)
        let wentOffline = await paginator.first { $0.isOffline }
        #expect(wentOffline.state == loaded.state)
        #expect(ids(wentOffline) == [1, 2])

        connectivity.setOnline(true)
        let cameBack = await paginator.first { !$0.isOffline }
        #expect(ids(cameBack) == [1, 2])
    }

    @Test func aStatusThatDoesNotChangeOfflinePublishesNothing() async {
        let paginator = paginator(threePages(), environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        let stream = paginator.snapshots()

        connectivity.set(ConnectivityStatus(isOnline: true, isExpensive: true))
        connectivity.setOnline(false)
        let seen = await collect(stream) { $0.isOffline }

        #expect(seen.count == 2)
    }

    @Test func isOfflineSetByOfflineError() async {
        let paginator = paginator(threePages(outage: Outage(isOn: true)), environment: environment)

        await paginator.start()
        let failed = await paginator.settled()

        #expect(failed.isOffline)
        #expect(failed.state == .failed(.offline, isFirstPage: true))
    }

    @Test func anotherErrorDoesNotSetIsOffline() async {
        let source = MockSource { _ in throw PageKitHTTPError(status: 500) }
        let paginator = paginator(source, environment: environment)

        await paginator.start()

        #expect(await !paginator.settled().isOffline)
    }

    @Test func failedRevalidationSetsIsOfflineAndKeepsTheItems() async {
        let environment = environment
        await seed(pages: 1, in: environment)
        let paginator = paginator(
            threePages(outage: Outage(isOn: true)), policy: .cacheThenNetwork, environment: environment
        )

        await paginator.start()
        let failed = await paginator.first { $0.lastError != nil }

        #expect(failed.isOffline)
        #expect(failed.isStale)
        #expect(ids(failed) == [1, 2])
    }

    @Test func offlineFirstLoadRecoveredFromCacheIsLabelledOffline() async {
        let environment = environment
        await seed(pages: 1, in: environment)
        let paginator = paginator(
            threePages(outage: Outage(isOn: true)), policy: .networkFirst, environment: environment
        )

        await paginator.start()
        let recovered = await paginator.first { !$0.items.isEmpty }

        #expect(recovered.isOffline)
    }

    @Test func aNetworkAnswerEndsAnOfflineThatOnlyAnErrorReported() async {
        let outage = Outage(isOn: true)
        let paginator = paginator(threePages(outage: outage), environment: environment)
        await paginator.start()
        #expect(await paginator.settled().isOffline)

        await outage.set(false)
        await paginator.retry()

        #expect(await !paginator.current().isOffline)
    }

    @Test func aConfirmedFirstPageEndsAnOfflineThatOnlyAnErrorReported() async {
        let environment = environment
        await seed(pages: 1, in: environment)
        let outage = Outage(isOn: true)
        let paginator = paginator(threePages(outage: outage), policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        #expect(await paginator.first { $0.lastError != nil }.isOffline)

        await outage.set(false)
        await paginator.retry()

        #expect(await !paginator.current().isOffline)
    }

    @Test func offlineMonitorDoesNotSkipTheRequest() async {
        let connectivity = FakeConnectivity(initial: ConnectivityStatus(isOnline: false))
        let calls = CallLog()
        let paginator = paginator(threePages(calls: calls), environment: .testing(connectivity: connectivity))

        await paginator.start()
        let loaded = await paginator.settled()
        await paginator.waitForReadAhead()

        #expect(ids(loaded) == [1, 2])
        #expect(await calls.count == 1)
        // The monitor made the claim, so only the monitor withdraws it.
        #expect(await paginator.first { $0.isOffline }.state == .loaded(hasMore: true))
    }

    // MARK: Reconnect

    @Test func reconnectRetriesPendingNextPage() async {
        let outage = Outage()
        let paginator = paginator(threePages(outage: outage, failingFrom: 3), environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.loadNextPage()
        await outage.set(true)
        await paginator.loadNextPage()
        #expect(await paginator.current().state == .failed(.offline, isFirstPage: false))

        connectivity.setOnline(false)
        _ = await paginator.first { $0.isOffline }
        await outage.set(false)
        connectivity.setOnline(true)
        let retried = await paginator.first { $0.state == .loaded(hasMore: false) }

        #expect(ids(retried) == [1, 2, 3, 4, 5])
        #expect(!retried.isOffline)
    }

    @Test func reconnectOnPageOneRefreshesThenRetriesThePendingNextPage() async {
        let outage = Outage()
        let calls = CallLog()
        let paginator = paginator(threePages(outage: outage, failingFrom: 2, calls: calls), environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await outage.set(true)
        await paginator.loadNextPage()
        let callsBefore = await calls.count

        await outage.set(false)
        await flipOfflineAndBack(paginator)

        #expect(ids(await paginator.current()) == [1, 2, 3, 4])
        #expect(await calls.count == callsBefore + 2)
    }

    @Test func aStatusChangeWhileOnlineIsNotAReconnect() async {
        let calls = CallLog()
        let paginator = paginator(threePages(calls: calls), environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.connectivityChanged(to: ConnectivityStatus(isOnline: true, isExpensive: true))
        await paginator.waitForReconnect()

        #expect(await calls.count == 1)
    }

    @Test func reconnectStillLoadsTheNextPageWhenRefreshReplacesTheList() async {
        let changed = Outage()
        let source = MockSource { [offline] token in
            let hasChanged = await changed.isOn
            if token.page == 1 { return hasChanged ? page(8, 9, next: token.next) : page(1, 2, next: token.next) }
            if !hasChanged { throw offline }
            return page(10)
        }
        let paginator = paginator(source, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.loadNextPage()

        await changed.set(true)
        await flipOfflineAndBack(paginator)

        #expect(ids(await paginator.current()) == [8, 9, 10])
    }

    @Test func reconnectRetriesAFirstPageThatFailed() async {
        let outage = Outage(isOn: true)
        let paginator = paginator(threePages(outage: outage), environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await outage.set(false)
        await flipOfflineAndBack(paginator)

        #expect(ids(await paginator.current()) == [1, 2])
    }

    @Test func reconnectRevalidatesWhenOnFirstPage() async {
        let environment = environment
        await seed(pages: 1, in: environment)
        let outage = Outage(isOn: true)
        let paginator = paginator(threePages(outage: outage), policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        #expect(await paginator.first { $0.lastError != nil }.isStale)

        await outage.set(false)
        await flipOfflineAndBack(paginator)

        let revalidated = await paginator.current()
        #expect(!revalidated.isStale)
        #expect(revalidated.lastError == nil)
    }

    @Test func reconnectNeverShrinksListPastFirstPage() async {
        let environment = environment
        await seed(pages: 2, in: environment)
        let calls = CallLog()
        let outage = Outage(isOn: true)
        let source = threePages(outage: outage, calls: calls)
        let paginator = paginator(source, policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        _ = await paginator.first { $0.lastError != nil }
        let callsBefore = await calls.count

        await outage.set(false)
        await flipOfflineAndBack(paginator)

        let snapshot = await paginator.current()
        #expect(ids(snapshot) == [1, 2, 3, 4])
        #expect(snapshot.isStale)
        #expect(await calls.count == callsBefore)
    }

    @Test func reconnectUnderCacheOnlyStaysOffTheNetwork() async {
        let environment = environment
        await seed(pages: 1, in: environment)
        let calls = CallLog()
        let paginator = paginator(threePages(calls: calls), policy: .cacheOnly, environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await flipOfflineAndBack(paginator)

        #expect(await calls.count == 0)
    }

    @Test func reconnectLeavesALoadUnderWayAlone() async {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let paginator = paginator(MockSource { token in
            await calls.record()
            if token.page == 2 {
                await entered.open()
                await release.wait()
            }
            return page(token.page, next: token.next)
        }, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        let load = Task { await paginator.loadNextPage() }
        await entered.wait()

        await flipOfflineAndBack(paginator)

        #expect(await calls.count == 2)
        await release.open()
        await load.value
    }

    @Test func aFailureThatOutlastsAReconnectIsPickedUpWhenItLands() async {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let paginator = paginator(MockSource { [offline] token in
            let call = await calls.record()
            if token.page == 1 { return page(1, next: token.next) }
            if call == 2 {
                await entered.open()
                await release.wait()
                throw offline
            }
            return page(2)
        }, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        let load = Task { await paginator.loadNextPage() }
        await entered.wait()
        await flipOfflineAndBack(paginator)

        await release.open()
        await load.value
        await paginator.waitForReconnect()

        let snapshot = await paginator.first { $0.state == .loaded(hasMore: false) }
        #expect(ids(snapshot) == [1, 2])
        #expect(!snapshot.isOffline)
    }

    @Test func aLoadThatSucceedsLeavesNothingForTheReconnectToDo() async {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let paginator = paginator(MockSource { token in
            await calls.record()
            await entered.open()
            await release.wait()
            return page(1)
        }, environment: environment)
        await paginator.start()
        await entered.wait()
        await flipOfflineAndBack(paginator)

        await release.open()
        _ = await paginator.settled()
        await paginator.waitForReconnect()

        #expect(await calls.count == 1)
    }

    @Test func goingOfflineAgainDropsAResumeThatWasWaiting() async {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let paginator = paginator(MockSource { token in
            await calls.record()
            await entered.open()
            await release.wait()
            throw PageKitHTTPError(status: 400)
        }, environment: environment)
        await paginator.start()
        await entered.wait()
        await flipOfflineAndBack(paginator)
        connectivity.setOnline(false)
        _ = await paginator.first { $0.isOffline }

        await release.open()
        _ = await paginator.settled()
        await paginator.waitForReconnect()

        #expect(await calls.count == 1)
    }

    @Test func aReconnectInTheBackgroundWaitsForTheForeground() async {
        let outage = Outage()
        let calls = CallLog()
        let paginator = paginator(threePages(outage: outage, failingFrom: 2, calls: calls), environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await outage.set(true)
        await paginator.loadNextPage()
        await outage.set(false)
        await paginator.setAppActive(false)
        let callsBefore = await calls.count

        await flipOfflineAndBack(paginator)
        #expect(await calls.count == callsBefore)

        await paginator.setAppActive(true)

        #expect(ids(await paginator.first { $0.state == .loaded(hasMore: true) && $0.items.count == 4 }) == [1, 2, 3, 4])
    }

    // MARK: Read-ahead

    @Test func readAheadUsesTheLatestStatusFromOneStream() async {
        let environment = environment
        let paginator = paginator(threePages(), policy: .cacheThenNetwork, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForReadAhead()
        await paginator.loadNextPage()
        await paginator.waitForReadAhead()

        #expect(connectivity.streamsOpened == 1)
    }

    @Test func aBetterConnectionStartsTheReadAheadItHeldBack() async {
        let connectivity = FakeConnectivity(initial: ConnectivityStatus(isOnline: true, isExpensive: true))
        var configuration = PaginationConfiguration.testing(.cacheThenNetwork)
        configuration.lookaheadPages = 1
        let calls = CallLog()
        let paginator = Paginator(
            source: threePages(calls: calls), configuration: configuration,
            environment: .testing(connectivity: connectivity)
        )
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForReadAhead()
        #expect(await calls.count == 1)

        connectivity.set(.online)
        while await calls.count < 2 { await Task.yield() }
    }

    // MARK: Listener life cycle

    @Test func startingAgainKeepsOneListener() async {
        let calls = CallLog()
        let paginator = paginator(MockSource { token in
            if await calls.record() == 1 { throw CancellationError() }
            return page(1, next: token.next)
        }, environment: environment)
        let stream = paginator.snapshots()
        await paginator.start()
        _ = await collect(stream) { $0.state == .loadingFirstPage }
        _ = await collect(stream) { $0.state == .idle }

        await paginator.start()
        _ = await paginator.settled()

        #expect(connectivity.streamsOpened == 1)
    }

    @Test func droppingThePaginatorEndsItsListener() async {
        let environment = environment
        var paginator: Paginator<MockSource>? = paginator(threePages(), environment: environment)
        await paginator?.start()
        _ = await paginator?.settled()
        #expect(connectivity.listenerCount == 1)

        paginator = nil

        while connectivity.listenerCount > 0 { await Task.yield() }
    }

    // MARK: Cancel

    @Test func cancelFinishesAllStreams() async {
        let paginator = paginator(threePages(), environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        let streams = [paginator.snapshots(), paginator.snapshots()]

        await paginator.cancel()

        for stream in streams {
            for await _ in stream {}
        }
        #expect(paginator.broadcaster.subscriberCount == 0)
    }

    @Test func cancelStopsListeningForConnectivity() async {
        let paginator = paginator(threePages(), environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.cancel()

        while connectivity.listenerCount > 0 { await Task.yield() }
    }

    @Test func cancelDeliversTheRestoredStateBeforeFinishing() async {
        let entered = Gate()
        let release = Gate()
        let paginator = paginator(MockSource { _ in
            await entered.open()
            await release.wait()
            return page(1)
        }, environment: environment)
        await paginator.start()
        await entered.wait()
        let stream = paginator.snapshots()

        await paginator.cancel()

        var last: PaginationSnapshot<TestItem>?
        for await snapshot in stream { last = snapshot }
        #expect(last?.state == .idle)
        await release.open()
    }

    @Test func snapshotsAfterCancelFinishesImmediately() async {
        let paginator = paginator(threePages(), environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.cancel()

        var seen: [PaginationSnapshot<TestItem>] = []
        for await snapshot in paginator.snapshots() { seen.append(snapshot) }

        #expect(seen.map(ids) == [[1, 2]])
        #expect(paginator.broadcaster.subscriberCount == 0)
    }

    @Test func cancellingTwiceIsHarmless() async {
        let paginator = paginator(threePages(), environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.cancel()
        await paginator.cancel()

        for await _ in paginator.snapshots() {}
    }

    @Test func lateResultAfterCancelIsIgnored() async {
        let entered = Gate()
        let release = Gate()
        let paginator = paginator(MockSource { token in
            if token.page == 2 {
                await entered.open()
                await release.wait()
            }
            return page(token.page, next: token.next)
        }, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        let load = Task { await paginator.loadNextPage() }
        await entered.wait()

        await paginator.cancel()
        await release.open()
        await load.value

        let snapshot = await paginator.current()
        #expect(ids(snapshot) == [1])
        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(await paginator.items.map(\.id) == [1])
    }

    @Test func cancelStopsRetryBackoff() async {
        let waiting = Gate()
        let woken = Gate()
        let calls = CallLog()
        let environment = PaginatorEnvironment.testing(connectivity: connectivity, sleep: { _ in
            await waiting.open()
            defer { Task { await woken.open() } }
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        })
        let paginator = paginator(MockSource { _ in
            await calls.record()
            throw PageKitHTTPError(status: 500)
        }, environment: environment)
        await paginator.start()
        await waiting.wait()

        await paginator.cancel()
        await woken.wait()

        #expect(await calls.count == 1)
        #expect(await paginator.current().state == .idle)
    }

    @Test func startAfterCancelIsANoOp() async {
        let calls = CallLog()
        let paginator = paginator(threePages(calls: calls), environment: environment)

        await paginator.cancel()
        await paginator.start()

        #expect(await paginator.startTask == nil)
        #expect(await paginator.current().state == .idle)
        #expect(await calls.count == 0)
    }

    @Test func startAfterCancellingALoadIsANoOp() async {
        let entered = Gate()
        let release = Gate()
        let calls = CallLog()
        let paginator = paginator(MockSource { _ in
            await calls.record()
            await entered.open()
            await release.wait()
            return page(1)
        }, environment: environment)
        await paginator.start()
        await entered.wait()

        await paginator.cancel()
        await paginator.start()
        await release.open()

        #expect(await paginator.startTask == nil)
        #expect(await calls.count == 1)
        #expect(await paginator.current().state == .idle)
    }

    @Test func nothingLoadsAfterCancel() async {
        let outage = Outage(isOn: true)
        let calls = CallLog()
        let paginator = paginator(threePages(outage: outage, failingFrom: 2, calls: calls), environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await paginator.waitForReadAhead()
        await paginator.loadNextPage()
        await outage.set(false)
        let callsBefore = await calls.count

        await paginator.cancel()
        await paginator.retry()
        await paginator.refresh()
        await paginator.prefetch(upToIndex: 1)
        await paginator.prefetchTask?.value
        await paginator.connectivityChanged(to: ConnectivityStatus(isOnline: true, isExpensive: true))
        await paginator.waitForReconnect()

        #expect(await calls.count == callsBefore)
        #expect(await paginator.connectivityStatus == .online)
    }

    @Test func retryingARevalidationAfterCancelLoadsNothing() async {
        let environment = environment
        await seed(pages: 1, in: environment)
        let calls = CallLog()
        let paginator = paginator(
            threePages(outage: Outage(isOn: true), calls: calls), policy: .cacheThenNetwork, environment: environment
        )
        await paginator.start()
        _ = await paginator.first { $0.lastError != nil }
        let callsBefore = await calls.count

        await paginator.cancel()
        await paginator.retry()

        #expect(await calls.count == callsBefore)
    }

    @Test func cancelStraightAfterAReconnectStopsItsWork() async {
        let calls = CallLog()
        let paginator = paginator(threePages(calls: calls), environment: environment)
        await paginator.start()
        _ = await paginator.settled()

        await paginator.reconnectThenCancel()

        #expect(await calls.count == 1)
    }

    @Test func cancelDuringAReconnectEndsIt() async {
        let entered = Gate()
        let release = Gate()
        let held = Outage()
        let calls = CallLog()
        let paginator = paginator(MockSource { token in
            await calls.record()
            if await held.isOn {
                await entered.open()
                await release.wait()
            }
            return page(token.page, next: token.next)
        }, environment: environment)
        await paginator.start()
        _ = await paginator.settled()
        await held.set(true)

        connectivity.setOnline(false)
        _ = await paginator.first { $0.isOffline }
        connectivity.setOnline(true)
        await entered.wait()
        await paginator.cancel()
        await release.open()
        await paginator.waitForReconnect()

        #expect(await calls.count == 2)
        #expect(ids(await paginator.current()) == [1])
    }
}
