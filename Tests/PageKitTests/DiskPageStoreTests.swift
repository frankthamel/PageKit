import CryptoKit
import Foundation
import Testing
@testable import PageKit

struct DiskPageStoreTests {
    private typealias TestPage = Page<TestItem, CursorToken>

    private let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageKitTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(now: @escaping @Sendable () -> Date = Date.init) -> DiskPageStore {
        DiskPageStore(root: root, now: now)
    }

    private func token(_ value: String?) -> CursorToken { CursorToken(value: value, size: 20) }

    private func makePage(_ id: Int = 1, next: String? = nil) -> TestPage {
        Page(items: [TestItem(id: id)], nextToken: next.map { token($0) })
    }

    private func makeManifest(tokens: [CursorToken], schemaVersion: Int = 1) -> FeedManifest<CursorToken> {
        FeedManifest(
            schemaVersion: schemaVersion, tokens: tokens, lastNextToken: token("next"),
            updatedAt: Date(timeIntervalSince1970: 1_000), maxAge: 3_600, diskSizeLimit: 1_000, storage: .caches
        )
    }

    private func feedFolder(_ feedID: String) -> URL {
        root.appendingPathComponent(DiskPageStore.folderName(for: feedID), isDirectory: true)
    }

    private func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func pageRoundTrips() async {
        let store = makeStore()
        let bytes = await store.save(makePage(5, next: "b"), feedID: "f", token: token("a"), schemaVersion: 1)

        let hit: TestPage? = await store.page(feedID: "f", token: token("a"), schemaVersion: 1)
        #expect(hit?.items == [TestItem(id: 5)])
        #expect(hit?.nextToken == token("b"))
        #expect(bytes > 0)
    }

    @Test func fileNameIsSHA256OfToken() async throws {
        let store = makeStore()
        let key = token("abc")
        await store.save(makePage(), feedID: "f", token: key, schemaVersion: 1)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined()
        #expect(files(in: feedFolder("f")) == ["page-\(digest).json"])
    }

    @Test func cursorWithSlashIsAValidFile() async {
        let store = makeStore()
        let key = token("a/b/../c")
        await store.save(makePage(3), feedID: "f", token: key, schemaVersion: 1)

        let hit: TestPage? = await store.page(feedID: "f", token: key, schemaVersion: 1)
        #expect(hit?.items == [TestItem(id: 3)])
        #expect(files(in: feedFolder("f")).count == 1)
    }

    @Test func offlineLaunchReadsManifestAfterNewStoreInstance() async {
        let manifest = makeManifest(tokens: [token(nil), token("a")])
        await makeStore().saveManifest(manifest, feedID: "f")

        let loaded = await makeStore().manifest(feedID: "f", as: CursorToken.self, schemaVersion: 1)
        #expect(loaded?.tokens == manifest.tokens)
        #expect(loaded?.lastNextToken == token("next"))
        #expect(loaded?.maxAge == 3_600)
        #expect(loaded?.storage == .caches)
    }

    @Test func schemaMismatchDeletesTheFeed() async {
        let store = makeStore()
        await store.saveManifest(makeManifest(tokens: [token("a")], schemaVersion: 1), feedID: "f")
        await store.save(makePage(), feedID: "f", token: token("a"), schemaVersion: 1)

        let loaded = await store.manifest(feedID: "f", as: CursorToken.self, schemaVersion: 2)
        #expect(loaded == nil)
        #expect(!FileManager.default.fileExists(atPath: feedFolder("f").path))
    }

