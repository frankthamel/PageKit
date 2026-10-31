import Foundation
import Testing
@testable import PageKit

@Suite struct PaginatorLoadingTests {
    private let serverFailure = PaginationError.server(status: 500)

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

    private func ids(_ snapshot: PaginationSnapshot<TestItem>) -> [Int] {
        snapshot.items.map(\.id)
    }

    // MARK: First page and next page

    @Test func firstPageLoadsThenLoaded() async {
        let paginator = Paginator.testing(threePages())
        let stream = paginator.snapshots()

        await paginator.start()
        let seen = await collect(stream) { $0.state == .loaded(hasMore: true) }

        #expect(seen.map(\.state) == [.idle, .loadingFirstPage, .loaded(hasMore: true)])
        #expect(ids(seen[2]) == [1, 2])
    }

    @Test func startTwiceLoadsOnce() async {
        let calls = CallLog()
        let paginator = Paginator.testing(threePages(calls: calls))

        await paginator.start()
        await paginator.start()
        _ = await paginator.settled()
        await paginator.start()

        #expect(await calls.count == 1)
    }

    @Test func emptyFirstPageIsEmpty() async {
        let paginator = Paginator.testing(MockSource { _ in page() })

        await paginator.start()

        #expect(await paginator.settled().state == .empty)
    }

    @Test func stopsWhenNextTokenIsNil() async {
        let calls = CallLog()
        let paginator = Paginator.testing(threePages(calls: calls))
        await paginator.start()
        _ = await paginator.settled()

        await paginator.loadNextPage()
        await paginator.loadNextPage()
        let end = await paginator.current()
        await paginator.loadNextPage()

        #expect(end.state == .loaded(hasMore: false))
        #expect(ids(end) == [1, 2, 3, 4, 5])
        #expect(await calls.count == 3)
    }

    @Test func nextPageAppends() async {
        let paginator = Paginator.testing(threePages())
        await paginator.start()
        _ = await paginator.settled()

        await paginator.loadNextPage()

        let snapshot = await paginator.current()
        #expect(ids(snapshot) == [1, 2, 3, 4])
        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(await paginator.pageOrder.map(\.page) == [1, 2])
        #expect(await paginator.indexByID[TestItem(id: 3).id] == 2)
        #expect(await paginator.pageByItem[TestItem(id: 3).id]?.page == 2)
    }

    @Test func indexAndCursorSourcesProduceSameStates() async {
        let index = Paginator.testing(MockSource { token in
            token.page == 1 ? page(1, 2, next: token.next) : page(3)
        })
        let cursor = Paginator.testing(CursorMockSource { token in
            token.value == nil ? page(1, 2, next: CursorToken(value: "b", size: token.size)) : page(3)
        })

        let indexRun = await run(index)
        let cursorRun = await run(cursor)

        #expect(indexRun.states == cursorRun.states)
        #expect(indexRun.ids == cursorRun.ids)
        #expect(indexRun.ids == [1, 2, 3])
    }

    private func run<Source>(
        _ paginator: Paginator<Source>
    ) async -> (states: [PaginationState], ids: [Int]) where Source.Item == TestItem {
        let stream = paginator.snapshots()
        await paginator.start()
        _ = await paginator.settled()
        await paginator.loadNextPage()
        let seen = await collect(stream) { $0.state == .loaded(hasMore: false) }
        return (seen.map(\.state), seen.last?.items.map(\.id) ?? [])
    }

    @Test func concurrentRequestsForSamePageHitTheNetworkOnce() async throws {
        let calls = CallLog()
        let entered = Gate()
        let release = Gate()
        let source = MockSource { token in
            await calls.record()
            await entered.open()
            await release.wait()
            return page(1, next: token.next)
        }
        let paginator = Paginator.testing(source)
        let token = source.firstToken

        let first = Task { try await paginator.fetch(token) }
        await entered.wait()
        let second = try await paginator.fetch(token, openingOnSuspend: release)

        #expect(try await first.value.items == second.items)
        #expect(await calls.count == 1)
        #expect(await paginator.inFlight.isEmpty)
    }

