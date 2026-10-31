@testable import PageKit

extension Paginator {
    /// A paginator on the testing configuration and environment.
    static func testing(_ source: Source) -> Paginator {
        Paginator(source: source, configuration: .testing, environment: .testing())
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
        return try await fetch(token)
    }
}

/// Counts calls into a source, safely across tasks.
actor CallLog {
    private(set) var count = 0

    /// Records a call and returns its number, starting at 1.
    @discardableResult
    func record() -> Int {
        count += 1
        return count
    }
}

/// Reads every snapshot from `stream` up to and including the one that satisfies `condition`.
func collect<Item>(
    _ stream: AsyncStream<PaginationSnapshot<Item>>,
    until condition: (PaginationSnapshot<Item>) -> Bool
) async -> [PaginationSnapshot<Item>] {
    var seen: [PaginationSnapshot<Item>] = []
    for await snapshot in stream {
        seen.append(snapshot)
        if condition(snapshot) { break }
    }
    return seen
}

/// A page of `TestItem`s with the given IDs.
func page<Token>(_ ids: Int..., next: Token? = nil) -> Page<TestItem, Token> {
    Page(items: ids.map { TestItem(id: $0) }, nextToken: next)
}
