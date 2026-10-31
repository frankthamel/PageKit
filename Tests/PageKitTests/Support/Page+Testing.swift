@testable import PageKit

/// A page of `TestItem`s with the given IDs.
func page<Token>(_ ids: Int..., next: Token? = nil) -> Page<TestItem, Token> {
    Page(items: ids.map { TestItem(id: $0) }, nextToken: next)
}
