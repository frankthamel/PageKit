import Observation
import PageKit

@MainActor @Observable
final class RecipesViewModel {
    private(set) var snapshot = PaginationSnapshot<Recipe>.initial
    private let paginator = Paginator(source: recipesSource)

    deinit {
        let paginator = paginator
        Task { await paginator.cancel() }
    }
}
