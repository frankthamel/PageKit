/// Identifies one page of a list.
///
/// The engine never looks inside a token. It stores it, uses it as a cache key,
/// writes it to disk and hands it back to the ``PageSource``. Define your own,
/// for example a cursor plus a search query, by conforming to this protocol.
public protocol PageToken: Hashable, Codable, Sendable {
    /// The token for the page after this one, if it can be worked out without
    /// asking the server.
    ///
    /// Index-based tokens can, so the engine may read several pages ahead in
    /// parallel. Cursor-based tokens cannot, because the next cursor only
    /// arrives with the current page. The default is `nil`.
    var predictedNext: Self? { get }
}

extension PageToken {
    /// By default a token cannot predict its successor.
    public var predictedNext: Self? { nil }
}
