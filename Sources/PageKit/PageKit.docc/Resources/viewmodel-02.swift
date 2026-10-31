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

    func run() async {
        await paginator.start()
        for await snapshot in paginator.snapshots() {
            self.snapshot = snapshot
        }
    }

    func itemAppeared(_ recipe: Recipe) {
        Task { await paginator.itemAppeared(id: recipe.id) }
    }

    func retry() {
        Task { await paginator.retry() }
    }
}
