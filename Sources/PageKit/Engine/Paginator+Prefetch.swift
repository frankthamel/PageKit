/// Getting pages before they are needed, at two levels: a trigger that loads the next
/// page as the user nears the end, and a read-ahead that parks later pages in the cache.
extension Paginator {
    /// Tell the paginator an item came on screen, so it can load the next page in time.
    ///
    /// Call this from each cell's `onAppear`. It looks the item up in constant time, so
    /// it is safe to call for every cell. An unknown ID is ignored.
    public func itemAppeared(id: Source.Item.ID) {
        guard let index = indexByID[id] else { return }
        prefetch(upToIndex: index)
    }

    /// Loads the next page if `index` is within `prefetchDistance` items of the end.
    ///
    /// UIKit apps can forward the furthest index from `prefetchItemsAt`. Nothing happens
    /// while the list is loading, failed or finished, or while the app is in the background.
    /// The same goes after a page with no items, which only ``loadNextPage()`` moves past.
    public func prefetch(upToIndex index: Int) {
        guard canPrefetch, prefetchTask == nil,
              index >= items.count - configuration.prefetchDistance else { return }
        // Cleared once it runs, because from there on `state` blocks a second load.
        prefetchTask = Task {
            guard !Task.isCancelled else { return }
            prefetchTask = nil
            await loadNextPage()
        }
    }

    /// Tell the paginator whether the app is in the foreground. The default is `true`.
    ///
    /// Call this from `scenePhase`. In the background nothing is prefetched, though
    /// ``loadNextPage()`` still works. Read-ahead stops after the page it is waiting on,
    /// and starts again with the next page shown.
    public func setAppActive(_ isActive: Bool) {
        isAppActive = isActive
    }

    private var canPrefetch: Bool {
        isAppActive && state.canLoadMore && !newestPageWasBlank
    }

    /// Whether the newest page shows no items, which scrolling cannot move past. The
    /// distance trigger leaves such a page to an explicit ``loadNextPage()``.
    private var newestPageWasBlank: Bool {
        items.last.flatMap { pageByItem[$0.id] } != pageOrder.last
    }

    /// Starts reading ahead of the list, unless a read-ahead is already running.
    func scheduleReadAhead() {
        guard canPrefetch, configuration.cachePolicy.readsAhead, configuration.lookaheadPages > 0,
              readAheadTask == nil, let nextToken else { return }
        readAheadTask = Task { await readAhead(from: nextToken) }
    }

    /// Follows the chain from `start`, parking up to `lookaheadPages` pages.
    ///
    /// Nothing here touches the list or its state, so a failure just ends the read-ahead.
    /// A page is only parked once the page before it has named its token, so a wrong
    /// prediction can't put a page outside the chain into the cache.
    private func readAhead(from start: Token) async {
        let generation = self.generation
        defer {
            if generation == self.generation {
                readAheadTask = nil
                // A page shown meanwhile found this task still set, so its turn is now.
                if nextToken != start { scheduleReadAhead() }
            }
        }
        guard await networkAllowsReadAhead() else { return }

        var next: Token? = start
        var remaining = configuration.lookaheadPages
        while remaining > 0, let token = next {
            let cached = await readPage(token)
            guard generation == self.generation, isAppActive else { return }
            if let cached {
                next = cached.nextToken
                remaining -= 1
                continue
            }
            // Started together, these are the only parallel requests. A token that can't
            // predict its successor is a batch of one, so a cursor feed runs in sequence.
            let tokens = remaining > 1 ? [token, token.predictedNext].compactMap { $0 } : [token]
            let requests = tokens.map(request)
            for (token, request) in zip(tokens, requests) {
                let page = await readAheadPage(from: request)
                guard let page, token == next, generation == self.generation else { return }
                persist(page, token: token, clearEpoch: request.clearEpoch)
                // After a clear the page isn't parked, and following it would park the next.
                guard request.clearEpoch == environment.disk.clearEpoch(for: source.feedID) else { return }
                next = page.nextToken
                remaining -= 1
            }
        }
    }

    /// The page a request brings, or `nil`. Cancellation is expected, so only a real failure is logged.
    private func readAheadPage(from request: InFlightRequest) async -> Page<Item, Token>? {
        do {
            return try await request.task.value
        } catch {
            if let failure = ErrorClassifier.classify(error) {
                PageKitLog.logger.error("Read-ahead failed: \(String(describing: failure))")
            }
            return nil
        }
    }

    /// Whether the connection right now is one the app wants read-ahead to use.
    private func networkAllowsReadAhead() async -> Bool {
        guard let status = await environment.connectivity.updates().first(where: { _ in true }),
              status.isOnline else { return false }
        return configuration.allowsReadAheadOnExpensiveNetwork || !(status.isExpensive || status.isConstrained)
    }
}
