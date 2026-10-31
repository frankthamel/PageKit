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

    /// A request under way, which any number of callers can share.
    struct InFlightRequest {
        let task: Task<Page<Item, Token>, Error>
        /// The feed's clear epoch from before the request, which every caller persists
        /// with. A caller that joins after a clear must not take the page for a new one.
        let clearEpoch: Int
        /// How many edits came before the request. Its page predates any after these.
        let editsBefore: Int
    }

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
    /// Later pages that repeat an item, whose cached copies still hold it.
    var otherPagesByItem: [Item.ID: Set<Token>] = [:]
    /// Goes up whenever running loads stop counting, so their late results can be dropped.
    ///
    /// Invariant: any path that changes `state` during a load must bump this, or that
    /// load will overwrite the change when it finishes. A load that finds this moved
    /// leaves `state` alone, so every bump must come with a state that isn't left loading.
    /// Read-ahead stops on the same signal, so a page from an old chain is never parked.
    var generation = 0
    /// Requests under way, so that two callers for one page share one request.
    var inFlight: [Token: InFlightRequest] = [:]
    /// What ``retry()`` repeats.
    var lastFailedOperation: LoadOperation?
    /// A next-page load the distance trigger has queued but that has not begun.
    var prefetchTask: Task<Void, Never>?
    /// The read-ahead under way. There is at most one.
    var readAheadTask: Task<Void, Never>?
    /// Set by ``setAppActive(_:)``. Nothing is prefetched while it is `false`.
    var isAppActive = true

    var state = PaginationState.idle {
        didSet { if !state.isLoading { stateBeforeLoad = state } }
    }
    /// The most recent state that was not a load, which a cancelled load goes back to.
    var stateBeforeLoad = PaginationState.idle
    var isStale = false
    var isOffline = false
    var lastError: PaginationError?
    var startTask: Task<Void, Never>?
    /// Set once by ``cancel()``, which is final.
    var isCancelled = false
    /// Every edit so far, kept for the paginator's life: a request from before an edit
    /// can land at any time, and a parked page can be served at any time. It grows by one
    /// entry, holding at most one item, per edit the user makes.
    var localEdits: [LocalEdit] = []
    /// Delivers network status for as long as the paginator lives.
    var connectivityTask: Task<Void, Never>?
    /// The latest network status, or `nil` until the first arrives.
    var connectivityStatus: ConnectivityStatus?
    /// The work the most recent reconnect started.
    var reconnectTask: Task<Void, Never>?
    /// Whether a reconnect is waiting for a load to settle or the app to come back.
    var isResumePending = false
    /// The most recent disk write. Each one waits for the one before, so they land in order.
    var pendingWrite: Task<Void, Never>?
    /// The most recent queued deletion of cached pages.
    var pendingDiscard: Task<Void, Never>?

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

    deinit {
        connectivityTask?.cancel()
        broadcaster.finish()
    }

    /// A new stream on every call. It starts with the current snapshot, then delivers
    /// every change, in order. Any number of observers may listen at once.
    ///
    /// After ``cancel()`` a new stream delivers the final snapshot and finishes. Every
    /// stream also finishes once the paginator is gone.
    public nonisolated func snapshots() -> AsyncStream<PaginationSnapshot<Source.Item>> {
        broadcaster.stream()
    }

    /// Begins loading and returns at once. Results arrive on ``snapshots()``.
    ///
    /// Calling it again after the feed has opened, or after ``cancel()``, does nothing.
    public func start() {
        guard state == .idle, startTask == nil, !isCancelled else { return }
        environment.scheduleMaintenance()
        if connectivityTask == nil { startListeningForConnectivity() }
        startTask = Task { await open() }
    }

    /// Stops all work and finishes every ``snapshots()`` stream. A load that was running
    /// leaves no trace: the state goes back to what it was before the load, and its late
    /// result is ignored.
    ///
    /// This is final. Every later call on this paginator does nothing. Make a new one to
    /// show the feed again.
    public func cancel() {
        isCancelled = true
        startTask?.cancel()
        startTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        reconnectTask?.cancel()
        connectivityTask?.cancel()
        invalidateLoads()
        if state.isLoading {
            state = stateBeforeLoad
            publish()
        }
        broadcaster.finish()
    }

    /// Cancels every request and makes sure no running load or read-ahead can use its result.
    func invalidateLoads() {
        generation += 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        readAheadTask?.cancel()
        readAheadTask = nil
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
    private var isFinished = false

    /// How many streams are still listening.
    var subscriberCount: Int { lock.withLock { continuations.count } }

    /// A stream that starts with the latest snapshot, then delivers every later one.
    /// Once finished, that first snapshot is also the last.
    ///
    /// `onTermination` takes the lock, so `finish()` on a continuation must be called
    /// outside it, here and in ``finish()``.
    func stream() -> AsyncStream<PaginationSnapshot<Item>> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
            let isOpen = lock.withLock {
                continuation.yield(current)
                if !isFinished { continuations[id] = continuation }
                return !isFinished
            }
            if !isOpen { continuation.finish() }
        }
    }

    /// Records `snapshot` as the latest and delivers it to every stream.
    func publish(_ snapshot: PaginationSnapshot<Item>) {
        lock.withLock {
            current = snapshot
            continuations.values.forEach { $0.yield(snapshot) }
        }
    }

    /// Ends every stream, and every stream asked for from now on.
    func finish() {
        let open = lock.withLock {
            isFinished = true
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        open.forEach { $0.finish() }
    }

    private func remove(_ id: UUID) {
        lock.withLock { continuations[id] = nil }
    }
}
