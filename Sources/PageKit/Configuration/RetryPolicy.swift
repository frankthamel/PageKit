import Foundation

/// How many times, and how patiently, a failed load is retried.
///
/// Each retry waits roughly twice as long as the last, up to `maxDelay`. A random
/// factor keeps many devices from retrying at the same instant.
public struct RetryPolicy: Sendable {
    /// How many times a load is tried in total.
    public var maxAttempts: Int

    /// The wait before the first retry, in seconds.
    public var baseDelay: TimeInterval

    /// The longest wait between tries, in seconds.
    public var maxDelay: TimeInterval

    /// Three attempts, waiting 0.5 s, 1 s, 2 s and so on, capped at 8 s.
    public static let `default` = RetryPolicy()

    /// Creates a policy.
    /// - Parameters:
    ///   - maxAttempts: How many times a load is tried in total.
    ///   - baseDelay: The wait before the first retry, in seconds.
    ///   - maxDelay: The longest wait between tries, in seconds.
    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// The wait before retry number `attempt`, counting from 0, with 50% to 100% jitter.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponential = min(maxDelay, baseDelay * pow(2, Double(attempt)))
        return exponential * Double.random(in: 0.5...1.0)
    }
}
