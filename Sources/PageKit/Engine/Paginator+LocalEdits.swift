/// Changes the user made to single items, which land in the list and both caches at once.
///
/// Only the page holding the item is rewritten, from what the list shows. That needs no
/// cache read, so an evicted page file is no obstacle: the file just comes back with
/// the page's current items.
extension Paginator {
    /// One user change, kept so a request from before it can't undo it.
    struct LocalEdit {
        let id: Item.ID
        /// The item's new value, or `nil` if it was removed.
        let replacement: Item?
    }

    /// Removes an item from the list, the memory cache and the disk cache.
    ///
    /// Returns once the change is on disk. An unknown ID is ignored. If that was the last
    /// item the state becomes `.empty`, or the next page loads if there is one. Removing
    /// the last of the newest page's items also loads the next page, because scrolling
    /// can't reach it. Pages requested earlier come back without the item, but one
    /// requested later is believed, so tell the server first.
    public func remove(id: Source.Item.ID) async {
        guard !isCancelled, let index = indexByID[id], let token = pageByItem[id] else { return }
        items.remove(at: index)
        indexByID[id] = nil
        pageByItem[id] = nil
        for position in index..<items.count { indexByID[items[position].id] = position }
        record(LocalEdit(id: id, replacement: nil), in: token)
        if items.isEmpty {
            // Whatever is running belongs to the list that has just gone.
            invalidateLoads()
            state = nextToken == nil ? .empty : .loaded(hasMore: true)
        }
        publish()
        loadNextPageIfNewestIsBlank()
        await waitForPendingWrites()
    }

    /// Replaces an item, in the same position, in the list and both caches.
    ///
    /// Returns once the change is on disk. An item with an unknown ID is ignored.
    public func update(_ item: Source.Item) async {
        guard !isCancelled, let index = indexByID[item.id], let token = pageByItem[item.id] else { return }
        items[index] = item
        record(LocalEdit(id: item.id, replacement: item), in: token)
        publish()
        await waitForPendingWrites()
    }

    /// Notes the edit for requests under way and saves the page it changed.
    ///
    /// The save carries the list's clear epoch, so after a clear the list changes but no
    /// page of the old list goes back into a cache.
    private func record(_ edit: LocalEdit, in token: Token) {
        localEdits.append(edit)
        guard let position = pageOrder.firstIndex(of: token) else { return }
        let next = position + 1 < pageOrder.count ? pageOrder[position + 1] : nextToken
        let page = Page(items: items.filter { pageByItem[$0.id] == token }, nextToken: next)
        persist(page, token: token, clearEpoch: listClearEpoch)
    }

    /// The page `request` brings, with every edit made since it began.
    func page(from request: InFlightRequest) async throws -> Page<Item, Token> {
        let page = try await request.task.value
        let edits = localEdits[request.editsBefore...]
        guard !edits.isEmpty else { return page }
        let items = edits.reduce(page.items) { items, edit in
            items.compactMap { $0.id == edit.id ? edit.replacement : $0 }
        }
        return Page(items: items, nextToken: page.nextToken)
    }
}
