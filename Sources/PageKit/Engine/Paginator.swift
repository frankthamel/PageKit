import Foundation

/// Drives one paginated list. It is the only type an app talks to.
///
/// Create one per feed, call ``start()``, and render whatever arrives on
/// ``snapshots()``. The list is always in exactly one ``PaginationState``, and only
/// `.loaded(hasMore: true)` may start the next page.
///
/// Being an actor, it handles one decision at a time. Every `await` is still a point
/// where other calls can run, so state is re-checked after each one before anything
/// changes.
public actor Paginator<Source: PageSource> {
    typealias Item = Source.Item
    typealias Token = Source.Token

    let source: Source
    let configuration: PaginationConfiguration
    let environment: PaginatorEnvironment
    let retrier: Retrier
    nonisolated let broadcaster = SnapshotBroadcaster<Source.Item>()

    /// The list, in display order, with no duplicate IDs.
    var items: [Item] = []
    /// Each item's position in `items`.
    var indexByID: [Item.ID: Int] = [:]
    /// The token of every page that makes up `items`, in order.
    var pageOrder: [Token] = []
    /// The token of the following page, or `nil` at the end of the list.
    var nextToken: Token?
    /// The page each item came from.
    var pageByItem: [Item.ID: Token] = [:]
    /// Goes up whenever running loads stop counting, so their late results can be dropped.
    var generation = 0
    /// Requests under way, so that two callers for one page share one request.
    var inFlight: [Token: Task<Page<Item, Token>, Error>] = [:]
    /// What ``retry()`` repeats.
    var lastFailedOperation: LoadOperation?

    var state = PaginationState.idle {
        didSet { if !state.isLoading { stateBeforeLoad = state } }
    }
    /// The most recent state that was not a load, which a cancelled load goes back to.
    var stateBeforeLoad = PaginationState.idle
    var isStale = false
    var isOffline = false
    var lastError: PaginationError?
    var startTask: Task<Void, Never>?

    /// Creates a paginator. Nothing loads until ``start()``.
    /// - Parameters:
    ///   - source: Fetches the pages.
    ///   - configuration: Tunes caching, prefetching and retries.
    ///   - connectivity: Reports network status. The default watches the real network.
    public init(
        source: Source,
        configuration: PaginationConfiguration = .init(),
        connectivity: any ConnectivityMonitoring = NetworkPathMonitor()
    ) {
        self.init(
            source: source,
            configuration: configuration,
            environment: .live(configuration: configuration, connectivity: connectivity)
        )
    }

    init(source: Source, configuration: PaginationConfiguration, environment: PaginatorEnvironment) {
        self.source = source
        self.configuration = configuration
        self.environment = environment
        retrier = Retrier(policy: configuration.retry, sleep: environment.sleep)
        environment.memory.raiseCostLimit(to: configuration.memoryCostLimit)
    }

    /// A new stream on every call. It starts with the current snapshot, then delivers
    /// every change, in order. Any number of observers may listen at once.
    public nonisolated func snapshots() -> AsyncStream<PaginationSnapshot<Source.Item>> {
        broadcaster.stream()
    }

    /// Begins loading and returns at once. Results arrive on ``snapshots()``.
    ///
    /// Calling it again after the feed has opened does nothing.
    public func start() {
        guard state == .idle, startTask == nil else { return }
        startTask = Task { await open() }
    }

    /// Stops all work under way. A load that was running leaves no trace: the state
    /// goes back to what it was before the load, and its late result is ignored.
    public func cancel() {
        startTask?.cancel()
        startTask = nil
        invalidateLoads()
        guard state.isLoading else { return }
        state = stateBeforeLoad
        publish()
    }

    /// Cancels every request and makes sure no running load can apply its result.
    func invalidateLoads() {
        generation += 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    /// Sends the current state to every observer, as one snapshot.
    func publish() {
        broadcaster.publish(
            PaginationSnapshot(
                items: items, state: state, isStale: isStale, isOffline: isOffline, lastError: lastError
            )
        )
    }
}

/// Holds the latest snapshot and every observer's stream.
///
/// A lock, not the actor, guards them so that `snapshots()` needs no `await`.
/// `@unchecked Sendable` is safe because `latest` and `continuations` are only touched
/// while holding `lock`. Publishing inside the lock means a new observer can neither
/// miss a snapshot nor see one twice, and every observer sees the same order.
final class SnapshotBroadcaster<Item: Identifiable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current = PaginationSnapshot<Item>.initial
    private var continuations: [UUID: AsyncStream<PaginationSnapshot<Item>>.Continuation] = [:]

    /// The snapshot most recently published.
    var latest: PaginationSnapshot<Item> { lock.withLock { current } }

    /// How many streams are still listening.
    var subscriberCount: Int { lock.withLock { continuations.count } }

    /// A stream that starts with the latest snapshot, then delivers every later one.
    func stream() -> AsyncStream<PaginationSnapshot<Item>> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
            lock.withLock {
                continuations[id] = continuation
                continuation.yield(current)
            }
        }
    }

    /// Records `snapshot` as the latest and delivers it to every stream.
    func publish(_ snapshot: PaginationSnapshot<Item>) {
        lock.withLock {
            current = snapshot
            continuations.values.forEach { $0.yield(snapshot) }
        }
    }

    private func remove(_ id: UUID) {
        lock.withLock { continuations[id] = nil }
    }
}
