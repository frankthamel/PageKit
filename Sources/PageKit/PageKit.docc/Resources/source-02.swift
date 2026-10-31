import Foundation
import PageKit

struct RecipesResponse: Decodable, Sendable {
    let recipes: [Recipe]
    let totalPages: Int
}

let recipesSource = URLSessionPageSource<RecipesResponse, Recipe, IndexToken>(
    feedID: "recipes.all",
    firstToken: .first(size: 20),
    request: { token in
        URLRequest(url: URL(string: "https://api.example.com/recipes?page=\(token.page)")!)
    },
    map: { response, token in
        Page(items: response.recipes, nextToken: token.page < response.totalPages ? token.next : nil)
    }
)
