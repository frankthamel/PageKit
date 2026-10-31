#if compiler(>=6.1)
import Testing

@Suite(.watchdog) struct TestWatchdogTests {
    @Test func aTestPastTheLimitTriggersIt() async throws {
        let triggered = Gate()
        let watchdog = TestWatchdog(limit: 0) { _ in Task { await triggered.open() } }

        // This only returns if the watchdog fires.
        try await watchdog.provideScope(for: .current!, testCase: .current) { await triggered.wait() }
    }

    @Test func aTestWithinTheLimitDoesNot() async throws {
        let expired = CallLog()
        let watchdog = TestWatchdog(limit: 0.01) { _ in Task { await expired.record() } }

        try await watchdog.provideScope(for: .current!, testCase: .current) {}
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await expired.count == 0)
    }
}
#endif
