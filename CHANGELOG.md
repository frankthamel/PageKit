# Changelog

All notable changes to PageKit are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [semantic versioning](https://semver.org).

## [0.1.0] - 2026-10-31

The first release.

### Added

- `Paginator`, an actor that drives one list through a single `PaginationState`, and sends each change as one `PaginationSnapshot`.
- `PageSource`, `Page` and the `IndexToken`, `CursorToken` and custom `PageToken` styles.
- `URLSessionPageSource`, a ready-made source for simple JSON APIs.
- Memory and disk caching, with the `.cacheThenNetwork`, `.networkFirst`, `.networkOnly` and `.cacheOnly` policies.
- `.caches` and `.durable` disk storage, expiry by age, and eviction by size.
- Offline support: restoring saved lists, connectivity monitoring, and resuming on reconnect.
- Prefetching by distance from the end of the list, and read-ahead that parks pages in the cache.
- Local edits with `remove(id:)` and `update(_:)`, which reach the list and both caches.
- `PageKit.clear(feedID:)`, `clearAll()`, `clearMemoryCache()` and `performMaintenance()`.
- Automatic retries with backoff and jitter, and `Retry-After` support.
- Signposts for Instruments, and a privacy manifest.
- DocC articles and a tutorial.

[0.1.0]: https://github.com/frankthamel/PageKit/releases/tag/0.1.0
