@testable import PageKit

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
