import Foundation
import PageKit

struct RecipesResponse: Decodable, Sendable {
    let recipes: [Recipe]
    let totalPages: Int
}
