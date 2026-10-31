/// A load that can fail, and so can be repeated by `retry()`.
enum LoadOperation: Sendable {
    case firstPage
    case nextPage
    case refresh
    case revalidate
}

/// Where a load's page came from. Only a page from the network has anything to save.
enum PageOrigin: Sendable {
    case network
    case cache
}

extension Paginator {
    /// Loads the next page. Does nothing unless the state is `.loaded(hasMore: true)`.
    public func loadNextPage() async {
        guard state.canLoadMore else { return }
        await load(.nextPage)
    }

    /// Reloads from the first page.
    ///
    /// On success the new page replaces the list. On failure every item stays: the
    /// state returns to `.loaded`, and the snapshot's `lastError` is set. With no items
    /// to keep, a failure is `.failed(_, isFirstPage: true)` instead.
    ///
    /// Under ``CachePolicy/cacheOnly`` this does nothing, because that policy never uses
    /// the network.
    public func refresh() async {
        guard configuration.cachePolicy != .cacheOnly else { return }
        await load(.refresh)
    }

    /// Repeats the load that last failed. Does nothing if none has, or while loading.
    public func retry() async {
        guard !state.isLoading, let lastFailedOperation else { return }
        if lastFailedOperation == .revalidate {
            await revalidateFirstPage()
        } else {
            await load(lastFailedOperation)
        }
    }

    /// The first load after `start()`.
    ///
    /// `startTask` is cleared as soon as this task runs, not when it ends: from here on
    /// `state` decides whether `start()` may run again, and the task's end can lag
    /// behind a source that ignores cancellation.
    func open() async {
        guard !Task.isCancelled else { return }
        startTask = nil
        guard state == .idle else { return }
        if configuration.cachePolicy.readsCacheFirst {
            await openFromCache()
        } else {
            await load(.firstPage)
        }
    }

    /// Fetches a page through the shared in-flight table, with retries.
    ///
    /// A second caller for the same token waits for the first caller's request.
    /// Cancelling a caller here does not cancel the request, because others may share
    /// it. `load(_:)` adds that for the one caller that owns the list's state, so work
    /// calling `fetch` directly, such as read-ahead, is not affected.
    func fetch(_ token: Source.Token) async throws -> Page<Source.Item, Source.Token> {
        if let existing = inFlight[token] {
            return try await existing.value
        }
        let task = Task { [source, retrier] in
            try await retrier.run { try await source.loadPage(token) }
        }
        inFlight[token] = task
        // Invalidating loads may have put a newer request under this token. Leave that one be.
        defer { if inFlight[token] == task { inFlight[token] = nil } }
        return try await task.value
    }

    /// Runs one load from its loading state through to its final snapshot.
    func load(_ operation: LoadOperation) async {
        guard !Task.isCancelled else { return }
        if operation == .refresh { invalidateLoads() }
        guard let token = operation == .nextPage ? nextToken : source.firstToken else { return }
        state = loadingState(for: operation)
        publish()

        latestLoad += 1
        let load = latestLoad
        let generation = self.generation
        let result: Result<(page: Page<Item, Token>, origin: PageOrigin), Error>
        do {
            result = .success(try await withTaskCancellationHandler {
                try await resolvePage(token, for: operation)
            } onCancel: { [self] in
                Task { await abandonLoad(load, generation: generation, token: token) }
            })
        } catch {
            result = .failure(error)
        }

        // The world may have changed while waiting. Whoever replaced this load owns the state now.
        guard generation == self.generation, load == latestLoad else { return }
        guard !Task.isCancelled else { return restoreState() }
        switch result {
        case .success(let resolved):
            apply(resolved.page, token: token, operation: operation, origin: resolved.origin)
        case .failure(let error):
            guard let failure = ErrorClassifier.classify(error) else { return restoreState() }
            let recovered = await recoverFromCache(operation, token: token, failure: failure)
            guard generation == self.generation, !recovered else { return }
            guard !Task.isCancelled else { return restoreState() }
            fail(operation, with: failure)
        }
    }

