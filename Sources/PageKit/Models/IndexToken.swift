/// A token for index-based (page number) APIs. The client works out the next page.
public struct IndexToken: PageToken {
    /// The page number, starting at 1.
    public let page: Int

    /// How many items each page holds.
    public let size: Int

    /// Creates a token.
    /// - Parameters:
    ///   - page: The page number, starting at 1.
    ///   - size: How many items each page holds.
    public init(page: Int, size: Int) {
        self.page = page
        self.size = size
    }

    /// The number of items before this page, for APIs that take a "skip" value.
    public var offset: Int { (page - 1) * size }

    /// The token for the page after this one.
    public var next: IndexToken { IndexToken(page: page + 1, size: size) }

    /// The next page is always `next`, so pages can be read ahead in parallel.
    public var predictedNext: IndexToken? { next }

    /// The token for the first page.
    /// - Parameter size: How many items each page holds.
    public static func first(size: Int = 20) -> IndexToken {
        IndexToken(page: 1, size: size)
    }
}
