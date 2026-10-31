/// A connectivity source a test can flip by hand. Supports one listener.
struct FakeConnectivity: Sendable {
    /// Yields `true` for online and `false` for offline.
    let updates: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: Bool.self)
    }

    func setOnline(_ isOnline: Bool) {
        continuation.yield(isOnline)
    }
}
