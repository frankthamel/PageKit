import Foundation
@testable import PageKit

/// Writes whole feeds (a manifest plus one page) into a store, for maintenance and clearing tests.
enum FeedSeeding {
    static let token = CursorToken(value: nil, size: 20)

    /// Seeds one feed whose page holds `items` items, so its size is roughly `items * 8` bytes.
    static func seed(
        _ store: DiskPageStore, feedID: String, items: Int = 100, updatedAt: Date,
        maxAge: TimeInterval = 7 * 86_400, diskSizeLimit: Int = 50_000_000, storage: DiskStorage = .caches
    ) async {
        let manifest = FeedManifest(
            schemaVersion: 1, tokens: [token], lastNextToken: nil, updatedAt: updatedAt,
            maxAge: maxAge, diskSizeLimit: diskSizeLimit, storage: storage
        )
        await store.saveManifest(manifest, feedID: feedID)
        let page = Page<TestItem, CursorToken>(items: (0..<items).map { TestItem(id: $0) }, nextToken: nil)
        await store.save(page, feedID: feedID, token: token, schemaVersion: 1)
    }

    static func hasManifest(_ store: DiskPageStore, feedID: String) async -> Bool {
        await store.manifest(feedID: feedID, as: CursorToken.self, schemaVersion: 1) != nil
    }

    /// Total bytes of every feed in the store.
    static func totalBytes(_ store: DiskPageStore) async -> Int {
        await store.storedFeeds().reduce(0) { $0 + $1.bytes }
    }
}