    @Test func staleFetchDoesNotClearTheNewerInFlightEntry() async throws {
        let calls = CallLog()
        let oldEntered = Gate(), newEntered = Gate()
        let oldRelease = Gate(), newRelease = Gate()
        let source = MockSource { _ in
            if await calls.record() == 1 {
                await oldEntered.open()
                await oldRelease.wait()
            } else {
                await newEntered.open()
                await newRelease.wait()
            }
            return page(1)
        }
        let paginator = Paginator.testing(source)

        let stale = Task { try await paginator.fetch(source.firstToken) }
        await oldEntered.wait()
        let refresh = Task { await paginator.refresh() }
        await newEntered.wait()
        await oldRelease.open()
        _ = try? await stale.value

        #expect(await paginator.inFlight[source.firstToken] != nil)

        await newRelease.open()
        await refresh.value
    }

    @Test func loadNextPageIsANoOpUnlessLoadedWithMore() async {
        let calls = CallLog()
        let source = MockSource { token in
            let call = await calls.record()
            if call == 2 { throw PageKitHTTPError(status: 404) }
            return token.page == 1 ? page(1, next: token.next) : page(2)
        }
        let paginator = Paginator.testing(source)

        await paginator.loadNextPage()
        #expect(await calls.count == 0)    // idle

        await paginator.start()
        _ = await paginator.settled()
        await paginator.loadNextPage()     // fails
        #expect(await calls.count == 2)
        await paginator.loadNextPage()     // failed
        #expect(await calls.count == 2)

        await paginator.retry()
        #expect(await paginator.current().state == .loaded(hasMore: false))
        await paginator.loadNextPage()     // end
        #expect(await calls.count == 3)
    }

    // MARK: De-duplication

    @Test func duplicateIDsAcrossPagesAreDropped() async {
        let paginator = Paginator.testing(MockSource { token in
            token.page == 1 ? page(1, 2, next: token.next) : page(2, 3)
        })
        await paginator.start()
        _ = await paginator.settled()

        await paginator.loadNextPage()

        #expect(ids(await paginator.current()) == [1, 2, 3])
        #expect(await paginator.indexByID.count == 3)
        #expect(await paginator.indexByID[TestItem(id: 3).id] == 2)
        #expect(await paginator.pageByItem[TestItem(id: 2).id]?.page == 1)
    }

    @Test func duplicateIDsInsideOnePageAreDropped() async {
        let paginator = Paginator.testing(MockSource { _ in page(1, 1, 2, 1) })

        await paginator.start()

        #expect(ids(await paginator.settled()) == [1, 2])
        #expect(await paginator.indexByID[TestItem(id: 2).id] == 1)
    }

    @Test func allDuplicatePageStillAdvancesTheToken() async {
        let requested = CallLog()
        let paginator = Paginator.testing(MockSource { token in
            await requested.record()
            switch token.page {
            case 1: return page(1, 2, next: token.next)
            case 2: return page(1, 2, next: token.next)
            default: return page(3)
            }
        })
        await paginator.start()
        _ = await paginator.settled()

        await paginator.loadNextPage()
        #expect(await paginator.current().state == .loaded(hasMore: true))
        await paginator.loadNextPage()

        #expect(ids(await paginator.current()) == [1, 2, 3])
        #expect(await requested.count == 3)
    }

    @Test func emptyPageWithNextTokenDoesNotAutoLoop() async {
        let calls = CallLog()
        let later = Paginator.testing(MockSource { token in
            await calls.record()
            return token.page == 1 ? page(1, next: token.next) : page(next: token.next)
        })
        await later.start()
        _ = await later.settled()

        await later.loadNextPage()

        #expect(await later.current().state == .loaded(hasMore: true))
        #expect(await calls.count == 2)
        #expect(await later.nextToken?.page == 3)

        let firstCalls = CallLog()
        let first = Paginator.testing(MockSource { token in
            await firstCalls.record()
            return page(next: token.next)
        })
        await first.start()

        #expect(await first.settled().state == .empty)
        await first.loadNextPage()
        #expect(await firstCalls.count == 1)
    }

