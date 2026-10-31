/// The simplest possible item: an identity, plus content that can change without it.
struct TestItem: Identifiable, Codable, Sendable, Equatable {
    let id: Int
    var title: String?
}
