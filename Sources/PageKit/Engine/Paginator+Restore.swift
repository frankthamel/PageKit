import Foundation

extension CachePolicy {
    /// Whether this policy may read or write a cache at all.
    var usesCache: Bool { self != .networkOnly }

    /// Whether a next page is looked for in the cache before the network.
    var readsCacheFirst: Bool { self == .cacheOnly || self == .cacheThenNetwork }

    /// Whether a page fetched ahead of the list would ever be served. That takes a network
    /// to fetch it and a next load that looks in the cache first. Under `.networkFirst` the
    /// next load fetches the page again, and may be led to different pages after it.
    var readsAhead: Bool { self == .cacheThenNetwork }
}

/// The cache half of the engine.
///
/// One invariant keeps it simple: every page in the cache belongs to the current chain.
/// Replacing the list deletes the later pages, so a cached page is always safe to append.
/// The manifest lists only the pages on screen. A parked page is reached from
/// `lastNextToken`, one page at a time, as any cached next page is.
extension Paginator {
    private var feedID: String { source.feedID }

    /// Opens a feed that shows its cached pages first.
    ///
    /// Disk reads suspend, so the state must leave `.idle` first or a second `start()`
    /// would open the feed again. It is not published: observers go straight to the
    /// cached items, or to the first-page load if there are none.
    func openFromCache() async {
        latestLoad += 1
        state = .loadingFirstPage
        let generation = self.generation
        let restored = await restoreFromCache()
        guard generation == self.generation else { return }
        switch (restored, configuration.cachePolicy) {
        case (true, .cacheOnly):
            break
        case (false, .cacheOnly):
            state = .empty
            publish()
        case (true, _):
            await revalidateFirstPage()
        case (false, _):
            await load(.firstPage)
        }
    }

    /// Shows the feed's whole saved chain, as one snapshot.
    ///
    /// A page missing from the chain ends it early. The pages before it still join up.
    /// - Parameter error: The failure that led here, to report with the cached items.
    /// - Returns: `true` if there was something to show. `false` also covers being
    ///   overtaken by a newer load, so the caller must re-check the generation.
    @discardableResult
    func restoreFromCache(reporting error: PaginationError? = nil) async -> Bool {
        let generation = self.generation
        await environment.beforeDiskRead()
        let manifest = await environment.disk.manifest(
            feedID: feedID, as: Token.self, schemaVersion: configuration.schemaVersion
        )
        guard generation == self.generation, let manifest, manifest.tokens.first == source.firstToken else {
            return false
        }
        guard environment.now().timeIntervalSince(manifest.updatedAt) <= manifest.maxAge else {
            discardCachedPages(except: [])
            return false
        }

        var pages: [(token: Token, page: Page<Item, Token>)] = []
        for token in manifest.tokens {
            let page = await readPage(token)
            guard generation == self.generation else { return false }
            guard let page else { break }
            pages.append((token, page))
        }
        // Nothing past a break can be reached by following the chain, so none of it may be served.
        if pages.count < manifest.tokens.count { discardCachedPages(except: pages.map(\.token)) }
        guard pages.contains(where: { !$0.page.items.isEmpty }) else { return false }

        pages.forEach { append($0.page, token: $0.token) }
        nextToken = pages.last?.page.nextToken
        // Under `.cacheOnly` no network load is coming to confirm these items.
        isStale = configuration.cachePolicy != .cacheOnly
        lastError = error
        state = settledState
        publish()
        return true
    }

    /// Checks restored items against page 1 from the network, without blocking the list.
    ///
    /// The state stays as it is, so the user can keep scrolling, and a failure only
    /// sets `lastError`.
    func revalidateFirstPage() async {
        let generation = self.generation
        let token = source.firstToken
        do {
            let fetched = try await fetch(token)
            guard generation == self.generation, !Task.isCancelled else { return }
            adoptFirstPage(fetched.page, token: token, clearEpoch: fetched.clearEpoch)
        } catch {
            guard generation == self.generation, !Task.isCancelled,
                  let failure = ErrorClassifier.classify(error) else { return }
            PageKitLog.logger.error("Revalidation failed: \(String(describing: failure))")
            lastError = failure
            // A next page that failed is what the footer is waiting on, so retry stays with
            // it, even while it is being retried: a cancelled retry goes back to `.failed`.
            if case .failed = stateBeforeLoad {} else { lastFailedOperation = .revalidate }
            publish()
        }
    }

