import Foundation
import Testing
@testable import PageKit

@Suite(.watchdog) struct URLSessionPageSourceTests {
    private struct ArticlesResponse: Decodable, Sendable {
        let data: [TestItem]
        let next: String?
    }

    private let first = CursorToken(value: nil, size: 2)

    private func source(
        session: URLSession,
        url: URL,
        decoder: JSONDecoder = JSONDecoder()
    ) -> URLSessionPageSource<ArticlesResponse, TestItem, CursorToken> {
        URLSessionPageSource(
            feedID: "articles",
            firstToken: first,
            session: session,
            decoder: decoder,
            request: { token in
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "limit", value: "\(token.size)")]
                if let cursor = token.value { components.queryItems?.append(URLQueryItem(name: "after", value: cursor)) }
                return URLRequest(url: components.url!)
            },
            map: { (response: ArticlesResponse, token) in
                Page(items: response.data, nextToken: response.next.map { CursorToken(value: $0, size: token.size) })
            }
        )
    }

    private func failure(
        status: Int, headers: [String: String] = [:], body: String = "{}"
    ) async -> PaginationError? {
        let stub = StubURLProtocol.stub { StubURLProtocol.ok(body, for: $0, status: status, headers: headers) }
        do {
            _ = try await source(session: stub.session, url: stub.url).loadPage(first)
            return nil
        } catch {
            return ErrorClassifier.classify(error)
        }
    }

    @Test func successDecodesAndMaps() async throws {
        let stub = StubURLProtocol.stub {
            StubURLProtocol.ok(#"{"data":[{"id":1,"title":"a"},{"id":2}],"next":"c2"}"#, for: $0)
        }

        let page = try await source(session: stub.session, url: stub.url).loadPage(first)

        #expect(page.items == [TestItem(id: 1, title: "a"), TestItem(id: 2, title: nil)])
        #expect(page.nextToken == CursorToken(value: "c2", size: 2))
    }

    @Test func setsReloadIgnoringCachePolicyAndTimeout() async throws {
        let seen = Captured()
        let stub = StubURLProtocol.stub {
            seen.set($0)
            return StubURLProtocol.ok(#"{"data":[],"next":null}"#, for: $0)
        }

        _ = try await source(session: stub.session, url: stub.url).loadPage(first)

        let request = try #require(seen.value)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 15)
        #expect(request.url?.query == "limit=2")
    }

    @Test func http429CarriesRetryAfter() async {
        let error = await failure(status: 429, headers: ["Retry-After": "7"])
        #expect(error == .rateLimited(retryAfter: 7))
    }

    @Test func negativeOrNonNumericRetryAfterIsIgnored() async {
        for value in ["-5", "soon", "Wed, 21 Oct 2026 07:28:00 GMT", "nan", "inf"] {
            let error = await failure(status: 429, headers: ["Retry-After": value])
            #expect(error == .rateLimited(retryAfter: nil), "Retry-After \(value)")
        }
    }

    @Test func http503IsServerError() async {
        #expect(await failure(status: 503) == .server(status: 503))
    }

    @Test func http404IsClientError() async {
        #expect(await failure(status: 404) == .client(status: 404))
    }

    @Test func badJSONIsDecodingError() async {
        let error = await failure(status: 200, body: #"{"data":"nope"}"#)
        guard case .decoding = error else {
            Issue.record("expected a decoding error, got \(String(describing: error))")
            return
        }
    }

    @Test func nonHTTPResponseIsOtherNotACrash() async {
        let stub = StubURLProtocol.stub { request in
            (URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        do {
            _ = try await source(session: stub.session, url: stub.url).loadPage(first)
            Issue.record("expected a failure")
        } catch {
            guard case .other = ErrorClassifier.classify(error) else {
                Issue.record("expected .other, got \(error)")
                return
            }
        }
    }

    @Test func sourceWorksInsidePaginator() async {
        let stub = StubURLProtocol.stub {
            StubURLProtocol.ok(#"{"data":[{"id":1},{"id":2}],"next":null}"#, for: $0)
        }
        let paginator = Paginator.testing(source(session: stub.session, url: stub.url))

        await paginator.start()
        let snapshot = await paginator.settled()

        #expect(snapshot.items.map(\.id) == [1, 2])
        #expect(snapshot.state == .loaded(hasMore: false))
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    var value: URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
    func set(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; self.request = request }
}
