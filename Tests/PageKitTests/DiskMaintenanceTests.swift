import Foundation
import Testing
@testable import PageKit

final class DiskMaintenanceTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PageKitMaintenanceTests-\(UUID().uuidString)", isDirectory: true)
    private let now = Date(timeIntervalSince1970: 10_000_000)

    deinit { try? FileManager.default.removeItem(at: root) }

    private var store: DiskPageStore { DiskPageStore(root: root) }
    private var maintenance: DiskMaintenance { DiskMaintenance(now: { [now] in now }) }

    private func age(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func seed(_ store: DiskPageStore, _ feedID: String, age seconds: TimeInterval, limit: Int = 50_000_000,
                      maxAge: TimeInterval = 30 * 86_400, storage: DiskStorage = .caches) async {
        await FeedSeeding.seed(store, feedID: feedID, items: 1_000, updatedAt: age(seconds),
                               maxAge: maxAge, diskSizeLimit: limit, storage: storage)
    }

    private func survivors(_ store: DiskPageStore, _ ids: [String]) async -> [String] {
        var kept: [String] = []
        for id in ids where await FeedSeeding.hasManifest(store, feedID: id) { kept.append(id) }
        return kept
    }

    /// Seeds `count` equal-sized feeds, oldest first, and returns their IDs and the size of one.
    private func seedEqualFeeds(_ store: DiskPageStore, count: Int, limitInFeeds: Double) async -> (ids: [String], one: Int) {
        let ids = (0..<count).map { "feed-\($0)" }
        for (index, id) in ids.enumerated() {
            await seed(store, id, age: TimeInterval((count - index) * 60))
        }
        let one = await FeedSeeding.totalBytes(store) / count
        let limit = Int(Double(one) * limitInFeeds)
        for (index, id) in ids.enumerated() {
            await seed(store, id, age: TimeInterval((count - index) * 60), limit: limit)
        }
        return (ids, one)
    }

    @Test func sweepDeletesLeastRecentFeedsToEightyPercent() async {
        let store = store
        let (ids, _) = await seedEqualFeeds(store, count: 5, limitInFeeds: 4.5)

        await maintenance.sweep(store: store, evictsBySize: true)

        #expect(await survivors(store, ids) == ["feed-2", "feed-3", "feed-4"])
    }

    @Test func sweepStopsOnceUnderTheTarget() async {
        let store = store
        let (ids, _) = await seedEqualFeeds(store, count: 3, limitInFeeds: 2.8)

        await maintenance.sweep(store: store, evictsBySize: true)

        #expect(await survivors(store, ids) == ["feed-1", "feed-2"])
    }

    @Test func sweepLeavesAFolderUnderTheLimitAlone() async {
        let store = store
        let (ids, _) = await seedEqualFeeds(store, count: 3, limitInFeeds: 3.5)

        await maintenance.sweep(store: store, evictsBySize: true)

        #expect(await survivors(store, ids) == ids)
    }

    @Test func feedsExpireByTheirOwnMaxAge() async {
        let store = store
        let twoDays: TimeInterval = 2 * 86_400
        await seed(store, "short", age: twoDays, maxAge: 3_600)
        await seed(store, "long", age: twoDays, maxAge: 30 * 86_400)

        await maintenance.sweep(store: store, evictsBySize: true)

        #expect(await survivors(store, ["short", "long"]) == ["long"])
    }

    @Test func durableFeedsAreNotEvictedBySize() async {
        let store = store
        let (ids, _) = await seedEqualFeeds(store, count: 5, limitInFeeds: 2)

        await maintenance.sweep(store: store, evictsBySize: false)

        #expect(await survivors(store, ids) == ids)
    }

    @Test func durableFeedsStillExpireByAge() async {
        let store = store
        await seed(store, "old", age: 2 * 86_400, maxAge: 3_600, storage: .durable)
        await seed(store, "fresh", age: 60, storage: .durable)

        await maintenance.sweep(store: store, evictsBySize: false)

        #expect(await survivors(store, ["old", "fresh"]) == ["fresh"])
    }

    @Test func sizeCapIsLargestRecorded() async {
        let store = store
        await seed(store, "small-limit", age: 120, limit: 1)
        await seed(store, "large-limit", age: 60, limit: 50_000_000)

        await maintenance.sweep(store: store, evictsBySize: true)

        #expect(await survivors(store, ["small-limit", "large-limit"]) == ["small-limit", "large-limit"])
    }

    @Test func unreadableManifestFeedIsDeleted() async throws {
        let store = store
        await seed(store, "good", age: 60)
        let broken = root.appendingPathComponent(DiskPageStore.folderName(for: "broken"), isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent("manifest.json"))

        await maintenance.sweep(store: store, evictsBySize: true)

        #expect(!FileManager.default.fileExists(atPath: broken.path))
        #expect(await survivors(store, ["good"]) == ["good"])
    }
}