    // MARK: Refresh

    @Test func staleResponseAfterRefreshIsDiscarded() async {
        let firstPageCalls = CallLog()
        let entered = Gate()
        let release = Gate()
        let paginator = Paginator.testing(MockSource { token in
            if token.page == 1 {
                return await firstPageCalls.record() == 1 ? page(1, 2, next: token.next) : page(10, 11)
            }
            await entered.open()
            await release.wait()
            return page(3, 4)
        })
        await paginator.start()
        _ = await paginator.settled()

        let stale = Task { await paginator.loadNextPage() }
        await entered.wait()
        await paginator.refresh()
        await release.open()
        await stale.value

        let snapshot = await paginator.current()
        #expect(ids(snapshot) == [10, 11])
        #expect(snapshot.state == .loaded(hasMore: false))
    }

    @Test func refreshSuccessReplacesTheList() async {
        let calls = CallLog()
        let paginator = Paginator.testing(MockSource { token in
            await calls.record() == 1 ? page(1, 2, next: token.next) : page(2, 9, next: token.next)
        })
        await paginator.start()
        _ = await paginator.settled()
        let stream = paginator.snapshots()

        await paginator.refresh()
        let seen = await collect(stream) { $0.state == .loaded(hasMore: true) && $0.items.last?.id == 9 }

        #expect(seen.map(\.state) == [.loaded(hasMore: true), .refreshing, .loaded(hasMore: true)])
        #expect(ids(seen[2]) == [2, 9])
        #expect(await paginator.pageOrder.count == 1)
        #expect(await paginator.indexByID[TestItem(id: 2).id] == 0)
        #expect(await paginator.indexByID[TestItem(id: 1).id] == nil)
        #expect(await paginator.pageByItem[TestItem(id: 1).id] == nil)
    }

    @Test func refreshToAnEmptyListIsEmpty() async {
        let calls = CallLog()
        let paginator = Paginator.testing(MockSource { _ in
            await calls.record() == 1 ? page(1) : page()
        })
        await paginator.start()
        _ = await paginator.settled()

        await paginator.refresh()

        let snapshot = await paginator.current()
        #expect(snapshot.state == .empty)
        #expect(snapshot.items.isEmpty)
    }

    @Test func refreshBeforeStartLoadsTheFirstPage() async {
        let paginator = Paginator.testing(threePages())
        let stream = paginator.snapshots()

        await paginator.refresh()
        let seen = await collect(stream) { $0.state == .loaded(hasMore: true) }

        #expect(seen.map(\.state) == [.idle, .loadingFirstPage, .loaded(hasMore: true)])
    }

    @Test func failedRefreshKeepsItemsAndSetsLastError() async {
        let calls = CallLog()
        let paginator = Paginator.testing(MockSource { token in
            if await calls.record() == 1 { return page(1, 2, next: token.next) }
            throw PageKitHTTPError(status: 500)
        })
        await paginator.start()
        _ = await paginator.settled()

        await paginator.refresh()

        let snapshot = await paginator.current()
        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(ids(snapshot) == [1, 2])
        #expect(snapshot.lastError == serverFailure)
    }

    @Test func failedRefreshAfterFailedNextPageReturnsToLoaded() async {
        let calls = CallLog()
        let paginator = Paginator.testing(MockSource { token in
            if await calls.record() == 1 { return page(1, next: token.next) }
            throw PageKitHTTPError(status: 404)
        })
        await paginator.start()
        _ = await paginator.settled()
        await paginator.loadNextPage()

        await paginator.refresh()

        let snapshot = await paginator.current()
        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(snapshot.lastError == .client(status: 404))
    }

