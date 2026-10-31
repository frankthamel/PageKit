import Foundation

/// The part of a manifest that disk maintenance needs.
///
/// It leaves out the tokens, so it decodes any feed's manifest whatever its `Token` type.
struct FeedManifestHeader: Decodable, Sendable {
    let updatedAt: Date
    let maxAge: TimeInterval
    let diskSizeLimit: Int
}
