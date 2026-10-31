import Foundation

/// A ready-made ``PageSource`` for simple JSON APIs, so an app can paginate without writing a type.
///
/// You say how to build a request from a token, and how to turn the decoded response into a
/// ``Page``. Each load then does four things: builds the request (ignoring `URLCache`, because
/// PageKit does its own caching, with a 15-second timeout), sends it, checks the status code, and
/// decodes the body.
///
/// - A 2xx status is decoded and mapped.
/// - A 429 or 5xx status throws a retryable error. For 429, the number of seconds in a
///   `Retry-After` header is carried along. A negative or non-numeric value is ignored, and so is
///   the HTTP-date form of the header.
/// - Any other status throws a permanent error.
/// - A response that is not HTTP, or a body that does not decode, throws an error PageKit reports
///   as `other` or `decoding`.
public struct URLSessionPageSource<
    Response: Decodable & Sendable,
    Item: Identifiable & Codable & Sendable,
    Token: PageToken
>: PageSource where Item.ID: Codable & Sendable {
    /// How long one request may take before it fails with a timeout, in seconds.
    static var requestTimeout: TimeInterval { 15 }

    /// A stable, unique name for this list. It is the cache key.
    public let feedID: String

    /// The token for the very first page.
    public let firstToken: Token

    private let session: URLSession
    private let makeDecoder: @Sendable () -> JSONDecoder
    private let makeRequest: @Sendable (Token) -> URLRequest
    private let map: @Sendable (Response, Token) -> Page<Item, Token>

    /// Creates a source.
    /// - Parameters:
    ///   - feedID: A stable, unique name for the list.
    ///   - firstToken: The token for the first page.
    ///   - session: The session that sends requests. Defaults to `URLSession.shared`.
    ///   - decoder: The decoder for response bodies. It is copied for each load, so changing
    ///     it afterwards has no effect on the source.
    ///   - request: Builds the request for a token. PageKit sets its cache policy and timeout.
    ///   - map: Turns a decoded response, and the token it was fetched with, into a page.
    public init(
        feedID: String,
        firstToken: Token,
        session: URLSession = .shared,
        decoder: JSONDecoder = .init(),
        request: @escaping @Sendable (Token) -> URLRequest,
        map: @escaping @Sendable (Response, Token) -> Page<Item, Token>
    ) {
        self.feedID = feedID
        self.firstToken = firstToken
        self.session = session
        self.makeDecoder = Self.decoderFactory(copying: decoder)
        self.makeRequest = request
        self.map = map
    }

    /// Fetches and decodes one page.
    /// - Parameter token: The page to fetch.
    public func loadPage(_ token: Token) async throws -> Page<Item, Token> {
        var request = makeRequest(token)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.requestTimeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PaginationError.other(underlying: "The response was not an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw PageKitHTTPError(status: http.statusCode, retryAfter: Self.retryAfter(in: http))
        }
        return map(try makeDecoder().decode(Response.self, from: data), token)
    }

    /// The seconds from a numeric `Retry-After` header, or `nil` if it is missing, negative or not a number.
    private static func retryAfter(in response: HTTPURLResponse) -> TimeInterval? {
        guard let text = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds >= 0
        else { return nil }
        return seconds
    }

    /// A factory of decoders configured like `decoder`.
    ///
    /// The source keeps the settings and builds a fresh decoder per load, so the caller's decoder can change afterwards without effect.
    private static func decoderFactory(copying decoder: JSONDecoder) -> @Sendable () -> JSONDecoder {
        let dates = decoder.dateDecodingStrategy
        let data = decoder.dataDecodingStrategy
        let floats = decoder.nonConformingFloatDecodingStrategy
        let keys = decoder.keyDecodingStrategy
        let userInfo = decoder.userInfo
        return {
            let copy = JSONDecoder()
            copy.dateDecodingStrategy = dates
            copy.dataDecodingStrategy = data
            copy.nonConformingFloatDecodingStrategy = floats
            copy.keyDecodingStrategy = keys
            copy.userInfo = userInfo
            return copy
        }
    }
}
