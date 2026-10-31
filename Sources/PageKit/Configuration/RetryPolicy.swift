import Foundation

/// How many times, and how patiently, a failed load is retried.
///
/// Each retry waits roughly twice as long as the last, up to `maxDelay`. A random
/// factor keeps many devices from retrying at the same instant.
public struct RetryPolicy: Sendable {
    /// How many times a load is tried in total. Values below 1 behave as 1.
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

    /// The wait before retry number `attempt`, counting from 0.
    /// - Parameters:
    ///   - attempt: The retry number, counting from 0.
    ///   - random: The jitter factor, from 0.5 to 1.0. Tests pass a fixed value.
    func delay(forAttempt attempt: Int, random: Double = Double.random(in: 0.5...1.0)) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2, Double(attempt))) * random
    }
}