    /// Finds a load's page where its cache policy says to look first.
    ///
    /// Under `.cacheOnly` a miss is the end of the chain. An empty last page says so,
    /// and takes the same path as any other page.
    private func resolvePage(
        _ token: Token, for operation: LoadOperation
    ) async throws -> (page: Page<Item, Token>, origin: PageOrigin) {
        guard operation == .nextPage, configuration.cachePolicy.readsCacheFirst else {
            return (try await fetch(token), .network)
        }
        let generation = self.generation
        if let cached = await readPage(token) { return (cached, .cache) }
        guard generation == self.generation, !Task.isCancelled else { throw CancellationError() }
        guard configuration.cachePolicy != .cacheOnly else {
            return (Page(items: [], nextToken: nil), .cache)
        }
        return (try await fetch(token), .network)
    }

    /// Under `.networkFirst`, shows what the cache holds after a failed load.
    ///
    /// A refresh never comes here: it keeps what is on screen, and there is nothing to
    /// gain from a retried first page with items already showing.
    /// - Returns: `true` if the load has been dealt with.
    private func recoverFromCache(_ operation: LoadOperation, token: Token, failure: PaginationError) async -> Bool {
        guard configuration.cachePolicy == .networkFirst else { return false }
        switch operation {
        case .firstPage where items.isEmpty:
            lastFailedOperation = .firstPage
            return await restoreFromCache(reporting: failure)
        case .nextPage:
            guard let cached = await readPage(token) else { return false }
            isStale = true
            apply(cached, token: token, operation: .nextPage, origin: .cache)
            return true
        case .firstPage, .refresh, .revalidate:
            return false
        }
    }

    /// Ends a load whose caller was cancelled, without waiting for its request.
    ///
    /// This arrives by a separate task, so it can land after the load has finished. It
    /// only acts if `load` is still the load under way, whose result can no longer apply.
    func abandonLoad(_ load: Int, generation: Int, token: Token) {
        guard load == latestLoad, generation == self.generation, state.isLoading else { return }
        inFlight[token]?.cancel()
        inFlight[token] = nil
        latestLoad += 1
        restoreState()
    }

    private func loadingState(for operation: LoadOperation) -> PaginationState {
        switch operation {
        case .nextPage: .loadingNextPage
        case .firstPage, .refresh, .revalidate: items.isEmpty ? .loadingFirstPage : .refreshing
        }
    }

    /// Takes in a page that belongs to the current list, as one snapshot.
    ///
    /// A page that replaces the list makes every later cached page part of the old chain,
    /// so they go, but only now that the new page has arrived.
    func apply(_ page: Page<Item, Token>, token: Token, operation: LoadOperation, origin: PageOrigin) {
        if operation != .nextPage {
            removeAllItems()
            discardCachedPages(except: [token])
            isStale = false
        }
        append(page, token: token)
        nextToken = page.nextToken
        if origin == .network { persist(page, token: token) }
        lastError = nil
        // A cached page says nothing about the network, so a failed revalidation still stands.
        if origin == .network || lastFailedOperation != .revalidate { lastFailedOperation = nil }
        state = settledState
        publish()
    }

    /// What the state is once the list holds what it should.
    var settledState: PaginationState {
        items.isEmpty ? .empty : .loaded(hasMore: nextToken != nil)
    }

    private func removeAllItems() {
        items.removeAll()
        indexByID.removeAll()
        pageByItem.removeAll()
        pageOrder.removeAll()
    }

    /// Appends the items whose IDs are new. The token is recorded even if none are,
    /// so a page of only duplicates still moves the list forward.
    func append(_ page: Page<Item, Token>, token: Token) {
        pageOrder.append(token)
        for item in page.items where indexByID[item.id] == nil {
            indexByID[item.id] = items.count
            pageByItem[item.id] = token
            items.append(item)
        }
    }

    /// Records a failure. Items on screen are never removed, so `.failed(_, isFirstPage: true)`
    /// always means there is nothing to show, and a failed refresh does not block scrolling.
    private func fail(_ operation: LoadOperation, with error: PaginationError) {
        PageKitLog.logger.error("Page load failed: \(String(describing: error))")
        lastFailedOperation = operation
        if items.isEmpty {
            state = .failed(error, isFirstPage: true)
        } else if operation == .nextPage {
            state = .failed(error, isFirstPage: false)
        } else {
            lastError = error
            state = .loaded(hasMore: nextToken != nil)
        }
        publish()
    }

    /// Ends a cancelled load. Cancellation is not an error, so only the state changes.
    private func restoreState() {
        state = stateBeforeLoad
        publish()
    }
}
