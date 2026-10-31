import Foundation

/// The record of which pages of a feed are on disk, and how to look after them.
///
/// Cursor feeds need the order because page 3's token cannot be worked out
/// without page 2's response. The limits are stored so disk maintenance works
/// with no paginator alive.
struct FeedManifest<Token: PageToken>: Codable, Sendable {
    var schemaVersion: Int
    var tokens: [Token]
    var lastNextToken: Token?
    var updatedAt: Date
    var maxAge: TimeInterval
    var diskSizeLimit: Int
    var storage: DiskStorage
}
