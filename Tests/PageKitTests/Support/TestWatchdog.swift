import Foundation
import Testing

#if compiler(>=6.1)
/// Ends the whole test run if one test takes too long, so a hang fails instead of stalling.
///
/// Swift Testing's `.timeLimit` is not enough. It only cancels the test, and then waits for
/// it, so a test stuck on something that ignores cancellation, such as ``Gate/wait()``, stays
/// stuck. This timer runs on Dispatch, outside the test and the thread pool it may be stuck
/// on, and needs no `Duration`, so it also works at the macOS 12 floor.
struct TestWatchdog: TestTrait, SuiteTrait, TestScoping {
    /// Far above the slowest test, even on a machine under heavy load.
    static let defaultLimit: TimeInterval = 60

    var limit = defaultLimit
    var onExpiry: @Sendable (Test) -> Void = TestWatchdog.endRun

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        // A suite's own scope lasts for all of its tests, so only a test case is timed.
        guard testCase != nil else { return try await function() }
        let expiry = DispatchWorkItem { [onExpiry] in onExpiry(test) }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: expiry)
        defer { expiry.cancel() }
        try await function()
    }

    /// Names the test and exits, because nothing can make a stuck test return.
    private static let endRun: @Sendable (Test) -> Void = { test in
        let message = "Test \(test.name) at \(test.sourceLocation) ran past \(defaultLimit) seconds. Ending the run.\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
    }
}
#else
/// Does nothing on Swift 6.0, which has no `TestScoping`. A hang there stalls until the CI
/// job's timeout ends it.
struct TestWatchdog: TestTrait, SuiteTrait {}
#endif

extension Trait where Self == TestWatchdog {
    /// Ends the run if a test in this suite hangs. Every suite carries it.
    static var watchdog: TestWatchdog { TestWatchdog() }
}
