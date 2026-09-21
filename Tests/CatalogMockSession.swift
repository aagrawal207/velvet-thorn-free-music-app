import Foundation
@testable import GanaBajana

struct CatalogStub: Sendable {
    var status = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var data: Data
    var delay: TimeInterval = 0
    var beforeDelivery: (@Sendable () async throws -> Void)? = nil
}

final class CatalogMockState: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> CatalogStub
    private let lock = NSLock()
    private let handler: Handler
    private var recorded: [URLRequest] = []
    private var stops = 0

    init(handler: @escaping Handler) { self.handler = handler }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var cancellations: Int { lock.withLock { stops } }
    func stopped() { lock.withLock { stops += 1 } }
    func respond(to request: URLRequest) throws -> CatalogStub {
        var captured = request
        // URLSession can convert a POST body into a stream before handing it to URLProtocol.
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBodyStream = nil
            captured.httpBody = data
        }
        lock.withLock { recorded.append(captured) }
        return try handler(captured)
    }
}

private final class CatalogMockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: CatalogMockState] = [:]
    func register(_ state: CatalogMockState, id: String) { lock.withLock { states[id] = state } }
    func remove(_ id: String) { _ = lock.withLock { states.removeValue(forKey: id) } }
    func state(for request: URLRequest) -> CatalogMockState? {
        guard let id = request.value(forHTTPHeaderField: "X-GanaBajana-Catalog-Test") else { return nil }
        return lock.withLock { states[id] }
    }
}

private final class CatalogMockURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = CatalogMockRegistry()
    private let lock = NSLock()
    private var cancelled = false
    private var delivered = false
    private var work: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let state = Self.registry.state(for: request) else { throw URLError(.unsupportedURL) }
            let stub = try state.respond(to: request)
            let work = Task<Void, Never> { @Sendable [weak self, stub] in
                do {
                    try await stub.beforeDelivery?()
                    try await Task.sleep(for: .seconds(stub.delay))
                    try Task.checkCancellation()
                    self?.deliver(stub)
                } catch {
                    guard let self, !self.lock.withLock({ self.cancelled }) else { return }
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
            }
            let stopped = lock.withLock { self.work = work; return cancelled }
            if stopped { work.cancel() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func deliver(_ stub: CatalogStub) {
        guard !lock.withLock({ cancelled }), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers) else { return }
        lock.withLock { delivered = true }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession also stops a protocol after a completed load; only a stop before delivery is a cancellation.
    override func stopLoading() {
        let wasPending = lock.withLock {
            cancelled = true
            work?.cancel()
            work = nil
            return !delivered
        }
        if wasPending { Self.registry.state(for: request)?.stopped() }
    }
}

struct CatalogMockSession {
    let session: URLSession
    let state: CatalogMockState
    private let id: String

    init(handler: @escaping CatalogMockState.Handler) {
        id = UUID().uuidString
        state = CatalogMockState(handler: handler)
        CatalogMockURLProtocol.registry.register(state, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogMockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-GanaBajana-Catalog-Test": id]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func close() {
        session.invalidateAndCancel()
        CatalogMockURLProtocol.registry.remove(id)
    }
}

final class CatalogTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_789_819_200)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

final class CatalogTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

final class CatalogTestRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func record(_ value: Value) { lock.withLock { stored.append(value) } }
}

/// Routes mocked YouTube Music requests by endpoint and payload: searches by query and filter, browses by ID,
/// next (radio) by seed video ID, get_queue by the requested video IDs. Unlisted searches answer with an empty
/// page; unlisted browses and radios 404.
struct CatalogMockRouter: Sendable {
    var songs: [String: Data] = [:]
    var artists: [String: Data] = [:]
    var continuations: [String: Data] = [:]
    var browse: [String: Data] = [:]
    var next: [String: Data] = [:]
    var queue: (@Sendable ([String]) throws -> Data)?
    var artistsStatus = 200
    var queueStatus = 200

    func stub(_ request: URLRequest) throws -> CatalogStub {
        if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
        let body = try CatalogJSON.decode(request.httpBody ?? Data())
        let path = request.url?.path ?? ""
        if path.hasSuffix("/music/get_queue") {
            guard queueStatus == 200, let queue else { return CatalogStub(status: queueStatus == 200 ? 500 : queueStatus, data: Data("{}".utf8)) }
            return CatalogStub(data: try queue(body["videoIds"].array.compactMap(\.string)))
        }
        if path.hasSuffix("/browse") {
            if let token = body["continuation"].string, let data = continuations[token] { return CatalogStub(data: data) }
            guard let id = body["browseId"].string, let data = browse[id] else { return CatalogStub(status: 404, data: Data("{}".utf8)) }
            return CatalogStub(data: data)
        }
        if path.hasSuffix("/next") {
            guard let id = body["videoId"].string, let data = next[id] else { return CatalogStub(status: 404, data: Data("{}".utf8)) }
            return CatalogStub(data: data)
        }
        guard path.hasSuffix("/search") else { throw URLError(.unsupportedURL) }
        if let token = body["continuation"].string {
            return CatalogStub(data: try continuations[token] ?? CatalogFixtures.data(CatalogFixtures.search([], continued: true)))
        }
        let query = body["query"].string ?? ""
        if body["params"].string == YouTubeMusicService.searchParameters(.artists) {
            guard artistsStatus == 200 else { return CatalogStub(status: artistsStatus, data: Data("{}".utf8)) }
            return CatalogStub(data: try artists[query] ?? CatalogFixtures.data(CatalogFixtures.search([])))
        }
        return CatalogStub(data: try songs[query] ?? CatalogFixtures.data(CatalogFixtures.search([])))
    }
}
