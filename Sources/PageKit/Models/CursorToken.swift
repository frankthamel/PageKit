/// A token for cursor-based APIs. The server hands back the next cursor.
public struct CursorToken: PageToken {
    /// The opaque cursor from the server, or `nil` for the first page.
    public let value: String?

    /// How many items each page holds.
    public let size: Int

    /// Creates a token.
    /// - Parameters:
    ///   - value: The opaque cursor from the server, or `nil` for the first page.
    ///   - size: How many items each page holds.
    public init(value: String?, size: Int) {
        self.value = value
        self.size = size
    }
}
