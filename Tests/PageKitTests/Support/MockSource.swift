@testable import PageKit

/// An index-based source whose pages come from a closure the test supplies.
struct MockSource: PageSource {
    var feedID = "test"
    let firstToken = IndexToken.first(size: 2)
    let handler: @Sendable (IndexToken) async throws -> Page<TestItem, IndexToken>

    func loadPage(_ token: IndexToken) async throws -> Page<TestItem, IndexToken> {
        try await handler(token)
    }
}

/// A cursor-based source whose pages come from a closure the test supplies.
struct CursorMockSource: PageSource {
    let feedID = "test.cursor"
    let firstToken = CursorToken(value: nil, size: 2)
    let handler: @Sendable (CursorToken) async throws -> Page<TestItem, CursorToken>

    func loadPage(_ token: CursorToken) async throws -> Page<TestItem, CursorToken> {
        try await handler(token)
    }
}
