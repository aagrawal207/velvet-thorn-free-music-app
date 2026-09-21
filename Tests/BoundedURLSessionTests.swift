import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class BoundedURLSessionTests: XCTestCase {
    func testInvalidLimitsDoNotStartARequest() async throws {
        let stream = BoundedTestStream()
        let session = makeSession(stream)
        for limit in [Int.min, -1, 0, 64 * 1024 * 1024 + 1, Int.max] {
            do {
                _ = try await session.boundedData(for: stream.request, maximumBytes: limit)
                XCTFail("Expected an invalid limit")
            } catch { XCTAssertEqual(error as? BoundedResponseError, .invalidLimit) }
        }
        XCTAssertNil(stream.recordedRequest)
    }

    func testMinimumAndMaximumLimitsAcceptSmallBodies() async throws {
        for limit in [1, 64 * 1024 * 1024] {
            let stream = BoundedTestStream()
            let session = makeSession(stream)
            let work = try await start(stream, on: session, limit: limit)
            XCTAssertTrue(stream.respond(expectedLength: 1))
            XCTAssertTrue(stream.send(Data([0xFF])))
            XCTAssertTrue(stream.finish())
            let (data, _) = try await work.value
            XCTAssertEqual(data, Data([0xFF]))
        }
    }

    func testDeclaredOversizeCancelsBeforeReceivingAnyBody() async throws {
        for length in [Int64(9), Int64.max] {
            let stream = BoundedTestStream()
            let session = makeSession(stream)
            let work = try await start(stream, on: session, limit: 8)
            XCTAssertTrue(stream.respond(expectedLength: length))
            try await PlaybackTestSupport.eventually(timeout: 2) { stream.cancellations == 1 }
            do { _ = try await work.value; XCTFail("Expected a declared oversize error") }
            catch { XCTAssertEqual(error as? BoundedResponseError, .tooLarge) }
            XCTAssertEqual(stream.deliveredBytes, 0)
            XCTAssertFalse(stream.didFinish)
            XCTAssertFalse(stream.send(Data([1])))
        }
    }

    func testUnknownLengthChunksCancelOnOverflowWithoutWaitingForEOF() async throws {
        let stream = BoundedTestStream()
        let session = makeSession(stream)
        let work = try await start(stream, on: session, limit: 8)
        XCTAssertTrue(stream.respond())
        XCTAssertTrue(stream.send(Data([1, 2, 3])))
        XCTAssertTrue(stream.send(Data([4, 5, 6, 7, 8])))
        XCTAssertTrue(stream.send(Data([9])))
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected an actual-byte oversize error") }
        catch { XCTAssertEqual(error as? BoundedResponseError, .tooLarge) }
        XCTAssertEqual(stream.deliveredChunks, 3)
        XCTAssertEqual(stream.deliveredBytes, 9)
        XCTAssertFalse(stream.didFinish)
        XCTAssertFalse(stream.send(Data(repeating: 10, count: 32)))
        XCTAssertEqual(stream.deliveredBytes, 9)
    }

    func testActualByteLimitDoesNotTrustASmallerDeclaredLength() async throws {
        let stream = BoundedTestStream()
        let session = makeSession(stream)
        let work = try await start(stream, on: session, limit: 8)
        XCTAssertTrue(stream.respond(expectedLength: 1))
        XCTAssertTrue(stream.send(Data(repeating: 7, count: 9)))
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected an actual-byte oversize error") }
        catch { XCTAssertEqual(error as? BoundedResponseError, .tooLarge) }
        XCTAssertFalse(stream.didFinish)
    }

    func testExactBoundaryRoundTripsWithKnownAndUnknownLength() async throws {
        let body = Data([0, 1, 0x80, 0xFF, 4, 5, 6, 7])
        let lengths: [Int64?] = [8, nil]
        for length in lengths {
            let stream = BoundedTestStream()
            let session = makeSession(stream)
            let work = try await start(stream, on: session, limit: body.count)
            XCTAssertTrue(stream.respond(expectedLength: length))
            XCTAssertTrue(stream.send(body.prefix(3)))
            XCTAssertTrue(stream.send(body.dropFirst(3)))
            XCTAssertTrue(stream.finish())
            let (data, response) = try await work.value
            XCTAssertEqual(data, body)
            XCTAssertEqual(response.expectedContentLength, length ?? -1)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(stream.cancellations, 0)
        }
    }

    func testEmptyAndErrorHTTPStatusesAreReturnedToTheCaller() async throws {
        for (status, body) in [(204, Data()), (403, Data("denied".utf8))] {
            let stream = BoundedTestStream()
            let session = makeSession(stream)
            let work = try await start(stream, on: session, limit: 16)
            XCTAssertTrue(stream.respond(status: status, expectedLength: Int64(body.count)))
            if !body.isEmpty { XCTAssertTrue(stream.send(body)) }
            XCTAssertTrue(stream.finish())
            let (data, response) = try await work.value
            XCTAssertEqual(data, body)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Bounded-Response"), "preserved")
        }
    }

    func testSuccessfulEOFDoesNotRequireDeclaredLengthEquality() async throws {
        let stream = BoundedTestStream()
        let session = makeSession(stream)
        let work = try await start(stream, on: session, limit: 8)
        XCTAssertTrue(stream.respond(expectedLength: 8))
        XCTAssertTrue(stream.send(Data("short".utf8)))
        XCTAssertTrue(stream.finish())
        let (data, response) = try await work.value
        XCTAssertEqual(data, Data("short".utf8))
        XCTAssertEqual(response.expectedContentLength, 8)
    }

    func testTransportFailureDoesNotReturnPartialDataOrBecomeCancellation() async throws {
        for code in [URLError.Code.networkConnectionLost, .timedOut] {
            let stream = BoundedTestStream()
            let session = makeSession(stream)
            let work = try await start(stream, on: session, limit: 8)
            XCTAssertTrue(stream.respond(expectedLength: 8))
            XCTAssertTrue(stream.send(Data("part".utf8)))
            XCTAssertTrue(stream.finish(error: URLError(code)))
            do { _ = try await work.value; XCTFail("Expected the transport failure") }
            catch { XCTAssertEqual((error as? URLError)?.code, code) }
        }
    }

    func testNativeCancelledErrorIsNormalized() async throws {
        let stream = BoundedTestStream()
        let session = makeSession(stream)
        let work = try await start(stream, on: session, limit: 8)
        XCTAssertTrue(stream.respond())
        XCTAssertTrue(stream.finish(error: URLError(.cancelled)))
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(work.isCancelled)
    }

    func testAlreadyCancelledCallerDoesNotStartARequest() async throws {
        let stream = BoundedTestStream()
        let session = makeSession(stream)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.boundedData(for: stream.request, maximumBytes: 8)
        }
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(stream.recordedRequest)
    }

    func testCallerCancellationBeforeHeadersStopsTheRequest() async throws {
        let stream = BoundedTestStream()
        let session = makeSession(stream)
        let work = try await start(stream, on: session, limit: 8)
        work.cancel()
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(stream.respond())
        XCTAssertFalse(stream.didFinish)
    }

    func testCallerCancellationStopsAnUnknownLengthBodyWaitingForMoreBytes() async throws {
        for count in [4, 8] {
            let stream = BoundedTestStream()
            let session = makeSession(stream)
            let work = try await start(stream, on: session, limit: 8)
            XCTAssertTrue(stream.respond())
            XCTAssertTrue(stream.send(Data(repeating: 1, count: count)))
            try await PlaybackTestSupport.eventually(timeout: 2) {
                let tasks = await session.allTasks
                return tasks.contains { $0.countOfBytesReceived >= Int64(count) }
            }
            work.cancel()
            try await PlaybackTestSupport.eventually(timeout: 2) { stream.cancellations == 1 }
            do { _ = try await work.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(stream.didFinish)
            XCTAssertFalse(stream.send(Data([2])))
        }
    }

    func testCancellationAndOversizeAffectOnlyTheirOwnRequest() async throws {
        for oversized in [false, true] {
            let rejected = BoundedTestStream()
            let sibling = BoundedTestStream()
            let later = BoundedTestStream()
            let session = makeSession(rejected, sibling, later)
            let rejectedWork = try await start(rejected, on: session, limit: 8)
            let siblingWork = try await start(sibling, on: session, limit: 8)
            XCTAssertTrue(rejected.respond())
            XCTAssertTrue(sibling.respond())
            XCTAssertTrue(sibling.send(Data([1, 2])))
            if oversized { XCTAssertTrue(rejected.send(Data(repeating: 7, count: 9))) }
            else { rejectedWork.cancel() }
            try await PlaybackTestSupport.eventually(timeout: 2) { rejected.cancellations == 1 }
            do { _ = try await rejectedWork.value; XCTFail("Expected rejection") }
            catch {
                if oversized { XCTAssertEqual(error as? BoundedResponseError, .tooLarge) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            XCTAssertEqual(sibling.cancellations, 0)
            XCTAssertTrue(sibling.send(Data([3])))
            XCTAssertTrue(sibling.finish())
            let (siblingData, _) = try await siblingWork.value
            XCTAssertEqual(siblingData, Data([1, 2, 3]))

            let laterWork = try await start(later, on: session, limit: 8)
            XCTAssertTrue(later.respond(expectedLength: 1))
            XCTAssertTrue(later.send(Data([4])))
            XCTAssertTrue(later.finish())
            let (laterData, _) = try await laterWork.value
            XCTAssertEqual(laterData, Data([4]))
            XCTAssertEqual(later.recordedRequest?.value(forHTTPHeaderField: "X-Bounded-Session"), "preserved")
            XCTAssertEqual(later.recordedRequest?.timeoutInterval, 7)
            XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 5)
            XCTAssertEqual(session.configuration.timeoutIntervalForResource, 10)
        }
    }

    private func makeSession(_ streams: BoundedTestStream...) -> URLSession {
        streams.forEach { BoundedTestURLProtocol.registry.register($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedTestURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Bounded-Session": "preserved"]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        addTeardownBlock {
            session.invalidateAndCancel()
            streams.forEach { BoundedTestURLProtocol.registry.remove($0.id) }
        }
        return session
    }

    private func start(_ stream: BoundedTestStream, on session: URLSession, limit: Int) async throws -> Task<(Data, URLResponse), Error> {
        let work = Task { try await session.boundedData(for: stream.request, maximumBytes: limit) }
        addTeardownBlock { work.cancel() }
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.recordedRequest != nil }
        return work
    }
}

// Tests release headers, chunks, and EOF separately so a successful stop must happen while loading is unfinished.
private final class BoundedTestStream: @unchecked Sendable {
    let id = UUID().uuidString
    private let queue = DispatchQueue(label: "BoundedURLSessionTests.stream")
    private var loading: BoundedTestURLProtocol?
    private var capturedRequest: URLRequest?
    private var finished = false
    private var stops = 0
    private var byteCount = 0
    private var chunkCount = 0

    var request: URLRequest {
        var request = URLRequest(url: URL(string: "https://bounded-response.test/\(id)")!, timeoutInterval: 7)
        request.setValue(id, forHTTPHeaderField: "X-GanaBajana-Bounded-Test")
        return request
    }

    var recordedRequest: URLRequest? { queue.sync { capturedRequest } }
    var cancellations: Int { queue.sync { stops } }
    var didFinish: Bool { queue.sync { finished } }
    var deliveredBytes: Int { queue.sync { byteCount } }
    var deliveredChunks: Int { queue.sync { chunkCount } }

    func start(_ loading: BoundedTestURLProtocol) {
        queue.async {
            self.loading = loading
            self.capturedRequest = loading.request
        }
    }

    func stop() {
        queue.async {
            if self.loading != nil, !self.finished { self.stops += 1 }
            self.loading = nil
        }
    }

    func respond(status: Int = 200, expectedLength: Int64? = nil) -> Bool {
        queue.sync {
            guard let loading, let url = loading.request.url else { return false }
            var headers = ["Content-Type": "application/octet-stream", "X-Bounded-Response": "preserved"]
            if let expectedLength { headers["Content-Length"] = String(expectedLength) }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return false }
            loading.client?.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
            return true
        }
    }

    func send(_ data: Data) -> Bool {
        queue.sync {
            guard let loading else { return false }
            byteCount += data.count
            chunkCount += 1
            loading.client?.urlProtocol(loading, didLoad: data)
            return true
        }
    }

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
}

private final class BoundedTestStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [String: BoundedTestStream] = [:]

    func register(_ stream: BoundedTestStream) { lock.withLock { streams[stream.id] = stream } }
    func remove(_ id: String) { _ = lock.withLock { streams.removeValue(forKey: id) } }
    func stream(for request: URLRequest) -> BoundedTestStream? {
        guard let id = request.value(forHTTPHeaderField: "X-GanaBajana-Bounded-Test") else { return nil }
        return lock.withLock { streams[id] }
    }
}

private final class BoundedTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = BoundedTestStreamRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stream = Self.registry.stream(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        stream.start(self)
    }

    override func stopLoading() { Self.registry.stream(for: request)?.stop() }
}
