import Foundation

/// Names one page of one feed, for use as a cache key.
struct PageKey: Hashable, Sendable {
    let feedID: String

    /// The token encoded as JSON with sorted keys, so equal tokens give equal text.
    let token: String

    init<Token: PageToken>(feedID: String, token: Token) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        self.feedID = feedID
        self.token = (try? encoder.encode(token)).map { String(decoding: $0, as: UTF8.self) }
            ?? String(describing: token)
    }

    /// The key as NSCache wants it: the feed and token joined by a separator
    /// that cannot appear in the token's JSON.
    var nsKey: NSString { "\(feedID)\u{1F}\(token)" as NSString }
}
