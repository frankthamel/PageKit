/// One chunk of a list, plus the token that leads to the next chunk.
///
/// The same shape serves index-based and cursor-based APIs, which is what lets
/// one engine drive both.
public struct Page<Item, Token> {
    /// The items in this chunk, in display order.
    public let items: [Item]

    /// The token for the following chunk, or `nil` when this was the last one.
    public let nextToken: Token?

    /// Creates a page.
    /// - Parameters:
    ///   - items: The items in this chunk.
    ///   - nextToken: The token for the following chunk, or `nil` at the end of the list.
    public init(items: [Item], nextToken: Token?) {
        self.items = items
        self.nextToken = nextToken
    }
}

extension Page: Sendable where Item: Sendable, Token: Sendable {}
extension Page: Codable where Item: Codable, Token: Codable {}
extension Page: Equatable where Item: Equatable, Token: Equatable {}
