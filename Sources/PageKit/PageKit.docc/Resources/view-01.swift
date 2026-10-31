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
        }
    }
}
