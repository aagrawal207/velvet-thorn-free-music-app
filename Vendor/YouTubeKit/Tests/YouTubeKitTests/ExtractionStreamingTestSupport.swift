import Foundation
import XCTest
@testable import YouTubeKit

final class ExtractionTestStream: @unchecked Sendable {
    let path: String
    private let queue = DispatchQueue(label: "YouTubeKitTests.streaming")
    private var loading: ExtractionStreamingProtocol?
    private var captured: URLRequest?
    private var finished = false
    private var stops = 0
    private var bytes = 0
    private var chunks = 0

    init(path: String = "/\(UUID().uuidString)") { self.path = path }

    var request: URLRequest { URLRequest(url: URL(string: "https://www.youtube.com\(path)")!) }
    var recordedRequest: URLRequest? { queue.sync { captured } }
    var cancellations: Int { queue.sync { stops } }
    var didFinish: Bool { queue.sync { finished } }
    var deliveredBytes: Int { queue.sync { bytes } }
    var deliveredChunks: Int { queue.sync { chunks } }

    func start(_ loading: ExtractionStreamingProtocol) {
        queue.async {
            self.loading = loading
            self.captured = loading.request
        }
    }

    func stop() {
        queue.async {
            if self.loading != nil, !self.finished { self.stops += 1 }
            self.loading = nil
        }
    }

    @discardableResult
    func respond(status: Int = 200, expectedLength: Int64? = nil) -> Bool {
        queue.sync {
            guard let loading, let url = loading.request.url else { return false }
            var headers = ["Content-Type": "application/octet-stream", "X-Streaming-Fixture": "preserved"]
            if let expectedLength { headers["Content-Length"] = String(expectedLength) }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            loading.client?.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
            return true
        }
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        queue.sync {
            guard let loading else { return false }
            bytes += data.count
            chunks += 1
            loading.client?.urlProtocol(loading, didLoad: data)
            return true
        }
    }

    @discardableResult
    func finish(error: URLError? = nil) -> Bool {
        queue.sync {
            guard let loading else { return false }
            finished = true
            self.loading = nil
            if let error { loading.client?.urlProtocol(loading, didFailWithError: error) }
            else { loading.client?.urlProtocolDidFinishLoading(loading) }
            return true
        }
    }

    func complete(_ data: Data) {
        respond(expectedLength: Int64(data.count))
        send(data)
        finish()
    }
}

fileprivate final class ExtractionStreamingRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: [String: [ExtractionTestStream]]] = [:]

    func register(_ streams: [ExtractionTestStream], id: String) {
        lock.withLock { routes[id] = Dictionary(grouping: streams, by: \.path) }
    }
    func remove(_ id: String) { _ = lock.withLock { routes.removeValue(forKey: id) } }
    func take(_ request: URLRequest) -> ExtractionTestStream? {
        guard let id = request.value(forHTTPHeaderField: "X-Extraction-Streaming-Test"), let path = request.url?.path else { return nil }
        return lock.withLock {
            guard let stream = routes[id]?[path]?.first else { return nil }
            routes[id]?[path]?.removeFirst()
            return stream
        }
    }
}

final class ExtractionStreamingProtocol: URLProtocol, @unchecked Sendable {
    fileprivate static let registry = ExtractionStreamingRegistry()
    private let lock = NSLock()
    private var stream: ExtractionTestStream?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let stream = Self.registry.take(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        lock.withLock { self.stream = stream }
        stream.start(self)
    }
    override func stopLoading() {
        let stream = lock.withLock {
            let stream = self.stream
            self.stream = nil
            return stream
        }
        stream?.stop()
    }
}

@available(iOS 15.0, watchOS 8.0, tvOS 15.0, macOS 12.0, *)
@MainActor
class ExtractionStreamingTestCase: XCTestCase {
    func makeSession(_ streams: [ExtractionTestStream], ordinarySession: Bool = false) -> URLSession {
        let id = UUID().uuidString
        ExtractionStreamingProtocol.registry.register(streams, id: id)
        let configuration = ExtractionTransport.configuration()
        configuration.protocolClasses = [ExtractionStreamingProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Extraction-Streaming-Test": id, "X-Fixture-Configuration": "preserved"]
        let session = ordinarySession ? URLSession(configuration: configuration) : ExtractionTransport.makeSession(configuration: configuration)
        addTeardownBlock {
            session.invalidateAndCancel()
            ExtractionStreamingProtocol.registry.remove(id)
        }
        return session
    }

    func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("The streaming fixture did not reach the expected state")
                throw URLError(.timedOut)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func start<Value: Sendable>(_ stream: ExtractionTestStream,
                               operation: @escaping @MainActor () async throws -> Value) async throws -> Task<Value, Error> {
        let work = Task { try await operation() }
        addTeardownBlock { work.cancel() }
        try await eventually { stream.recordedRequest != nil }
        return work
    }

    func start(_ stream: ExtractionTestStream, session: URLSession, limit: Int = 8,
               timeout: TimeInterval = 5) async throws -> Task<(Data, URLResponse), Error> {
        try await start(stream) {
            try await ExtractionTransport.data(for: stream.request, budget: .init(maximumBytes: limit, timeout: timeout), session: session)
        }
    }

    func assertOversized<Value: Sendable>(_ work: Task<Value, Error>, stream: ExtractionTestStream) async throws {
        try await eventually { stream.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected a receipt-time size rejection") }
        catch { XCTAssertEqual(error as? ExtractionTransportError, .responseTooLarge) }
        XCTAssertFalse(stream.didFinish)
        XCTAssertFalse(stream.send(Data([1])))
    }
}
