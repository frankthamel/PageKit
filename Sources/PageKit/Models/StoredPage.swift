import Foundation

/// One page as written to disk.
struct StoredPage<Item: Codable & Sendable, Token: PageToken>: Codable, Sendable {
    let schemaVersion: Int
    let storedAt: Date
    let items: [Item]
    let nextToken: Token?
}
