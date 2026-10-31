import Foundation

/// Why a page failed to load.
///
/// Every failure is sorted into one of these cases so the engine can decide
/// whether to retry, and so the UI can decide what to show.
public enum PaginationError: Error, Equatable, Sendable {
    /// There is no network connection.
    case offline

    /// The request took too long.
    case timedOut

    /// The server asked the client to slow down (HTTP 429).
    /// - Parameter retryAfter: How long the server asked us to wait, if it said.
    case rateLimited(retryAfter: TimeInterval?)

    /// The server failed (HTTP 5xx).
    case server(status: Int)

    /// The request was rejected (HTTP 4xx other than 429).
    case client(status: Int)

    /// The response did not match the item model.
    case decoding(underlying: String)

    /// Any other failure.
    case other(underlying: String)
}
