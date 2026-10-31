/// Everything a UI needs to draw a list at one moment.
public struct PaginationSnapshot<Item: Identifiable & Sendable>: Sendable {
    /// The items to show, in order, with no duplicate IDs.
    public let items: [Item]

    /// Where the list is in its loading life cycle.
    public let state: PaginationState

    /// `true` while cached items are shown and a refresh is still in flight.
    public let isStale: Bool

    /// `true` when the device has no connection. Independent of `state`.
    public let isOffline: Bool

    /// The most recent error that did not replace the items on screen, if any.
    public let lastError: PaginationError?

    /// An empty list that has not started loading.
    public static var initial: PaginationSnapshot {
        PaginationSnapshot(items: [], state: .idle, isStale: false, isOffline: false, lastError: nil)
    }

    init(items: [Item], state: PaginationState, isStale: Bool, isOffline: Bool, lastError: PaginationError?) {
        self.items = items
        self.state = state
        self.isStale = isStale
        self.isOffline = isOffline
        self.lastError = lastError
    }
}
