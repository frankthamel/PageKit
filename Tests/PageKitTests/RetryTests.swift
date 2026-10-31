import Foundation
import Testing
@testable import PageKit

struct RetryTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        private var calls = 0
        func call() { lock.withLock { calls += 1 } }
        func record(_ v: Double) { lock.withLock { values.append(v) } }
        var callCount: Int { lock.withLock { calls } }
        var recorded: [Double] { lock.withLock { values } }
    }

    private func retrier(_ counter: Counter = Counter(), sleep: Sleep? = nil) -> Retrier {
        Retrier(policy: .default, sleep: sleep ?? { counter.record($0) })
    }

    @Test func classifiesURLErrors() {
        #expect(ErrorClassifier.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(ErrorClassifier.classify(URLError(.networkConnectionLost)) == .offline)
        #expect(ErrorClassifier.classify(URLError(.timedOut)) == .timedOut)
    }

    @Test func cancellationIsNotAnError() {
        #expect(ErrorClassifier.classify(CancellationError()) == nil)
        #expect(ErrorClassifier.classify(URLError(.cancelled)) == nil)
    }

    @Test func decodingErrorsClassifyAsDecoding() {
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        guard case .decoding = ErrorClassifier.classify(error) else {
            Issue.record("expected .decoding")
            return
        }
    }

    @Test func httpStatusesClassify() {
        #expect(ErrorClassifier.classify(PageKitHTTPError(status: 429, retryAfter: 3)) == .rateLimited(retryAfter: 3))
        #expect(ErrorClassifier.classify(PageKitHTTPError(status: 503)) == .server(status: 503))
        #expect(ErrorClassifier.classify(PageKitHTTPError(status: 404)) == .client(status: 404))
    }

    @Test func retryabilityMatchesTable() {
        #expect(PaginationError.timedOut.isRetryable)
        #expect(PaginationError.rateLimited(retryAfter: nil).isRetryable)
        #expect(PaginationError.server(status: 500).isRetryable)
        #expect(!PaginationError.offline.isRetryable)
        #expect(!PaginationError.client(status: 400).isRetryable)
        #expect(!PaginationError.decoding(underlying: "").isRetryable)
        #expect(!PaginationError.other(underlying: "").isRetryable)
    }

    @Test func delayDoublesAndCaps() {
        let policy = RetryPolicy.default
        for (attempt, expected) in [(0, 0.5), (1, 1.0), (2, 2.0), (10, 8.0)] {
            #expect(policy.delay(forAttempt: attempt, random: 1.0) == expected)
        }
    }

    @Test func jitterStaysInRange() {
        let policy = RetryPolicy.default
        #expect(policy.delay(forAttempt: 1, random: 0.5) == 0.5)
        for _ in 0..<100 {
            #expect((0.5...1.0).contains(policy.delay(forAttempt: 1)))
        }
    }

    @Test func serverErrorRetriesThreeTimesThenFails() async {
        let counter = Counter()
        await #expect(throws: PaginationError.server(status: 503)) {
            try await retrier(counter).run { () async throws -> Int in
                counter.call()
                throw PageKitHTTPError(status: 503)
            }
        }
        #expect(counter.callCount == 3)
        #expect(counter.recorded.count == 2)
    }

    @Test func clientErrorIsNotRetried() async {
        let counter = Counter()
        await #expect(throws: PaginationError.client(status: 404)) {
            try await retrier(counter).run { () async throws -> Int in
                counter.call()
                throw PageKitHTTPError(status: 404)
            }
        }
        #expect(counter.callCount == 1)
    }

    @Test func rateLimitedWaitsForRetryAfter() async throws {
        let counter = Counter()
        let value = try await retrier(counter).run { () async throws -> Int in
            counter.call()
            if counter.callCount == 1 { throw PageKitHTTPError(status: 429, retryAfter: 7) }
            return 42
        }
        #expect(value == 42)
        #expect(counter.recorded == [7])
    }

    @Test func cancelledSleepStopsRetrying() async {
        let counter = Counter()
        let retrier = Retrier(policy: .default, sleep: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            try await retrier.run { () async throws -> Int in
                counter.call()
                throw PageKitHTTPError(status: 503)
            }
        }
        #expect(counter.callCount == 1)
    }
}
