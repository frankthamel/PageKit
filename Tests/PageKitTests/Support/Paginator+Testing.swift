@testable import PageKit

extension Paginator {
    /// A paginator on the testing configuration and environment.
    static func testing(_ source: Source) -> Paginator {
        Paginator(source: source, configuration: .testing, environment: .testing())
    }

    /// A paginator on `policy`, sharing `environment`'s caches with any other made from it.
    static func testing(_ source: Source, policy: CachePolicy, environment: PaginatorEnvironment) -> Paginator {
        Paginator(source: source, configuration: .testing(policy), environment: environment)
    }

    /// The first snapshot that shows items the network has confirmed.
    nonisolated func revalidated() async -> PaginationSnapshot<Source.Item> {
        await first { !$0.items.isEmpty && !$0.isStale && !$0.state.isLoading }
    }

    /// The current snapshot.
    nonisolated func current() async -> PaginationSnapshot<Source.Item> {
        await first { _ in true }
    }

    /// The first snapshot, starting from the current one, that satisfies `condition`.
    nonisolated func first(
        where condition: (PaginationSnapshot<Source.Item>) -> Bool
    ) async -> PaginationSnapshot<Source.Item> {
        for await snapshot in snapshots() where condition(snapshot) { return snapshot }
        return .initial
    }

    /// The first snapshot after loading has begun and finished.
    nonisolated func settled() async -> PaginationSnapshot<Source.Item> {
        await first { $0.state != .idle && !$0.state.isLoading }
    }

    /// Calls `start()` twice then `cancel()` with no gap, so no task `start()` made has
    /// run yet, and returns once the surviving task is over.
    func startTwiceThenCancel() async {
        start()
        start()
        let task = startTask
        cancel()
        await task?.value
    }

    /// Calls `fetch` from inside the actor, and opens `gate` once that call has suspended.
    ///
    /// The inner task shares this actor, so it cannot run until `fetch` gives the actor
    /// up. That makes "the second request has joined" certain without any sleeping.
    func fetch(_ token: Source.Token, openingOnSuspend gate: Gate) async throws -> Page<Source.Item, Source.Token> {
        Task { [self] in
            _ = self
            await gate.open()
        }
        return try await fetch(token).page
    }

    /// Calls `retry` from inside the actor, and opens `gate` once that call has suspended.
    func retry(openingOnSuspend gate: Gate) async {
        Task { [self] in
            _ = self
            await gate.open()
        }
        await retry()
    }

    /// Reports `id` appearing `times` times, all in one turn of the actor.
    func itemAppeared(id: Source.Item.ID, times: Int) {
        for _ in 0..<times { itemAppeared(id: id) }
    }

    /// Reports `id` appearing and cancels before the load that queues can run.
    func itemAppearedThenCancel(id: Source.Item.ID) async {
        itemAppeared(id: id)
        let task = prefetchTask
        cancel()
        await task?.value
    }

    /// Waits until no read-ahead is running, including any that one leaves to follow it.
    func waitForReadAhead() async {
        while let task = readAheadTask { await task.value }
    }
}