    /// Takes in a fresh page 1: in place if it still leads into the same chain, otherwise
    /// as a new list.
    private func adoptFirstPage(_ page: Page<Item, Token>, token: Token, clearEpoch: Int) {
        let following = pageOrder.count > 1 ? pageOrder[1] : nextToken
        guard hasSameItems(page, token: token), page.nextToken == following else {
            return apply(page, token: token, operation: .refresh, origin: .network(clearEpoch: clearEpoch))
        }
        for item in page.items {
            if let index = indexByID[item.id] { items[index] = item }
        }
        persist(page, token: token, clearEpoch: clearEpoch)
        isStale = false
        lastError = nil
        if lastFailedOperation == .revalidate { lastFailedOperation = nil }
        if case .loaded = state { state = settledState }
        publish()
        scheduleReadAhead()
    }

    /// Whether `page` has the IDs of the items now shown from `token`, in the same order.
    private func hasSameItems(_ page: Page<Item, Token>, token: Token) -> Bool {
        var seen = Set<Item.ID>()
        let incoming = page.items.map(\.id).filter { seen.insert($0).inserted }
        return incoming == items.map(\.id).filter { pageByItem[$0] == token }
    }

    /// Reads a page from memory, then disk, and promotes a disk page to memory.
    ///
    /// A page being discarded is gone from memory at once but from disk only when its
    /// turn in the write queue comes, so a disk read waits for that first.
    /// A load that is overtaken meanwhile gets `nil`, because its page may no longer
    /// belong to the chain and must not go back into memory.
    func readPage(_ token: Token) async -> Page<Item, Token>? {
        guard configuration.cachePolicy.usesCache else { return nil }
        let key = PageKey(feedID: feedID, token: token)
        if let page = environment.memory.page(for: key, as: Page<Item, Token>.self) { return page }

        let generation = self.generation
        let clearEpoch = environment.disk.clearEpoch(for: feedID)
        await pendingDiscard?.value
        await environment.beforeDiskRead()
        let page: Page<Item, Token>? = await environment.disk.page(
            feedID: feedID, token: token, schemaVersion: configuration.schemaVersion
        )
        guard let page, generation == self.generation else { return nil }
        if clearEpoch == environment.disk.clearEpoch(for: feedID) {
            environment.memory.store(page, for: key, cost: cost(of: page))
        }
        return page
    }

    /// Stores a page in memory and queues it for disk, with a manifest of the list as it is now.
    ///
    /// Page and manifest go together, so maintenance never finds a feed without a manifest.
    /// - Parameter clearEpoch: The feed's epoch from before the page was requested. If the
    ///   feed has been cleared since, the page stays out of both caches, even if the clear
    ///   comes after this call but before the write lands.
    func persist(_ page: Page<Item, Token>, token: Token, clearEpoch: Int) {
        guard configuration.cachePolicy.usesCache,
              clearEpoch == environment.disk.clearEpoch(for: feedID) else { return }
        environment.memory.store(page, for: PageKey(feedID: feedID, token: token), cost: cost(of: page))
        let manifest = FeedManifest(
            schemaVersion: configuration.schemaVersion,
            tokens: pageOrder,
            lastNextToken: nextToken,
            updatedAt: environment.now(),
            maxAge: configuration.maxAge,
            diskSizeLimit: configuration.diskSizeLimit,
            storage: configuration.storage
        )
        enqueueDiskWrite { [feedID, schemaVersion = configuration.schemaVersion] disk in
            await disk.save(
                page, manifest: manifest, feedID: feedID, token: token,
                schemaVersion: schemaVersion, clearEpoch: clearEpoch
            )
        }
    }

    /// Deletes the feed's cached pages, other than `tokens`, from memory and disk.
    func discardCachedPages(except tokens: [Token]) {
        guard configuration.cachePolicy.usesCache else { return }
        environment.memory.removeFeed(feedID)
        pendingDiscard = enqueueDiskWrite { [feedID] disk in
            await disk.removePages(feedID: feedID, except: tokens)
        }
    }

    /// Waits until every queued disk write has landed. For tests.
    func waitForPendingWrites() async {
        await pendingWrite?.value
    }

    /// Runs `write` after every earlier write, without making the caller wait.
    ///
    /// Tasks on an actor have no guaranteed order, and an old manifest landing last would
    /// undo a newer one, so each write waits for the one before.
    @discardableResult
    private func enqueueDiskWrite(_ write: @escaping @Sendable (DiskPageStore) async -> Void) -> Task<Void, Never> {
        let earlier = pendingWrite
        let task = Task { [environment] in
            await earlier?.value
            await environment.beforeDiskWrite()
            await write(environment.disk)
        }
        pendingWrite = task
        return task
    }

    /// A page's size as JSON, which is what the memory cache budgets by.
    private func cost(of page: Page<Item, Token>) -> Int {
        (try? JSONEncoder().encode(page))?.count ?? 0
    }
}
