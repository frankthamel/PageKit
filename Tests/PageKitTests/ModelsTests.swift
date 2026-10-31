import Foundation
import Testing
@testable import PageKit

/// A token an app might define itself: a cursor plus a search query.
private struct SearchToken: PageToken {
    let cursor: String?
    let query: String
}

@Suite(.watchdog) struct ModelsTests {
    @Test func snapshotsAndPagesCompareByValue() {
        let snapshot = PaginationSnapshot(
            items: [TestItem(id: 1)], state: .loaded(hasMore: true), isStale: false, isOffline: false, lastError: nil
        )
        #expect(snapshot == snapshot)
        #expect(snapshot != .initial)
        #expect(Page(items: [1], nextToken: 2) == Page(items: [1], nextToken: 2))
        #expect(Page(items: [1], nextToken: 2) != Page(items: [1], nextToken: nil))
    }

    @Test func indexTokenOffsetIsZeroBased() {
        #expect(IndexToken(page: 3, size: 20).offset == 40)
        #expect(IndexToken.first(size: 20).offset == 0)
    }

    @Test func indexTokenPredictsNext() {
        let token = IndexToken(page: 1, size: 20)
        #expect(token.next == IndexToken(page: 2, size: 20))
        #expect(token.predictedNext == token.next)
    }

    @Test func cursorTokenPredictsNothing() {
        #expect(CursorToken(value: "abc", size: 25).predictedNext == nil)
    }

    @Test func customTokenDefaultsToNoPrediction() {
        #expect(SearchToken(cursor: nil, query: "shoes").predictedNext == nil)
    }

    @Test func tokensRoundTripThroughJSON() throws {
        let index = IndexToken(page: 3, size: 20)
        let cursor = CursorToken(value: "eyJpZCI6MTIzfQ", size: 25)
        let firstCursor = CursorToken(value: nil, size: 25)
        #expect(try roundTrip(index) == index)
        #expect(try roundTrip(cursor) == cursor)
        #expect(try roundTrip(firstCursor) == firstCursor)
    }

    @Test func pageKeyIsStableForTheSameToken() {
        let token = CursorToken(value: "a/b c", size: 25)
        #expect(PageKey(feedID: "feed", token: token) == PageKey(feedID: "feed", token: token))
        #expect(PageKey(feedID: "feed", token: token).token == PageKey(feedID: "feed", token: token).token)
        #expect(PageKey(feedID: "feed", token: token) != PageKey(feedID: "other", token: token))
        #expect(PageKey(feedID: "feed", token: token)
            != PageKey(feedID: "feed", token: CursorToken(value: "x", size: 25)))
    }

    @Test func initialSnapshotIsIdleAndEmpty() {
        let snapshot = PaginationSnapshot<TestItem>.initial
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.state == .idle)
        #expect(!snapshot.isStale)
        #expect(!snapshot.isOffline)
        #expect(snapshot.lastError == nil)
    }

    @Test func onlyLoadedWithMoreCanLoadMore() {
        let states: [(PaginationState, Bool)] = [
            (.idle, false),
            (.loadingFirstPage, false),
            (.loaded(hasMore: true), true),
            (.loaded(hasMore: false), false),
            (.loadingNextPage, false),
            (.refreshing, false),
            (.empty, false),
            (.failed(.offline, isFirstPage: true), false),
            (.failed(.offline, isFirstPage: false), false),
        ]
        for (state, expected) in states {
            #expect(state.canLoadMore == expected, "\(state)")
        }
    }

    @Test func pageCarriesNilNextTokenAtEnd() {
        let page = Page<TestItem, IndexToken>(items: [TestItem(id: 1)], nextToken: nil)
        #expect(page.items == [TestItem(id: 1)])
        #expect(page.nextToken == nil)
    }

    @Test func retryDelayGrowsAndStaysWithinJitterBounds() {
        let policy = RetryPolicy.default
        for (attempt, base) in [(0, 0.5), (1, 1.0), (2, 2.0), (10, 8.0)] {
            let delay = policy.delay(forAttempt: attempt)
            #expect((base * 0.5)...base ~= delay, "attempt \(attempt): \(delay)")
        }
    }

    private func roundTrip<T: PageToken>(_ token: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(token))
    }
}
