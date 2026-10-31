/// The simplest possible item: just an identity.
struct TestItem: Identifiable, Codable, Sendable, Equatable {
    let id: Int
}
