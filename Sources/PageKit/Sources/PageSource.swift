/// Knows how to fetch one page of a list. The only protocol most apps implement.
///
/// PageKit handles retries, caching, prefetching and de-duplication around it.
public protocol PageSource<Item, Token>: Sendable {
    /// What the list contains. It needs an identity to remove duplicates, and
    /// `Codable` so pages can be saved for offline use.
    associatedtype Item: Identifiable & Codable & Sendable where Item.ID: Codable & Sendable

    /// How pages are identified: ``IndexToken``, ``CursorToken`` or your own.
    associatedtype Token: PageToken

    /// A stable, unique name for this list, such as `"products.home"` or `"search.shoes"`.
    ///
    /// It is the cache key, so two lists must never share one.
    var feedID: String { get }

    /// The token for the very first page.
    var firstToken: Token { get }

    /// Fetches one page. Throw on failure; PageKit handles retries and caching.
    /// - Parameter token: The page to fetch.
    func loadPage(_ token: Token) async throws -> Page<Item, Token>
}