    @Test func loadingContinuesAfterFailedRefresh() async {
        let calls = CallLog()
        let paginator = Paginator.testing(MockSource { token in
            if await calls.record() == 2 { throw PageKitHTTPError(status: 404) }
            return token.page == 1 ? page(1, 2, next: token.next) : page(3)
        })
        await paginator.start()
        _ = await paginator.settled()
        await paginator.refresh()

        await paginator.loadNextPage()

        let snapshot = await paginator.current()
        #expect(ids(snapshot) == [1, 2, 3])
        #expect(snapshot.state == .loaded(hasMore: false))
    }

    @Test func refreshDuringARefreshRestarts() async {
        let calls = CallLog()
        let cancelledRequests = CallLog()
        let entered = Gate()
        let release = Gate()
        let paginator = Paginator.testing(MockSource { token in
            switch await calls.record() {
            case 1: return page(1, next: token.next)
            case 2:
                await entered.open()
                await release.wait()
                if Task.isCancelled { await cancelledRequests.record() }
                return page(8)
            default: return page(9)
            }
        })
        await paginator.start()
        _ = await paginator.settled()

        let first = Task { await paginator.refresh() }
        await entered.wait()
        await paginator.refresh()
        await release.open()
        await first.value

        let snapshot = await paginator.current()
        #expect(ids(snapshot) == [9])
        #expect(snapshot.state == .loaded(hasMore: false))
        #expect(await calls.count == 3)
        #expect(await cancelledRequests.count == 1)
    }

    @Test func staleFailureAfterRefreshIsDiscarded() async {
        let firstPageCalls = CallLog()
        let entered = Gate()
        let release = Gate()
        let paginator = Paginator.testing(MockSource { token in
            if token.page == 1 {
                await firstPageCalls.record()
                return page(1, next: token.next)
            }
            await entered.open()
            await release.wait()
            throw PageKitHTTPError(status: 404)
        })
        await paginator.start()
        _ = await paginator.settled()

        let stale = Task { await paginator.loadNextPage() }
        await entered.wait()
        await paginator.refresh()
        await release.open()
        await stale.value

        let snapshot = await paginator.current()
        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(snapshot.lastError == nil)
        #expect(await paginator.lastFailedOperation == nil)
    }

    // MARK: Failures and retry

    @Test func failedNextPageKeepsItems() async {
        let paginator = Paginator.testing(MockSource { token in
            if token.page == 2 { throw PageKitHTTPError(status: 500) }
            return page(1, 2, next: token.next)
        })
        await paginator.start()
        _ = await paginator.settled()

        await paginator.loadNextPage()

        let snapshot = await paginator.current()
        #expect(snapshot.state == .failed(serverFailure, isFirstPage: false))
        #expect(ids(snapshot) == [1, 2])
    }

    @Test func failedFirstPageWithNoItemsIsFullScreenFailure() async {
        let paginator = Paginator.testing(MockSource { _ in throw PageKitHTTPError(status: 500) })

        await paginator.start()

        let snapshot = await paginator.settled()
        #expect(snapshot.state == .failed(serverFailure, isFirstPage: true))
        #expect(snapshot.items.isEmpty)
    }

    @Test func failedRefreshWithNoItemsIsFullScreenFailure() async {
        let paginator = Paginator.testing(MockSource { _ in throw PageKitHTTPError(status: 404) })

        await paginator.refresh()

        #expect(await paginator.current().state == .failed(.client(status: 404), isFirstPage: true))
    }

    @Test func retriesRetryableFailuresWithinOneLoad() async {
        let calls = CallLog()
        let paginator = Paginator.testing(MockSource { _ in
            if await calls.record() < 3 { throw PageKitHTTPError(status: 503) }
            return page(1)
        })

        await paginator.start()

        #expect(ids(await paginator.settled()) == [1])
        #expect(await calls.count == 3)
    }

