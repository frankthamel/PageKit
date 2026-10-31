import CryptoKit
import Foundation

/// Keeps pages and feed manifests on disk as plain JSON files.
///
/// Layout: `<root>/<feed folder>/manifest.json` plus one `page-<sha256>.json`
/// per page. Being an actor, it serialises every read and write, so a feed's
/// folder is never touched by two operations at once.
///
/// A broken cache must never crash the app or block the network, so a file that
/// cannot be decoded is deleted and reported as a miss, and write failures are
/// logged and otherwise ignored.
actor DiskPageStore {
    private static let manifestFileName = "manifest.json"
    private static let maxFolderNameBytes = 200
    private static let allowedFolderCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_"
    )

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedStores: [DiskStorage: DiskPageStore] = [:]

    private let root: URL
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default

    /// Creates a store.
    /// - Parameters:
    ///   - root: The folder that holds one sub-folder per feed.
    ///   - now: The clock used to stamp pages. Tests pass a fixed one.
    init(root: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.root = root
        self.now = now
    }

    /// The store for a storage location, created once and then reused.
    ///
    /// `.caches` lives in `Library/Caches/PageKit` and `.durable` in
    /// `Library/Application Support/PageKit`.
    static func shared(for storage: DiskStorage) -> DiskPageStore {
        sharedLock.withLock {
            if let store = sharedStores[storage] { return store }
            let directory: FileManager.SearchPathDirectory = storage == .caches ? .cachesDirectory : .applicationSupportDirectory
            let base = FileManager.default.urls(for: directory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let store = DiskPageStore(root: base.appendingPathComponent("PageKit", isDirectory: true))
            sharedStores[storage] = store
            return store
        }
    }

    /// A folder name that is legal on disk and unique for the feed ID.
    ///
    /// Everything except lowercase letters, digits, `.`, `-` and `_` is
    /// percent-encoded, so IDs that differ only by case stay distinct on
    /// case-insensitive filesystems. A literal `%` is encoded as `%25`, so a raw
    /// `%` only ever starts an uppercase-hex escape and escapes cannot collide.
    /// Names over 200 bytes are cut short and prefixed with a hash of the whole
    /// ID, so two long IDs that share a start still differ.
    nonisolated static func folderName(for feedID: String) -> String {
        var name = feedID.addingPercentEncoding(withAllowedCharacters: allowedFolderCharacters) ?? ""
        // "." and ".." would name the folder itself or its parent.
        if name.allSatisfy({ $0 == "." }) { name = name.replacingOccurrences(of: ".", with: "%2E") }
        guard name.utf8.count > maxFolderNameBytes else { return name }
        let prefix = String(hex(SHA256.hash(data: Data(feedID.utf8))).prefix(16)) + "-"
        // The name is ASCII after encoding, so cutting by characters cuts by bytes.
        return prefix + String(name.prefix(maxFolderNameBytes - prefix.count))
    }

    // MARK: Manifest

    /// The saved manifest of a feed, or `nil` when there is none.
    ///
    /// A manifest from another schema version deletes the whole feed, and an
    /// unreadable one does the same, because its pages can no longer be trusted.
    func manifest<Token: PageToken>(feedID: String, as type: Token.Type, schemaVersion: Int) -> FeedManifest<Token>? {
        let url = manifestURL(feedID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let manifest = try? decoder.decode(FeedManifest<Token>.self, from: data),
              manifest.schemaVersion == schemaVersion else {
            removeFeed(feedID)
            return nil
        }
        return manifest
    }

    /// Writes a feed's manifest, replacing any earlier one.
    func saveManifest<Token: PageToken>(_ manifest: FeedManifest<Token>, feedID: String) {
        write(manifest, to: manifestURL(feedID), feedID: feedID)
    }

    // MARK: Pages

    /// The saved page for a token, or `nil` on a miss.
    ///
    /// An unreadable file is deleted. A page from another schema version deletes the whole feed.
    func page<Item: Codable & Sendable, Token: PageToken>(
        feedID: String, token: Token, schemaVersion: Int
    ) -> Page<Item, Token>? {
        guard let url = pageURL(feedID, token), let data = try? Data(contentsOf: url) else { return nil }
        guard let stored = try? decoder.decode(StoredPage<Item, Token>.self, from: data) else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        guard stored.schemaVersion == schemaVersion else {
            removeFeed(feedID)
            return nil
        }
        return Page(items: stored.items, nextToken: stored.nextToken)
    }

    /// Writes a page and returns its size in bytes, which the memory cache uses as its cost.
    @discardableResult
    func save<Item: Codable & Sendable, Token: PageToken>(
        _ page: Page<Item, Token>, feedID: String, token: Token, schemaVersion: Int
    ) -> Int {
        let stored = StoredPage(schemaVersion: schemaVersion, storedAt: now(), items: page.items, nextToken: page.nextToken)
        guard let url = pageURL(feedID, token) else { return 0 }
        return write(stored, to: url, feedID: feedID)
    }

    /// Writes a page and the manifest that lists it, in one turn of this actor.
    ///
    /// Maintenance deletes any folder with no manifest, so nothing may run between the
    /// two. The page goes first: a crash between them leaves a feed with no manifest,
    /// which is swept, rather than a manifest that promises a page it does not have.
    func save<Item: Codable & Sendable, Token: PageToken>(
        _ page: Page<Item, Token>, manifest: FeedManifest<Token>, feedID: String, token: Token, schemaVersion: Int
    ) {
        save(page, feedID: feedID, token: token, schemaVersion: schemaVersion)
        saveManifest(manifest, feedID: feedID)
    }

    /// Deletes every page of a feed except those for `tokens`. The manifest stays.
    func removePages<Token: PageToken>(feedID: String, except tokens: [Token]) {
        let kept = Set(tokens.compactMap { pageURL(feedID, $0)?.lastPathComponent })
        let folder = feedFolder(feedID)
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("page-") && !kept.contains(name) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: Listing

    /// A feed folder as found on disk.
    struct StoredFeed: Sendable {
        /// The folder's name under the root.
        let folder: String
        /// The total size of the files in the folder.
        let bytes: Int
        /// The manifest's header, or `nil` when it is missing or unreadable.
        let header: FeedManifestHeader?
    }

    /// Every feed folder under the root, for disk maintenance.
    func storedFeeds() -> [StoredFeed] {
        let folders = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return folders.map { name in
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let files = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            let bytes = files.reduce(0) { total, file in
                let attributes = try? fileManager.attributesOfItem(atPath: folder.appendingPathComponent(file).path)
                return total + ((attributes?[.size] as? Int) ?? 0)
            }
            let manifest = try? Data(contentsOf: folder.appendingPathComponent(Self.manifestFileName))
            return StoredFeed(folder: name, bytes: bytes, header: manifest.flatMap { try? decoder.decode(FeedManifestHeader.self, from: $0) })
        }
    }

    // MARK: Removal

    /// Deletes everything stored for one feed.
    func removeFeed(_ feedID: String) {
        try? fileManager.removeItem(at: feedFolder(feedID))
    }

    /// Deletes one feed folder by its name on disk. Used by maintenance, which cannot recover feed IDs from folder names.
    func removeFolder(_ name: String) {
        try? fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
    }

    /// Deletes every feed under this store's root.
    func removeAll() {
        try? fileManager.removeItem(at: root)
    }

    // MARK: Files

    private var decoder: JSONDecoder { JSONDecoder() }

    private func feedFolder(_ feedID: String) -> URL {
        root.appendingPathComponent(Self.folderName(for: feedID), isDirectory: true)
    }

    private func manifestURL(_ feedID: String) -> URL {
        feedFolder(feedID).appendingPathComponent(Self.manifestFileName)
    }

    /// `page-<SHA-256 of the token's JSON>.json`. Cursors may contain `/` and
    /// other characters that are illegal in file names, a hash never does.
    private func pageURL<Token: PageToken>(_ feedID: String, _ token: Token) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(token) else { return nil }
        let name = "page-\(Self.hex(SHA256.hash(data: data))).json"
        return feedFolder(feedID).appendingPathComponent(name)
    }

    /// Encodes `value` and writes it atomically. Returns the byte count, or 0 on failure.
    @discardableResult
    private func write<Value: Encodable>(_ value: Value, to url: URL, feedID: String) -> Int {
        do {
            let data = try JSONEncoder().encode(value)
            try prepareRoot()
            try fileManager.createDirectory(at: feedFolder(feedID), withIntermediateDirectories: true)
            try data.write(to: url, options: writeOptions)
            return data.count
        } catch {
            PageKitLog.logger.error("Disk write failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Creates the root and keeps it out of backups: cached server data should not use the user's iCloud quota.
    /// The exclusion is checked on every write, so a failed attempt is retried.
    private func prepareRoot() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var rootURL = root
        if (try? rootURL.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try rootURL.setResourceValues(values)
        } catch {
            PageKitLog.logger.error("Backup exclusion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Atomic, so a crash never leaves half a file. On devices the file is also
    /// encrypted until first unlock, which background refresh can still read.
    private var writeOptions: Data.WritingOptions {
        #if os(iOS) || os(tvOS) || os(watchOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
