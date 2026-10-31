import Foundation

/// A `URLProtocol` that answers requests from a closure, so tests need no server.
///
/// Each stub gets its own host, so tests running in parallel never see each other's requests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (URLResponse, Data)

    private static let handlers = Handlers()

    /// A session whose requests are answered by `handler`, and a URL on the host it answers for.
    static func stub(_ handler: @escaping Handler) -> (session: URLSession, url: URL) {
        let host = "\(UUID().uuidString.lowercased()).stub"
        handlers.set(handler, for: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return (URLSession(configuration: configuration), URL(string: "https://\(host)/items")!)
    }

    /// A successful JSON answer for `request`.
    static func ok(_ json: String, for request: URLRequest, status: Int = 200, headers: [String: String] = [:]) -> (URLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (response, Data(json.utf8))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host, let handler = Self.handlers.handler(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private final class Handlers: @unchecked Sendable {
        private let lock = NSLock()
        private var byHost: [String: Handler] = [:]

        func set(_ handler: @escaping Handler, for host: String) {
            lock.lock(); defer { lock.unlock() }
            byHost[host] = handler
        }

        func handler(for host: String) -> Handler? {
            lock.lock(); defer { lock.unlock() }
            return byHost[host]
        }
    }
}
