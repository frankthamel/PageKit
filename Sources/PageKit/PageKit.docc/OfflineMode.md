# Offline mode

Keep a feed readable with no connection.

## Overview

Any feed that uses a cache works offline with no extra code. Pages are kept on disk as they load, and the next launch opens from them. Read ``PaginationSnapshot/isOffline`` to show a banner.

### What happens when the connection drops

``PaginationSnapshot/isOffline`` is a label. PageKit never holds a request back because of it, since a device's network status can be wrong. A failed load is reported as usual, and items on screen stay.

### What happens on reconnecting

PageKit quietly refreshes a one-page list and retries whatever failed. A longer list stays as it is, because a refresh could shrink it under the user's thumb, so ``PaginationSnapshot/isStale`` stays `true` until the next ``Paginator/refresh()``.

If the app is in the background, this waits until it returns. Tell the paginator with ``Paginator/setAppActive(_:)`` from `scenePhase`.

### Choosing where pages live

Pages go in the caches folder by default, which iOS may clear when space runs low. Apps that promise offline reading should use ``DiskStorage/durable``, and keep pages for longer:

```swift
var config = PaginationConfiguration()
config.storage = .durable
config.maxAge = 30 * 24 * 3600      // keep a month of articles
```

Durable feeds are exempt from size eviction, so ``PaginationConfiguration/diskSizeLimit`` doesn't apply to them. They still expire at ``PaginationConfiguration/maxAge``. Give users a way to clear what they no longer need, with ``PageKit/PageKit/clear(feedID:)``.

### An explicit offline mode

To stop using the network altogether, make a paginator with ``CachePolicy/cacheOnly``.

### Changing your model

Bump ``PaginationConfiguration/schemaVersion`` when an item's shape changes, and files from the old version are discarded. A corrupt file counts as a cache miss: it is deleted, and the feed loads from the network.

## See Also

- <doc:ChoosingACachePolicy>
- ``ConnectivityStatus``