    @Test func retryRepeatsTheFailedOperation() async {
        // First page.
        let firstCalls = CallLog()
        let first = Paginator.testing(MockSource { _ in
            if await firstCalls.record() == 1 { throw PageKitHTTPError(status: 404) }
            return page(1)
        })
        await first.start()
        _ = await first.settled()
        await first.retry()
        #expect(ids(await first.current()) == [1])

        // Next page.
        let nextCalls = CallLog()
        let next = Paginator.testing(MockSource { token in
            if await nextCalls.record() == 2 { throw PageKitHTTPError(status: 404) }
            return token.page == 1 ? page(1, next: token.next) : page(2)
        })
        await next.start()
        _ = await next.settled()
        await next.loadNextPage()
        await next.retry()
        #expect(ids(await next.current()) == [1, 2])

        // Refresh: the retry replaces the list rather than appending to it.
        let refreshCalls = CallLog()
        let refresh = Paginator.testing(MockSource { token in
            switch await refreshCalls.record() {
            case 1: return page(1, next: token.next)
            case 2: throw PageKitHTTPError(status: 404)
            default: return page(7)
            }
        })
        await refresh.start()
        _ = await refresh.settled()
        await refresh.refresh()
        await refresh.retry()
        #expect(ids(await refresh.current()) == [7])
    }

    @Test func retryDoesNothingWithoutAFailure() async {
        let calls = CallLog()
        let paginator = Paginator.testing(threePages(calls: calls))

        await paginator.retry()
        await paginator.start()
        _ = await paginator.settled()
        await paginator.retry()

        #expect(await calls.count == 1)
    }

    @Test func lastErrorClearsOnNextSuccess() async {
        let calls = CallLog()
        let paginator = Paginator.testing(MockSource { token in
            if await calls.record() == 2 { throw PageKitHTTPError(status: 404) }
            return page(1, next: token.next)
        })
        await paginator.start()
        _ = await paginator.settled()
        await paginator.refresh()
        #expect(await paginator.current().lastError == .client(status: 404))

        await paginator.loadNextPage()

        #expect(await paginator.current().lastError == nil)
        #expect(await paginator.lastFailedOperation == nil)
    }

    @Test func lastErrorSurvivesALaterNextPageFailure() async {
        let calls = CallLog()
        let paginator = Paginator.testing(MockSource { token in
            switch await calls.record() {
            case 2: throw PageKitHTTPError(status: 404)
            case 3: throw PageKitHTTPError(status: 403)
            default: return page(1, next: token.next)
            }
        })
        await paginator.start()
        _ = await paginator.settled()
        await paginator.refresh()

        await paginator.loadNextPage()

        let failed = await paginator.current()
        #expect(failed.state == .failed(.client(status: 403), isFirstPage: false))
        #expect(failed.lastError == .client(status: 404))

        await paginator.retry()
        #expect(await paginator.current().lastError == nil)
    }

    // MARK: Snapshots

    @Test func snapshotStreamStartsWithCurrentValue() async {
        let paginator = Paginator.testing(threePages())
        var early = paginator.snapshots().makeAsyncIterator()
        #expect(await early.next()?.state == .idle)

        await paginator.start()
        _ = await paginator.settled()

        var late = paginator.snapshots().makeAsyncIterator()
        let first = await late.next()
        #expect(first?.state == .loaded(hasMore: true))
        #expect(first?.items.count == 2)
    }

    @Test func twoObserversBothReceiveUpdates() async {
        let paginator = Paginator.testing(threePages())
        let first = paginator.snapshots()
        let second = paginator.snapshots()

        await paginator.start()
        let isDone: (PaginationSnapshot<TestItem>) -> Bool = { $0.state == .loaded(hasMore: true) }
        let firstSeen = await collect(first, until: isDone)
        let secondSeen = await collect(second, until: isDone)

        #expect(firstSeen.map(\.state) == secondSeen.map(\.state))
        #expect(firstSeen.count == 3)
    }

    @Test func abandonedStreamIsForgotten() async {
        let paginator = Paginator.testing(threePages())
        _ = await paginator.current()

        #expect(paginator.broadcaster.subscriberCount == 0)
    }

