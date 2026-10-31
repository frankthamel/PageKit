/// A load that can fail, and so can be repeated by `retry()`.
enum LoadOperation: Sendable {
    case firstPage
    case nextPage
    case refresh
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
    /// state returns to `.loaded`, and the snapshot's `lastError` is set.
    public func refresh() async {
        await load(.refresh)
    }

    /// Repeats the load that last failed. Does nothing if none has, or while loading.
    public func retry() async {
        guard !state.isLoading, let lastFailedOperation else { return }
        await load(lastFailedOperation)
    }

    /// The first load after `start()`.
    func open() async {
        guard state == .idle, !Task.isCancelled else { return }
        await load(.firstPage)
    }

    /// Fetches a page through the shared in-flight table, with retries.
    ///
    /// A second caller for the same token waits for the first caller's request.
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
    private func load(_ operation: LoadOperation) async {
        if operation == .refresh { invalidateLoads() }
        guard let token = operation == .nextPage ? nextToken : source.firstToken else { return }
        state = loadingState(for: operation)
        publish()

        let generation = self.generation
        let result: Result<Page<Item, Token>, Error>
        do {
            result = .success(try await fetch(token))
        } catch {
            result = .failure(error)
        }

        // The world may have changed while waiting. A newer generation owns the state now.
        guard generation == self.generation else { return }
        guard !Task.isCancelled else { return restoreState() }
        switch result {
        case .success(let page):
            apply(page, token: token, operation: operation)
        case .failure(let error):
            guard let failure = ErrorClassifier.classify(error) else { return restoreState() }
            fail(operation, with: failure)
        }
    }

    private func loadingState(for operation: LoadOperation) -> PaginationState {
        switch operation {
        case .nextPage: .loadingNextPage
        case .firstPage, .refresh: items.isEmpty ? .loadingFirstPage : .refreshing
        }
    }

    /// Takes in a page that belongs to the current list, as one snapshot.
    private func apply(_ page: Page<Item, Token>, token: Token, operation: LoadOperation) {
        if operation != .nextPage { removeAllItems() }
        append(page, token: token)
        nextToken = page.nextToken
        lastError = nil
        lastFailedOperation = nil
        state = items.isEmpty ? .empty : .loaded(hasMore: nextToken != nil)
        publish()
    }

    private func removeAllItems() {
        items.removeAll()
        indexByID.removeAll()
        pageByItem.removeAll()
        pageOrder.removeAll()
    }

    /// Appends the items whose IDs are new. The token is recorded even if none are,
    /// so a page of only duplicates still moves the list forward.
    private func append(_ page: Page<Item, Token>, token: Token) {
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
