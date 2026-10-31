import Testing
@testable import PageKit

@Suite(.watchdog) struct ConnectivityTests {
    @Test func statusEquality() {
        #expect(ConnectivityStatus.online == ConnectivityStatus(isOnline: true))
        #expect(ConnectivityStatus.online.isExpensive == false)
        #expect(ConnectivityStatus.online.isConstrained == false)
        #expect(ConnectivityStatus(isOnline: true, isExpensive: true) != .online)
        #expect(ConnectivityStatus(isOnline: false) != .online)
    }

    @Test func fakeConnectivityDeliversUpdates() async {
        let fake = FakeConnectivity()
        var first = fake.updates().makeAsyncIterator()
        var second = fake.updates().makeAsyncIterator()
        #expect(await first.next() == .online)
        #expect(await second.next() == .online)

        let cellular = ConnectivityStatus(isOnline: true, isExpensive: true)
        fake.set(cellular)
        fake.setOnline(false)
        #expect(await first.next() == cellular)
        #expect(await first.next() == ConnectivityStatus(isOnline: false))
        #expect(await second.next() == cellular)
    }

    @Test func monitorProducesAFirstValue() async {
        let received = await withTaskGroup(of: ConnectivityStatus?.self) { group in
            group.addTask {
                var iterator = NetworkPathMonitor().updates().makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(received != nil)
    }
}