    @Test func corruptPageIsDeletedAndIsAMiss() async throws {
        let store = makeStore()
        await store.save(makePage(), feedID: "f", token: token("a"), schemaVersion: 1)
        let file = try #require(files(in: feedFolder("f")).first)
        let url = feedFolder("f").appendingPathComponent(file)
        try Data("{ truncated".utf8).write(to: url)

        let hit: TestPage? = await store.page(feedID: "f", token: token("a"), schemaVersion: 1)
        #expect(hit == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func corruptManifestIsDeletedAndIsAMiss() async throws {
        let store = makeStore()
        await store.saveManifest(makeManifest(tokens: [token("a")]), feedID: "f")
        let url = feedFolder("f").appendingPathComponent("manifest.json")
        try Data("not json".utf8).write(to: url)

        let loaded = await store.manifest(feedID: "f", as: CursorToken.self, schemaVersion: 1)
        #expect(loaded == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func feedNamesWithSlashesAndUnicodeStayDistinct() async {
        let store = makeStore()
        let feeds = ["search.a/b", "search.a b", "search.日本"]
        for feed in feeds {
            await store.save(makePage(), feedID: feed, token: token("a"), schemaVersion: 1)
        }

        let folders = Set(feeds.map { DiskPageStore.folderName(for: $0) })
        #expect(folders.count == 3)
        #expect(Set(files(in: root)) == folders)
        for feed in feeds {
            #expect(!DiskPageStore.folderName(for: feed).contains("/"))
        }
    }

    @Test func longFeedNamesAreShortenedAndStayDistinct() {
        let a = String(repeating: "x", count: 300) + "a"
        let b = String(repeating: "x", count: 300) + "b"
        let nameA = DiskPageStore.folderName(for: a)
        #expect(nameA.utf8.count <= 200)
        #expect(nameA != DiskPageStore.folderName(for: b))
    }

    @Test func dotOnlyFeedNamesCannotEscapeTheRoot() {
        #expect(DiskPageStore.folderName(for: "..") != "..")
        #expect(DiskPageStore.folderName(for: ".") != ".")
    }

    @Test func durableRootIsExcludedFromBackup() async throws {
        let store = makeStore()
        await store.save(makePage(), feedID: "f", token: token("a"), schemaVersion: 1)

        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func removePagesKeepsTheNamedTokens() async {
        let store = makeStore()
        for value in ["a", "b", "c"] {
            await store.save(makePage(), feedID: "f", token: token(value), schemaVersion: 1)
        }
        await store.saveManifest(makeManifest(tokens: [token("a")]), feedID: "f")

        await store.removePages(feedID: "f", except: [token("b")])

        let kept: TestPage? = await store.page(feedID: "f", token: token("b"), schemaVersion: 1)
        let gone: TestPage? = await store.page(feedID: "f", token: token("a"), schemaVersion: 1)
        #expect(kept != nil)
        #expect(gone == nil)
        #expect(files(in: feedFolder("f")).contains("manifest.json"))
    }

    @Test func removeFeedAndRemoveAllDeleteFolders() async {
        let store = makeStore()
        await store.save(makePage(), feedID: "f", token: token("a"), schemaVersion: 1)
        await store.save(makePage(), feedID: "g", token: token("a"), schemaVersion: 1)

        await store.removeFeed("f")
        #expect(!FileManager.default.fileExists(atPath: feedFolder("f").path))
        #expect(FileManager.default.fileExists(atPath: feedFolder("g").path))

        await store.removeAll()
        #expect(files(in: root).isEmpty)
    }

    @Test func writesLeaveNoTemporaryFiles() async {
        let store = makeStore()
        await store.saveManifest(makeManifest(tokens: [token("a")]), feedID: "f")
        for value in ["a", "b", "c"] {
            await store.save(makePage(), feedID: "f", token: token(value), schemaVersion: 1)
        }

        let names = files(in: feedFolder("f"))
        #expect(names.count == 4)
        #expect(names.allSatisfy { $0 == "manifest.json" || ($0.hasPrefix("page-") && $0.hasSuffix(".json")) })
    }

    @Test func storedAtComesFromTheInjectedClock() async throws {
        let moment = Date(timeIntervalSince1970: 5_000)
        let store = makeStore(now: { moment })
        await store.save(makePage(), feedID: "f", token: token("a"), schemaVersion: 1)

        let file = try #require(files(in: feedFolder("f")).first)
        let data = try Data(contentsOf: feedFolder("f").appendingPathComponent(file))
        let stored = try JSONDecoder().decode(StoredPage<TestItem, CursorToken>.self, from: data)
        #expect(stored.storedAt == moment)
    }
}
