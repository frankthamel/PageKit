# Choosing a cache policy

Pick how a feed uses its memory and disk caches.

## Overview

Set ``PaginationConfiguration/cachePolicy`` on the configuration you give a ``Paginator``. Most feeds should keep the default, ``CachePolicy/cacheThenNetwork``.

| Policy | Opening the feed | Next page | Reads ahead |
| --- | --- | --- | --- |
| ``CachePolicy/cacheThenNetwork`` | Saved list at once, then checks page 1 | Cache, then network | Yes |
| ``CachePolicy/networkFirst`` | Network, then the saved list on failure | Network, then cache on failure | No |
| ``CachePolicy/networkOnly`` | Network | Network | No |
| ``CachePolicy/cacheOnly`` | Saved list, or `.empty` | Cache, and a miss ends the list | No |

### Cache then network

The feed opens instantly from saved pages with ``PaginationSnapshot/isStale`` set, then checks page 1 against the network. If page 1 still leads into the same pages, its items update in place and the user keeps their position. If it doesn't, the new page 1 replaces the list.

This is the only policy that reads ahead, because it is the only one that uses both a network to fetch a page and a next load that looks in the cache first.

### Network first

Use this when fresh data matters but stale data beats an error, as with search. Each load goes to the network. If the first page fails, the saved list appears with ``PaginationSnapshot/lastError`` set. If a next page fails, its cached copy is used.

```swift
var config = PaginationConfiguration()
config.cachePolicy = .networkFirst
config.maxAge = 60 * 60     // search results go stale fast
```

Reading ahead would fetch each page twice, since the next load goes to the network anyway, so this policy doesn't.

### Network only

Nothing is read from or written to a cache, which suits prices and stock levels.

### Cache only

The network is never used, which suits an explicit offline mode. ``Paginator/refresh()`` does nothing. A next page that isn't cached ends the list, and a feed with nothing saved is `.empty`.

## See Also

- <doc:OfflineMode>
- ``PaginationConfiguration``
