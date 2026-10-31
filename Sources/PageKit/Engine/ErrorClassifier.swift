import Foundation

/// An HTTP response with a failing status code.
///
/// Page sources throw this so PageKit can sort the failure and decide whether to retry.
public struct PageKitHTTPError: Error, Equatable, Sendable {
    /// The HTTP status code.
    public let status: Int

    /// How long the server asked us to wait, from the `Retry-After` header, if it sent one.
    public let retryAfter: TimeInterval?

    /// Creates an HTTP error.
    /// - Parameters:
    ///   - status: The HTTP status code.
    ///   - retryAfter: How long the server asked us to wait, if it said.
    public init(status: Int, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.retryAfter = retryAfter
    }
}

/// Sorts any thrown error into a `PaginationError`.
enum ErrorClassifier {
    /// The `PaginationError` for `error`, or `nil` if the work was cancelled.
    static func classify(_ error: Error) -> PaginationError? {
        switch error {
        case is CancellationError:
            return nil
        case let error as PaginationError:
            return error
        case let error as PageKitHTTPError:
            return classify(status: error.status, retryAfter: error.retryAfter)
        case let error as URLError:
            return classify(error)
        case is DecodingError:
            return .decoding(underlying: String(describing: error))
        default:
            return .other(underlying: String(describing: error))
        }
    }

    private static func classify(_ error: URLError) -> PaginationError? {
        switch error.code {
        case .cancelled: return nil
        case .notConnectedToInternet, .networkConnectionLost: return .offline
        case .timedOut: return .timedOut
        default: return .other(underlying: String(describing: error))
        }
    }

    private static func classify(status: Int, retryAfter: TimeInterval?) -> PaginationError {
        switch status {
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 500...599: return .server(status: status)
        case 400...499: return .client(status: status)
        default: return .other(underlying: "HTTP \(status)")
        }
    }
}

extension PaginationError {
    /// Whether trying again might succeed: timeouts, rate limits and server failures.
    var isRetryable: Bool {
        switch self {
        case .timedOut, .rateLimited, .server: return true
        case .offline, .client, .decoding, .other: return false
        }
    }
}
