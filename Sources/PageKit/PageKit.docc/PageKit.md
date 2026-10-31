# ``PageKit``

Paginate any list with one small type. PageKit handles retries, caching, offline reading and prefetching.

## Overview

You write a ``PageSource`` that fetches one page. A ``Paginator`` does the rest and sends your UI a ``PaginationSnapshot`` whenever anything changes. PageKit has no UI code and no dependencies, so it works the same behind SwiftUI, UIKit, AppKit, a widget or a command-line tool.

```swift
let paginator = Paginator(source: ProductsSource(api: .live))
await paginator.start()
for await snapshot in paginator.snapshots() {
    print(snapshot.items.count, snapshot.state)
}
```

The list is always in exactly one ``PaginationState``, and only `.loaded(hasMore: true)` can start the next page. That single rule prevents double loads, loads after the end, and retry storms.

## Topics

### Essentials

- <doc:BuildingAPaginatedList>
- ``PageSource``
- ``Page``
- ``Paginator``
- ``PaginationSnapshot``
- ``PaginationState``

### Articles

- <doc:ChoosingACachePolicy>
- <doc:IndexVsCursor>
- <doc:OfflineMode>
- <doc:MigratingFromYourOwnPagination>

### Tokens

- ``PageToken``
- ``IndexToken``
- ``CursorToken``

### Ready-made sources

- ``URLSessionPageSource``

### Configuration

- ``PaginationConfiguration``
- ``CachePolicy``
- ``DiskStorage``
- ``RetryPolicy``

### Errors

- ``PaginationError``
- ``PageKitHTTPError``

### Connectivity

- ``ConnectivityMonitoring``
- ``ConnectivityStatus``
- ``NetworkPathMonitor``

### Clearing and maintenance

- ``PageKit/PageKit``
