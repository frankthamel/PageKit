import Foundation

/// Waits for the given number of seconds. Injected so tests need not really wait.
typealias Sleep = @Sendable (TimeInterval) async throws -> Void

/// Runs work, retrying retryable failures with backoff.
struct Retrier: Sendable {
    private let policy: RetryPolicy
    private let sleep: Sleep

    init(policy: RetryPolicy, sleep: @escaping Sleep) {
        self.policy = policy
        self.sleep = sleep
    }

    /// Runs `work`, retrying while the failure is retryable and attempts remain.
    ///
    /// Throws the classified `PaginationError` once it gives up, or `CancellationError`
    /// if the work or a wait was cancelled. A rate-limited failure waits as long as the
    /// server asked; other failures use the policy's backoff.
    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let attempts = max(1, policy.maxAttempts)
        var attempt = 0
        while true {
            do {
                return try await work()
            } catch {
                guard let failure = ErrorClassifier.classify(error) else { throw CancellationError() }
                attempt += 1
                guard failure.isRetryable, attempt < attempts else { throw failure }
                PageKitLog.logger.debug("Attempt \(attempt) failed, retrying: \(String(describing: failure), privacy: .private)")
                try await sleep(wait(after: failure, attempt: attempt - 1))
            }
        }
    }

    private func wait(after failure: PaginationError, attempt: Int) -> TimeInterval {
        if case .rateLimited(let retryAfter?) = failure { return retryAfter }
        return policy.delay(forAttempt: attempt)
    }
}
