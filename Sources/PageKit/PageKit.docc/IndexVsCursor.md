# Index vs cursor

Choose the token that matches your API.

## Overview

A ``PageToken`` names one page. The engine never looks inside it. It stores it, uses it as a cache key, saves it to disk and hands it back to your ``PageSource``. So one engine drives every kind of API, and a feed only differs in its token.

### Index tokens

Use ``IndexToken`` for APIs that take a page number or an offset. The client works out the next page with ``IndexToken/next``, and ``IndexToken/offset`` gives the skip value.

```swift
struct OrdersSource: PageSource {
    let api: APIClient
    let feedID = "orders.history"
    let firstToken = IndexToken.first(size: 20)

    func loadPage(_ token: IndexToken) async throws -> Page<Product, IndexToken> {
        let response = try await api.products(page: token.page, limit: token.size)
        let hasMore = token.page < response.totalPages
        return Page(items: response.products, nextToken: hasMore ? token.next : nil)
    }
}
```

Index APIs are simple, but rows shift when items are added or removed. PageKit removes the duplicates this causes, by ID, so the list stays unique. It can't recover an item that shifted back past a page boundary. If that matters, prefer cursors.

### Cursor tokens

Use ``CursorToken`` when the server hands back the next cursor with each page. The list stays stable as items change, which suits timelines.

```swift
struct NotificationsSource: PageSource {
    let api: APIClient
    let feedID = "notifications"
    let firstToken = CursorToken(value: nil, size: 20)

    func loadPage(_ token: CursorToken) async throws -> Page<Post, CursorToken> {
        let response = try await api.timeline(after: token.value, limit: token.size)
        return Page(
            items: response.posts,
            nextToken: response.nextCursor.map { CursorToken(value: $0, size: token.size) }
        )
    }
}
```

### Custom tokens

Anything else the server needs to continue the list goes in your own token, such as a filter. It is cached and restored with the page.

```swift
struct FilteredToken: PageToken {
    let after: String?
    let status: String
    let size: Int
}
```

### Reading ahead

``PageToken/predictedNext`` says whether a token can name its successor without asking the server. ``IndexToken`` can, so it reads ahead in parallel. Cursors can't, because the next cursor only arrives with the current page, so a cursor feed reads ahead one page at a time. The default is `nil`.

## See Also

- ``PageToken``
- ``PageSource``
