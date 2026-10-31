/// Where a list is in its loading life cycle.
///
/// The list is always in exactly one state, and only `.loaded(hasMore: true)`
/// may start the next page. That single rule prevents duplicate loads, loads
/// after the end and retry storms.
public enum PaginationState: Equatable, Sendable {
    /// Nothing has been requested yet.
    case idle

    /// The first page is loading and there is nothing to show yet.
    case loadingFirstPage

    /// Items are showing. `hasMore` is `false` once the end of the list is reached.
    case loaded(hasMore: Bool)

    /// A later page is loading while earlier items stay on screen.
    case loadingNextPage

    /// The list is reloading from the first page.
    case refreshing

    /// The first page arrived with no items, or the last item was removed.
    case empty

    /// A load failed. `isFirstPage` is `true` when there is nothing to show.
    case failed(PaginationError, isFirstPage: Bool)

    /// The only state from which a next-page load may start.
    var canLoadMore: Bool { self == .loaded(hasMore: true) }

    /// Whether a load is under way.
    var isLoading: Bool {
        switch self {
        case .loadingFirstPage, .loadingNextPage, .refreshing: true
        case .idle, .loaded, .empty, .failed: false
        }
    }
}