    @Test func onePagePublishesOneLoadedSnapshot() async {
        let paginator = Paginator.testing(threePages())
        let stream = paginator.snapshots()
        await paginator.start()
        _ = await paginator.settled()

        await paginator.loadNextPage()
        await paginator.loadNextPage()
        let seen = await collect(stream) { $0.state == .loaded(hasMore: false) }

        #expect(seen.map(\.state) == [
            .idle, .loadingFirstPage, .loaded(hasMore: true),
            .loadingNextPage, .loaded(hasMore: true),
            .loadingNextPage, .loaded(hasMore: false),
        ])
    }

    // MARK: Cancellation

    @Test(arguments: [CancellationError() as any Error, URLError(.cancelled)])
    func cancellationDuringLoadIsSilent(thrown: any Error) async {
        let paginator = Paginator.testing(MockSource { token in
            if token.page == 2 { throw thrown }
            return page(1, 2, next: token.next)
        })
        await paginator.start()
        _ = await paginator.settled()
        let stream = paginator.snapshots()

        await paginator.loadNextPage()
        var seen: [PaginationSnapshot<TestItem>] = []
        for await snapshot in stream.prefix(3) { seen.append(snapshot) }

        #expect(seen.map(\.state) == [.loaded(hasMore: true), .loadingNextPage, .loaded(hasMore: true)])
        #expect(seen.allSatisfy { $0.lastError == nil })
        #expect(ids(seen[2]) == [1, 2])
        #expect(await paginator.lastFailedOperation == nil)
    }

    @Test func cancelledFirstLoadReturnsToIdleAndIgnoresTheLateResult() async {
        let entered = Gate()
        let release = Gate()
        let paginator = Paginator.testing(MockSource { _ in
            await entered.open()
            await release.wait()
            return page(1)
        })

        let load = Task { await paginator.refresh() }
        await entered.wait()
        #expect(await paginator.current().state == .loadingFirstPage)

        await paginator.cancel()
        #expect(await paginator.current().state == .idle)

        await release.open()
        await load.value
        let snapshot = await paginator.current()
        #expect(snapshot.state == .idle)
        #expect(snapshot.items.isEmpty)
    }

    @Test func cancelBeforeTheStartTaskRunsLoadsNothing() async {
        let calls = CallLog()
        let paginator = Paginator.testing(threePages(calls: calls))

        await paginator.startTwiceThenCancel()
        await paginator.loadNextPage()

        #expect(await paginator.current().state == .idle)
        #expect(await calls.count == 0)
    }

    @Test func cancelWhileIdlePublishesNothing() async {
        let paginator = Paginator.testing(threePages())
        let stream = paginator.snapshots()

        await paginator.cancel()
        await paginator.start()
        let seen = await collect(stream) { $0.state == .loadingFirstPage }

        #expect(seen.map(\.state) == [.idle, .loadingFirstPage])
    }

    @Test func cancelledNextPageRestoresTheStateBeforeTheLoad() async {
        let entered = Gate()
        let release = Gate()
        let paginator = Paginator.testing(MockSource { token in
            guard token.page == 2 else { return page(1, next: token.next) }
            await entered.open()
            await release.wait()
            return page(2)
        })
        await paginator.start()
        _ = await paginator.settled()

        let load = Task { await paginator.loadNextPage() }
        await entered.wait()
        await paginator.cancel()
        await release.open()
        await load.value

        let snapshot = await paginator.current()
        #expect(snapshot.state == .loaded(hasMore: true))
        #expect(ids(snapshot) == [1])
    }

    @Test func cancelledRetryRestoresTheFailureAndCancelsTheRequest() async {
        let calls = CallLog()
        let cancelledRequests = CallLog()
        let entered = Gate()
        let release = Gate()
        let paginator = Paginator.testing(MockSource { token in
            switch await calls.record() {
            case 1: return page(1, next: token.next)
            case 2: throw PageKitHTTPError(status: 404)
            default:
                await entered.open()
                await release.wait()
                if Task.isCancelled { await cancelledRequests.record() }
                return page(2)
            }
        })
        await paginator.start()
        _ = await paginator.settled()
        await paginator.loadNextPage()

        let retry = Task { await paginator.retry() }
        await entered.wait()
        await paginator.cancel()
        await release.open()
        await retry.value

        #expect(await paginator.current().state == .failed(.client(status: 404), isFirstPage: false))
        #expect(await cancelledRequests.count == 1)
        #expect(await paginator.inFlight.isEmpty)
    }

    @Test func cancelledCallerRestoresTheStateAndDropsThePage() async {
        let cancelledRequests = CallLog()
        let entered = Gate()
        let release = Gate()
        let paginator = Paginator.testing(MockSource { token in
            guard token.page == 2 else { return page(1, next: token.next) }
            await entered.open()
            await release.wait()
            if Task.isCancelled { await cancelledRequests.record() }
            return page(2)
        })
        await paginator.start()
        _ = await paginator.settled()

        let load = Task { await paginator.loadNextPage() }
        await entered.wait()
        load.cancel()

        // The source is still held at the gate, so this restore did not wait for it.
        let restored = await paginator.first { $0.state == .loaded(hasMore: true) }
        #expect(restored.items.map(\.id) == [1])

        await release.open()
        await load.value
        #expect(await cancelledRequests.count == 1)
        #expect(ids(await paginator.current()) == [1])
        #expect(await paginator.inFlight.isEmpty)
    }

    @Test func cancelledCallerStopsRetryBackoff() async {
        let calls = CallLog()
        let backingOff = Gate()
        let wake = Gate()
        let environment = PaginatorEnvironment.testing(sleep: { _ in
            await backingOff.open()
            await withTaskCancellationHandler {
                await wake.wait()
            } onCancel: {
                Task { await wake.open() }
            }
            try Task.checkCancellation()
        })
        let source = MockSource { _ in
            await calls.record()
            throw PageKitHTTPError(status: 429, retryAfter: 3600)
        }
        let paginator = Paginator(source: source, configuration: .testing, environment: environment)

        let load = Task { await paginator.refresh() }
        await backingOff.wait()
        load.cancel()
        await load.value

        let snapshot = await paginator.current()
        #expect(snapshot.state == .idle)
        #expect(snapshot.lastError == nil)
        #expect(await calls.count == 1)
    }

    @Test func callerCancelledBeforeTheLoadDoesNothing() async {
        let calls = CallLog()
        let paginator = Paginator.testing(threePages(calls: calls))
        await paginator.start()
        _ = await paginator.settled()
        let stream = paginator.snapshots()

        for operation in [paginator.loadNextPage, paginator.refresh] {
            await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await operation()
            }.value
        }
        await paginator.loadNextPage()
        let seen = await collect(stream) { $0.state == .loadingNextPage }

        #expect(seen.map(\.state) == [.loaded(hasMore: true), .loadingNextPage])
        #expect(await calls.count == 2)
    }

    @Test func abandonedLoadDoesNotDisturbTheLoadAfterIt() async {
        let calls = CallLog()
        let abandonedEntered = Gate(), nextEntered = Gate()
        let abandonedRelease = Gate(), nextRelease = Gate()
        let paginator = Paginator.testing(MockSource { token in
            switch await calls.record() {
            case 1: return page(1, next: token.next)
            case 2:
                await abandonedEntered.open()
                await abandonedRelease.wait()   // Ignores cancellation.
            default:
                await nextEntered.open()
                await nextRelease.wait()
            }
            return page(2)
        })
        await paginator.start()
        _ = await paginator.settled()

        let abandoned = Task { await paginator.loadNextPage() }
        await abandonedEntered.wait()
        abandoned.cancel()
        _ = await paginator.first { $0.state == .loaded(hasMore: true) }

        let next = Task { await paginator.loadNextPage() }
        await nextEntered.wait()
        await abandonedRelease.open()
        await abandoned.value
        #expect(await paginator.current().state == .loadingNextPage)

        await nextRelease.open()
        await next.value
        #expect(ids(await paginator.current()) == [1, 2])
    }

    @Test func lateCancellationDoesNotEndANewerLoad() async {
        let entered = Gate()
        let release = Gate()
        let source = MockSource { token in
            guard token.page == 2 else { return page(1, next: token.next) }
            await entered.open()
            await release.wait()
            return page(2)
        }
        let paginator = Paginator.testing(source)
        await paginator.start()
        _ = await paginator.settled()
        let finishedLoad = await paginator.latestLoad
        let generation = await paginator.generation

        let load = Task { await paginator.loadNextPage() }
        await entered.wait()
        await paginator.abandonLoad(finishedLoad, generation: generation, token: source.firstToken)
        #expect(await paginator.current().state == .loadingNextPage)

        await release.open()
        await load.value
        #expect(ids(await paginator.current()) == [1, 2])
    }

    @Test func lateCancellationAfterTheLoadFinishedChangesNothing() async {
        let source = threePages()
        let paginator = Paginator.testing(source)
        await paginator.start()
        _ = await paginator.settled()
        let generation = await paginator.generation

        await paginator.abandonLoad(await paginator.latestLoad, generation: generation, token: source.firstToken)

        #expect(await paginator.generation == generation)
    }

    @Test(arguments: [CancellationError() as any Error, URLError(.cancelled)])
    func startWorksAgainAfterFirstLoadIsCancelled(thrown: any Error) async {
        let calls = CallLog()
        let paginator = Paginator.testing(MockSource { token in
            if await calls.record() == 1 { throw thrown }
            return page(1, next: token.next)
        })
        let stream = paginator.snapshots()

        await paginator.start()
        _ = await collect(stream) { $0.state == .loadingFirstPage }
        _ = await collect(stream) { $0.state == .idle }
        await paginator.start()

        #expect(ids(await paginator.settled()) == [1])
    }

    @Test func startWorksAgainAfterACancelledRefreshSupersededIt() async {
        let calls = CallLog()
        let startEntered = Gate(), refreshEntered = Gate()
        let release = Gate()
        let paginator = Paginator.testing(MockSource { token in
            switch await calls.record() {
            case 1:
                await startEntered.open()
                await release.wait()    // Ignores cancellation, and outlasts the restart.
            case 2:
                await refreshEntered.open()
                await release.wait()
            default:
                break
            }
            return page(1, next: token.next)
        })

        await paginator.start()
        await startEntered.wait()
        let refresh = Task { await paginator.refresh() }
        await refreshEntered.wait()
        refresh.cancel()
        _ = await paginator.first { $0.state == .idle }

        await paginator.start()
        #expect(ids(await paginator.settled()) == [1])

        await release.open()
        await refresh.value
    }

    // MARK: Set-up

    @Test func publicInitialiserStartsIdle() async {
        let paginator = Paginator(source: threePages(), connectivity: FakeConnectivity())

        #expect(await paginator.current().state == .idle)
    }

    @Test func creatingAPaginatorRaisesTheMemoryLimit() {
        let memory = MemoryPageCache(costLimit: 10)
        var configuration = PaginationConfiguration.testing
        configuration.memoryCostLimit = 500

        _ = Paginator(source: threePages(), configuration: configuration, environment: .testing(memory: memory))

        #expect(memory.costLimit == 500)
    }

    @Test func liveEnvironmentUsesTheConfiguredStorage() async {
        var configuration = PaginationConfiguration.testing
        configuration.storage = .durable

        let environment = PaginatorEnvironment.live(configuration: configuration, connectivity: FakeConnectivity())

        #expect(environment.disk === DiskPageStore.shared(for: .durable))
        #expect(environment.memory === MemoryPageCache.shared)
    }

    @Test func serverSuppliedDelaysCannotOverflowTheLiveSleep() {
        #expect(PaginatorEnvironment.nanoseconds(for: 1.5) == 1_500_000_000)
        #expect(PaginatorEnvironment.nanoseconds(for: -5) == 0)
        #expect(PaginatorEnvironment.nanoseconds(for: 1e30) == 86_400_000_000_000)
        #expect(PaginatorEnvironment.nanoseconds(for: .nan) == 0)
    }
}
