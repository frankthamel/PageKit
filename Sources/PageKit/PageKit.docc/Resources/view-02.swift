import PageKit
import SwiftUI

struct RecipesView: View {
    @State private var model = RecipesViewModel()

    var body: some View {
        List {
            ForEach(model.snapshot.items) { recipe in
                Text(recipe.title)
                    .onAppear { model.itemAppeared(recipe) }
            }
            RecipesFooter(state: model.snapshot.state, retry: model.retry)
        }
    }
}

struct RecipesFooter: View {
    let state: PaginationState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .loadingFirstPage, .loadingNextPage:
            ProgressView()
        case .failed:
            Button("Couldn't load. Tap to retry.", action: retry)
        case .loaded(hasMore: false):
            Text("That's every recipe")
        case .empty:
            Text("No recipes yet")
        case .idle, .loaded, .refreshing:
            EmptyView()
        }
    }
}
