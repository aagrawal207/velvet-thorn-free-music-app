import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class ChunkedBodyTests: XCTestCase {
    // MARK: chunkedBody

    func testResponseIsReturnedBeforeAnyBodyBytes() async throws {
        let stream = ChunkedTestStream()
        let session = makeSession(stream)
        let work = Task { try await session.chunkedBody(for: stream.request) }
        addTeardownBlock { work.cancel() }
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.recordedRequest != nil }
        XCTAssertTrue(stream.respond(status: 206, expectedLength: 4))
        let (body, response) = try await work.value
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(response.expectedContentLength, 4)
        XCTAssertEqual(stream.deliveredBytes, 0)
        XCTAssertEqual(body.task.state, .running)

        XCTAssertTrue(stream.send(Data([1, 2, 3, 4])))
        XCTAssertTrue(stream.finish())
        var received = Data()
        for try await chunk in body { received.append(chunk) }
        XCTAssertEqual(received, Data([1, 2, 3, 4]))
        XCTAssertEqual(stream.cancellations, 0)
    }

    func testLargeChunkedBodyArrivesIntactAsFewElements() async throws {
        let payload = Self.payload(count: 5 * 1_048_576 + 777)
        let stream = ChunkedTestStream()
        let session = makeSession(stream)
        let work = Task { () -> (Data, Int) in
            let (body, _) = try await session.chunkedBody(for: stream.request)
            var data = Data()
            var elements = 0
            for try await chunk in body {
                elements += 1
                data.append(chunk)
            }
            return (data, elements)
        }
        addTeardownBlock { work.cancel() }
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.recordedRequest != nil }
        XCTAssertTrue(stream.respond())
        var offset = 0
        var sends = 0
        while offset < payload.count {
            let size = min(payload.count - offset, [1, 4_093, 65_536, 300_001][sends % 4])
            XCTAssertTrue(stream.send(payload.subdata(in: offset..<(offset + size))))
            offset += size
            sends += 1
        }
        XCTAssertTrue(stream.finish())
        let (data, elements) = try await work.value
        XCTAssertEqual(data.count, payload.count)
        XCTAssertEqual(data, payload)
        XCTAssertGreaterThan(elements, 0)
        XCTAssertLessThan(elements, payload.count / 1_000, "Chunks must not degrade to per-byte delivery")
    }

    func testUnconsumedBodySuspendsTheTaskAndDrainingResumesIt() async throws {
        let payload = Self.payload(count: 3 * URLSessionChunkedBody.highWaterBytes)
        let stream = ChunkedTestStream()
        let session = makeSession(stream)
        let work = Task { try await session.chunkedBody(for: stream.request) }
        addTeardownBlock { work.cancel() }
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.recordedRequest != nil }
        XCTAssertTrue(stream.respond(expectedLength: Int64(payload.count)))
        let (body, _) = try await work.value
        XCTAssertTrue(stream.send(payload.prefix(URLSessionChunkedBody.highWaterBytes)))
        try await PlaybackTestSupport.eventually(timeout: 2) { body.task.state == .suspended }
        XCTAssertTrue(stream.send(payload.dropFirst(URLSessionChunkedBody.highWaterBytes)))
        XCTAssertTrue(stream.finish())

        var received = Data()
        for try await chunk in body { received.append(chunk) }
        XCTAssertEqual(received, payload)
        XCTAssertEqual(body.task.state, .completed)
        XCTAssertEqual(stream.cancellations, 0)
    }

    func testCallerCancellationStopsOnlyItsOwnTransfer() async throws {
        let cancelled = ChunkedTestStream()
        let sibling = ChunkedTestStream()
        let session = makeSession(cancelled, sibling)
        let work = Task { () -> Int in
            let (body, _) = try await session.chunkedBody(for: cancelled.request)
            var count = 0
            for try await chunk in body { count += chunk.count }
            return count
        }
        let siblingWork = Task { () -> Data in
            let (body, _) = try await session.chunkedBody(for: sibling.request)
            var data = Data()
            for try await chunk in body { data.append(chunk) }
            return data
        }
        addTeardownBlock { work.cancel(); siblingWork.cancel() }
        try await PlaybackTestSupport.eventually(timeout: 2) { cancelled.recordedRequest != nil && sibling.recordedRequest != nil }
        XCTAssertTrue(cancelled.respond())
        XCTAssertTrue(sibling.respond())
        XCTAssertTrue(cancelled.send(Data(repeating: 1, count: 70_000)))
        XCTAssertTrue(sibling.send(Data([1, 2])))
        try await PlaybackTestSupport.eventually(timeout: 2) {
            await session.allTasks.contains { $0.countOfBytesReceived >= 70_000 }
        }

        work.cancel()
        try await PlaybackTestSupport.eventually(timeout: 2) { cancelled.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(cancelled.send(Data([2])))
        XCTAssertFalse(cancelled.didFinish)

        XCTAssertEqual(sibling.cancellations, 0)
        XCTAssertTrue(sibling.send(Data([3])))
        XCTAssertTrue(sibling.finish())
        let siblingData = try await siblingWork.value
        XCTAssertEqual(siblingData, Data([1, 2, 3]))
    }

    func testCancellationWhileWaitingForHeadersStopsTheRequest() async throws {
        let stream = ChunkedTestStream()
        let session = makeSession(stream)
        let work = Task { try await session.chunkedBody(for: stream.request) }
        addTeardownBlock { work.cancel() }
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.recordedRequest != nil }
        work.cancel()
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(stream.respond())
    }

    func testTransportFailureAfterBufferedChunksKeepsItsType() async throws {
        let stream = ChunkedTestStream()
        let session = makeSession(stream)
        let work = Task { () -> Data in
            let (body, _) = try await session.chunkedBody(for: stream.request)
            var data = Data()
            for try await chunk in body { data.append(chunk) }
            return data
        }
        addTeardownBlock { work.cancel() }
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.recordedRequest != nil }
        XCTAssertTrue(stream.respond())
        XCTAssertTrue(stream.send(Data("part".utf8)))
        XCTAssertTrue(stream.finish(error: URLError(.networkConnectionLost)))
        do { _ = try await work.value; XCTFail("Expected the transport failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }

    func testTaskDelegateStillReceivesRedirects() async throws {
        let stream = ChunkedTestStream()
        let session = makeSession(stream)
        let policy = ChunkedRefusingRedirects()
        let work = Task { try await session.boundedData(for: stream.request, maximumBytes: 64, delegate: policy) }
        addTeardownBlock { work.cancel() }
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.recordedRequest != nil }
        let target = URL(string: "https://redirect-target.test/elsewhere")!
        XCTAssertTrue(stream.redirect(to: target))
        try await PlaybackTestSupport.eventually(timeout: 2) { policy.refused == [target] }
        work.cancel()
        _ = try? await work.value
        XCTAssertEqual(policy.refused, [target])
        XCTAssertEqual(stream.requestCount, 1)
    }

    // MARK: boundedData over large chunks

    func testChunkOverflowWithoutContentLengthCancelsWithTooLarge() async throws {
        let limit = 256 * 1_024
        for sizes in [[limit + 1], [limit - 10, 11], [100_000, 100_000, 100_000]] {
            let stream = ChunkedTestStream()
            let session = makeSession(stream)
            let work = try await startBounded(stream, on: session, limit: limit)
            XCTAssertTrue(stream.respond())
            for size in sizes { XCTAssertTrue(stream.send(Data(repeating: 5, count: size))) }
            try await PlaybackTestSupport.eventually(timeout: 2) { stream.cancellations == 1 }
            do { _ = try await work.value; XCTFail("Expected an actual-byte oversize error for \(sizes)") }
            catch { XCTAssertEqual(error as? BoundedResponseError, .tooLarge) }
            XCTAssertFalse(stream.didFinish)
        }
    }

    func testChunkOverflowBeyondSmallerDeclaredLengthCancelsWithTooLarge() async throws {
        let limit = 256 * 1_024
        let stream = ChunkedTestStream()
        let session = makeSession(stream)
        let work = try await startBounded(stream, on: session, limit: limit)
        XCTAssertTrue(stream.respond(expectedLength: 1_024))
        XCTAssertTrue(stream.send(Data(repeating: 6, count: limit + 1)))
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected an actual-byte oversize error") }
        catch { XCTAssertEqual(error as? BoundedResponseError, .tooLarge) }
    }

    func testDeclaredLengthAboveLimitIsRejectedBeforeBody() async throws {
        let limit = 256 * 1_024
        let stream = ChunkedTestStream()
        let session = makeSession(stream)
        let work = try await startBounded(stream, on: session, limit: limit)
        XCTAssertTrue(stream.respond(expectedLength: Int64(limit + 1)))
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected a declared oversize error") }
        catch { XCTAssertEqual(error as? BoundedResponseError, .tooLarge) }
        XCTAssertEqual(stream.deliveredBytes, 0)
    }

    func testExactLimitLargeBodySucceedsWithKnownAndUnknownLength() async throws {
        let payload = Self.payload(count: 3 * 1_048_576 + 5)
        for length in [Int64(payload.count), nil] {
            let stream = ChunkedTestStream()
            let session = makeSession(stream)
            let work = try await startBounded(stream, on: session, limit: payload.count)
            XCTAssertTrue(stream.respond(expectedLength: length))
            XCTAssertTrue(stream.send(payload.prefix(1_000_003)))
            XCTAssertTrue(stream.send(payload.dropFirst(1_000_003)))
            XCTAssertTrue(stream.finish())
            let (data, response) = try await work.value
            XCTAssertEqual(data, payload)
            XCTAssertEqual(response.expectedContentLength, length ?? -1)
            XCTAssertEqual(stream.cancellations, 0)
        }
    }

    // MARK: AudioDownloader

    func testMultiMiBRangeDownloadWritesTheExactBytesWithBatchedProgress() async throws {
        let payload = Self.mediaPayload(count: 3 * Self.rangeBytes + 333)
        let mock = CatalogMockSession { try Self.rangeStub($0, payload: payload) }
        defer { mock.close() }
        let directory = try makeDirectory()
        let temporary = directory.appendingPathComponent("song-\(UUID().uuidString).part")
        let url = AudioCacheTests.remote("range-song", clen: payload.count)
        let progress = CatalogTestRecorder<Int64>()
        let totals = CatalogTestRecorder<Int64>()

        let part = try await AudioDownloader(session: mock.session).receive(trackID: "range-song", from: url, into: directory,
            limit: AudioCache.maximumFileBytes, temporary: temporary, progress: { written, expected in
                progress.record(written)
                totals.record(expected)
            })

        XCTAssertEqual(part.bytes, Int64(payload.count))
        XCTAssertEqual(part.fileExtension, "m4a")
        XCTAssertEqual(try Data(contentsOf: part.url), payload)
        XCTAssertEqual(mock.state.requests.count, 4)
        XCTAssertEqual(Set(totals.values), [Int64(payload.count)])
        let values = progress.values
        XCTAssertEqual(values.last, Int64(payload.count))
        XCTAssertEqual(values, values.sorted())
        // Within a range, progress reports at each full 256 KiB write; the range end reports its remainder.
        let batch = Int64(256 << 10)
        for value in values where value % batch != 0 { XCTAssertEqual(value, Int64(payload.count)) }
        XCTAssertTrue(values.contains(batch))
    }

    func testWholeResponseLongerThanItsDeclaredLengthIsRejectedWithoutAPartialFile() async throws {
        let payload = Self.mediaPayload(count: 600_000)
        let mock = CatalogMockSession { _ in
            CatalogStub(headers: ["Content-Type": "audio/mp4", "Content-Length": "500000"], data: payload)
        }
        defer { mock.close() }
        let directory = try makeDirectory()
        let temporary = directory.appendingPathComponent("song-\(UUID().uuidString).part")
        let url = URL(string: "https://media.example.test/song.m4a")!
        do {
            _ = try await AudioDownloader(session: mock.session).receive(trackID: "range-song", from: url, into: directory,
                                                                      limit: AudioCache.maximumFileBytes, temporary: temporary)
            XCTFail("An overrun must not publish")
        } catch {
            guard case .invalidMedia? = error as? PlaybackStreamError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    // MARK: Helpers

    private nonisolated static let rangeBytes = 1_048_576

    private func makeSession(_ streams: ChunkedTestStream...) -> URLSession {
        streams.forEach { ChunkedTestURLProtocol.registry.register($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedTestURLProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        addTeardownBlock {
            session.invalidateAndCancel()
            streams.forEach { ChunkedTestURLProtocol.registry.remove($0.id) }
        }
        return session
    }

    private func startBounded(_ stream: ChunkedTestStream, on session: URLSession, limit: Int) async throws -> Task<(Data, URLResponse), Error> {
        let work = Task { try await session.boundedData(for: stream.request, maximumBytes: limit) }
        addTeardownBlock { work.cancel() }
        try await PlaybackTestSupport.eventually(timeout: 2) { stream.recordedRequest != nil }
        return work
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkedBodyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Non-repeating bytes so a dropped, duplicated or reordered chunk changes the result.
    private nonisolated static func payload(count: Int) -> Data {
        var state: UInt32 = 0x9E37_79B9
        return Data((0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        })
    }

    private nonisolated static func mediaPayload(count: Int) -> Data {
        Data(OpusTestSupport.mp4.prefix(12)) + payload(count: count - 12)
    }

    private nonisolated static func rangeStub(_ request: URLRequest, payload: Data) throws -> CatalogStub {
        for start in stride(from: 0, to: payload.count, by: rangeBytes) {
            let end = min(start + rangeBytes, payload.count)
            if request.value(forHTTPHeaderField: "Range") == "bytes=\(start)-\(end - 1)" {
                return CatalogStub(status: 206, headers: ["Content-Type": "audio/mp4", "Content-Length": "\(end - start)",
                    "Content-Range": "bytes \(start)-\(end - 1)/\(payload.count)", "ETag": "\"media-v1\""],
                    data: payload.subdata(in: start..<end))
            }
        }
        throw URLError(.badServerResponse)
    }
}

private final class ChunkedRefusingRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [URL] = []
    var refused: [URL] { lock.withLock { targets } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.withLock { targets.append(request.url!) }
        completionHandler(nil)
    }
}

// Releases headers, chunks and EOF separately so tests control exactly what the task has received.
private final class ChunkedTestStream: @unchecked Sendable {
    let id = UUID().uuidString
    private let queue = DispatchQueue(label: "ChunkedBodyTests.stream")
    private var loading: ChunkedTestURLProtocol?
    private var capturedRequest: URLRequest?
    private var starts = 0
    private var finished = false
    private var stops = 0
    private var byteCount = 0

    var request: URLRequest {
        var request = URLRequest(url: URL(string: "https://chunked-body.test/\(id)")!, timeoutInterval: 7)
        request.setValue(id, forHTTPHeaderField: "X-GanaBajana-Chunked-Test")
        return request
    }

    var recordedRequest: URLRequest? { queue.sync { capturedRequest } }
    var requestCount: Int { queue.sync { starts } }
    var cancellations: Int { queue.sync { stops } }
    var didFinish: Bool { queue.sync { finished } }
    var deliveredBytes: Int { queue.sync { byteCount } }

    func start(_ loading: ChunkedTestURLProtocol) {
        queue.async {
            self.loading = loading
            self.capturedRequest = loading.request
            self.starts += 1
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
            var headers = ["Content-Type": "application/octet-stream"]
            if let expectedLength { headers["Content-Length"] = String(expectedLength) }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return false }
            loading.client?.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
            return true
        }
    }

    func redirect(to target: URL) -> Bool {
        queue.sync {
            guard let loading, let url = loading.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Location": target.absoluteString]) else { return false }
            var next = URLRequest(url: target)
            next.setValue(id, forHTTPHeaderField: "X-GanaBajana-Chunked-Test")
            loading.client?.urlProtocol(loading, wasRedirectedTo: next, redirectResponse: response)
            return true
        }
    }

    func send(_ data: Data) -> Bool {
        queue.sync {
            guard let loading else { return false }
            byteCount += data.count
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

private final class ChunkedTestStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [String: ChunkedTestStream] = [:]

    func register(_ stream: ChunkedTestStream) { lock.withLock { streams[stream.id] = stream } }
    func remove(_ id: String) { _ = lock.withLock { streams.removeValue(forKey: id) } }
    func stream(for request: URLRequest) -> ChunkedTestStream? {
        guard let id = request.value(forHTTPHeaderField: "X-GanaBajana-Chunked-Test") else { return nil }
        return lock.withLock { streams[id] }
    }
}

private final class ChunkedTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ChunkedTestStreamRegistry()

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
