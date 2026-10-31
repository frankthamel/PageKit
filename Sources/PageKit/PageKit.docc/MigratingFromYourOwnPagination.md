# Migrating from your own pagination code

Replace a hand-written pager one screen at a time.

## Overview

PageKit takes over the code around your network call. Your API client and your views can stay. Move one screen first, since each ``Paginator`` stands alone.

### Step 1: Wrap your API call in a source

Your existing fetch becomes ``PageSource/loadPage(_:)``. Move the logic that decides whether there's another page into the returned ``Page``: a `nil` next token ends the list. Your items must be `Identifiable`, `Codable` and `Sendable`.

Give each list a stable, unique ``PageSource/feedID``. It is the cache key, so include anything that makes the list different, such as a search query.

### Step 2: Delete what the paginator now owns

Replace your own versions of these:

| Your code | With PageKit |
| --- | --- |
| `isLoading`, `hasMore` and `error` flags | ``PaginationSnapshot/state`` |
| `page += 1` | ``IndexToken/next`` or a ``CursorToken`` |
| Appending and de-duplicating | ``PaginationSnapshot/items`` |
| "Am I near the end?" checks | ``Paginator/itemAppeared(id:)`` |
| Retry loops | ``PaginationConfiguration/retry`` |
| Your own cache | ``PaginationConfiguration/cachePolicy`` |

### Step 3: Keep one property

Store the whole snapshot in one property, and read everything from it. Separate copies of `items` and `state` cause two renders per page.

### Step 4: Watch for these changes in behaviour

- **Cancelling a caller aborts its load.** SwiftUI's `.refreshable` can cancel its task when the view re-renders, so call ``Paginator/refresh()`` from a task that outlives a re-render, such as `await Task { await paginator.refresh() }.value`.
- **A failed refresh keeps the list.** The state returns to `.loaded`, and the error is in ``PaginationSnapshot/lastError``. Show it quietly rather than as a full-screen error.
- **Tell the server before you edit the list.** Call ``Paginator/remove(id:)`` and ``Paginator/update(_:)`` after the server confirms, because a page requested afterwards is believed.
- **Cached items can show first.** Read ``PaginationSnapshot/isStale`` if the user needs to know. Use ``CachePolicy/networkOnly`` where they must never see old data.
- **Logging out takes a wipe.** Call ``PageKit/PageKit/clearAll()``, and wait for it before you move on.
- **``Paginator/cancel()`` is final.** Make a new paginator to show the feed again.

## See Also

- <doc:IndexVsCursor>
- <doc:ChoosingACachePolicy>
