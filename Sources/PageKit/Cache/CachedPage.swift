import Foundation

/// The part of a cached page that does not depend on its types.
///
/// NSCache's eviction callback hands over the object, not the key, so every
/// entry remembers its own feed and key. Being non-generic lets the shared
/// cache read them without knowing what the page holds.
class CachedEntry {
    let feedID: String
    let key: NSString

    init(key: PageKey) {
        self.feedID = key.feedID
        self.key = key.nsKey
    }
}

/// A page boxed in a class, because NSCache only stores reference types.
final class CachedPage<Item: Sendable, Token: PageToken>: CachedEntry {
    let page: Page<Item, Token>

    init(page: Page<Item, Token>, key: PageKey) {
        self.page = page
        super.init(key: key)
    }
}
