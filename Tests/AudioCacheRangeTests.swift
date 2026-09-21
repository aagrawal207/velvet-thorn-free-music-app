import XCTest
@testable import GanaBajana

@MainActor
final class AudioCacheRangeTests: XCTestCase {
    private nonisolated static let chunkBytes = 1_048_576
    private let trackID = "range-song"

    func testTwoRangesPublishTheExactAACBytesWithOneSidecarAndAnUnchangedSourceURL() async throws {
        let payload = Self.payload()
        let fixture = try makeFixture { try Self.rangeStub($0, payload: payload) }
        let url = AudioCacheTests.remote(trackID, clen: payload.count)

        let stored = try await fixture.cache.store(trackID: trackID, from: url, stream: ResolvedStream(url: url))

        XCTAssertEqual(try Data(contentsOf: stored.url), payload)
        XCTAssertEqual(stored.bytes, Int64(payload.count))
        XCTAssertEqual(stored.url.pathExtension, "m4a")
        XCTAssertEqual(fixture.mock.state.requests.map { $0.value(forHTTPHeaderField: "Range") }, [
            "bytes=0-1048575", "bytes=1048576-\(payload.count - 1)"
        ])
        for request in fixture.mock.state.requests {
            XCTAssertEqual(request.url, url)
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        }
        let sidecar = try String(contentsOf: fixture.cache.directory.appendingPathComponent("\(trackID).json"), encoding: .utf8)
        XCTAssertFalse(sidecar.contains(url.absoluteString))
        XCTAssertFalse(sidecar.contains("googlevideo"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path).sorted(),
                       ["\(trackID).json", "\(trackID).m4a"])
        let usage = try await fixture.cache.storageUsage()
        XCTAssertEqual(usage.bytes, Int64(payload.count))
        XCTAssertEqual(usage.songCount, 1)
        XCTAssertEqual(usage.pendingDownloads, 0)
    }

    func testWebMRangesReachPreparationUnchangedWithOptionalLengthAndETagHeaders() async throws {
        let payload = Self.payload(webM: true)
        for includeOptionalHeaders in [true, false] {
            let inputs = CatalogTestRecorder<Data>()
            let fixture = try makeFixture(preparation: { input, output in
                inputs.record(try Data(contentsOf: input))
                return try await OpusTestSupport.prepare(input: input, output: output)
            }, handler: { request in
                var stub = try Self.rangeStub(request, payload: payload, mime: "audio/webm")
                if !includeOptionalHeaders {
                    stub.headers.removeValue(forKey: "Content-Length")
                    stub.headers.removeValue(forKey: "ETag")
                }
                return stub
            })
            let original = try fixture.seed(trackID)
            let originalBytes = try Data(contentsOf: original)
            await fixture.cache.pin(trackID)
            let url = AudioCacheTests.remote(trackID, clen: payload.count)
            let stream = ResolvedStream(url: url, duration: 8, quality: OpusTestSupport.opusQuality)
            let permit = try await fixture.cache.writePermit()

            let stored = try await fixture.cache.storeOpus(trackID: trackID, stream: stream, permit: permit, foreground: true)

            XCTAssertEqual(inputs.values, [payload])
            XCTAssertEqual(try Data(contentsOf: stored.url), OpusTestSupport.mp4)
            XCTAssertEqual(try Data(contentsOf: original), originalBytes)
            XCTAssertEqual(fixture.mock.state.requests.count, 2)
            let files = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path)
            XCTAssertFalse(files.contains { $0.hasSuffix(".part") || $0.hasSuffix(".webm") })
            let usage = try await fixture.cache.storageUsage()
            XCTAssertEqual(usage.bytes, Int64(originalBytes.count + OpusTestSupport.mp4.count))
            XCTAssertEqual(usage.songCount, 1)
            XCTAssertEqual(usage.pendingDownloads, 0)
        }
    }

    func testExactChunkBoundaryAndOneByteTailAreAssembledWithoutAnExtraRequest() async throws {
        let firstChunk = Data(Self.payload().prefix(Self.chunkBytes))
        for tailBytes in [0, 1] {
            let payload = firstChunk + Data(repeating: 0xa5, count: tailBytes)
            let fixture = try makeFixture { try Self.rangeStub($0, payload: payload) }
            let url = AudioCacheTests.remote(trackID, clen: payload.count)
            let stored = try await fixture.cache.store(trackID: trackID, from: url, stream: ResolvedStream(url: url))
            XCTAssertEqual(try Data(contentsOf: stored.url), payload)
            XCTAssertEqual(stored.bytes, Int64(payload.count))
            var ranges: [String?] = ["bytes=0-1048575"]
            if tailBytes == 1 { ranges.append("bytes=1048576-1048576") }
            XCTAssertEqual(fixture.mock.state.requests.map { $0.value(forHTTPHeaderField: "Range") }, ranges)
        }
    }

    func testInvalidWebMRangeNeverReachesPreparationOrReplacesPinnedMedia() async throws {
        let payload = Self.payload(webM: true)
        let prepared = CatalogTestRecorder<Bool>()
        let fixture = try makeFixture(preparation: { input, output in
            prepared.record(true)
            return try await OpusTestSupport.prepare(input: input, output: output)
        }, handler: { request in
            var stub = try Self.rangeStub(request, payload: payload, mime: "audio/webm")
            if request.value(forHTTPHeaderField: "Range") != "bytes=0-1048575" {
                stub.headers["Content-Range"] = "bytes 1048576-\(payload.count - 1)/\(payload.count + 1)"
            }
            return stub
        })
        let original = try fixture.seed(trackID)
        let originalBytes = try Data(contentsOf: original)
        await fixture.cache.pin(trackID)
        let url = AudioCacheTests.remote(trackID, clen: payload.count)
        let permit = try await fixture.cache.writePermit()
        do {
            _ = try await fixture.cache.storeOpus(trackID: trackID,
                stream: ResolvedStream(url: url, quality: OpusTestSupport.opusQuality), permit: permit, foreground: true)
            XCTFail("Preparation requires a complete, verified WebM input")
        } catch { XCTAssertTrue(error is PlaybackStreamError, "\(error)") }
        XCTAssertTrue(prepared.values.isEmpty)
        XCTAssertEqual(fixture.mock.state.requests.count, 2)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path).sorted(),
                       ["\(trackID).json", "\(trackID).wav"])
        let usage = try await fixture.cache.storageUsage()
        XCTAssertEqual(usage.bytes, Int64(originalBytes.count))
        XCTAssertEqual(usage.pendingDownloads, 0)
    }

    func testIgnoredInitialRangeAcceptsOnlyOneVerifiedWholeResponse() async throws {
        let payload = Self.payload()
        for includeLength in [true, false] {
            let fixture = try makeFixture { _ in
                var headers = ["Content-Type": "audio/mp4"]
                if includeLength { headers["Content-Length"] = "\(payload.count)" }
                return CatalogStub(headers: headers, data: payload)
            }
            let url = AudioCacheTests.remote(trackID, clen: payload.count)
            let stored = try await fixture.cache.store(trackID: trackID, from: url, stream: ResolvedStream(url: url))
            XCTAssertEqual(try Data(contentsOf: stored.url), payload)
            XCTAssertEqual(stored.bytes, Int64(payload.count))
            XCTAssertEqual(fixture.mock.state.requests.map { $0.value(forHTTPHeaderField: "Range") }, ["bytes=0-1048575"])
        }
    }

    func testIgnoredInitialRangeRejectsPartialBodiesAndConflictingWholeLengths() async throws {
        let payload = Self.payload()
        let url = AudioCacheTests.remote(trackID, clen: payload.count)
        for stub in [
            CatalogStub(headers: ["Content-Type": "audio/mp4", "Content-Length": "1048576"], data: Data(payload.prefix(Self.chunkBytes))),
            CatalogStub(headers: ["Content-Type": "audio/mp4", "Content-Length": "\(payload.count)"], data: Data(payload.prefix(Self.chunkBytes))),
            CatalogStub(headers: ["Content-Type": "audio/mp4"], data: Data(payload.prefix(Self.chunkBytes))),
            CatalogStub(headers: ["Content-Type": "audio/mp4", "Content-Length": "\(payload.count + 1)"], data: payload),
            CatalogStub(headers: ["Content-Type": "audio/mp4"], data: payload + Data([0]))
        ] {
            let fixture = try makeFixture { _ in stub }
            try await assertRejected(fixture, url: url)
        }
    }

    func testRejectsIncorrectFirstRangeBoundsTotalsAndMissingRangeHeaders() async throws {
        let payload = Self.payload()
        let url = AudioCacheTests.remote(trackID, clen: payload.count)
        for range in [
            "bytes 1-1048575/\(payload.count)",
            "bytes 0-1048574/\(payload.count)",
            "bytes 0-1048576/\(payload.count)",
            "bytes 0-1048575/\(payload.count + 1)",
            "bytes 0-1048575/*", ""
        ] {
            var stub = Self.partial(payload, start: 0)
            stub.headers["Content-Range"] = range.isEmpty ? nil : range
            stub.headers.removeValue(forKey: "Content-Length")
            let invalid = stub
            let fixture = try makeFixture { _ in invalid }
            try await assertRejected(fixture, url: url, context: range)
        }
    }

    func testRejectsIncorrectOrNonDecimalPerResponseContentLengths() async throws {
        let payload = Self.payload()
        let url = AudioCacheTests.remote(trackID, clen: payload.count)
        for length in ["1048575", "\(payload.count)", "+1048576", "1048576.0", "1e6", "-1", "0", "1048576, 1048576", "9223372036854775808"] {
            var stub = Self.partial(payload, start: 0)
            stub.headers["Content-Length"] = length
            let invalid = stub
            let fixture = try makeFixture { _ in invalid }
            try await assertRejected(fixture, url: url, context: length)
        }
    }

    func testRejectsLaterGapsOverlapsChangedTotalsMIMEAndETags() async throws {
        let payload = Self.payload()
        let url = AudioCacheTests.remote(trackID, clen: payload.count)
        let changes = [
            ("Content-Range", "bytes 1048577-\(payload.count - 1)/\(payload.count)"),
            ("Content-Range", "bytes 1048575-\(payload.count - 1)/\(payload.count)"),
            ("Content-Range", "bytes 1048576-\(payload.count - 2)/\(payload.count)"),
            ("Content-Range", "bytes 1048576-\(payload.count - 1)/\(payload.count + 1)"),
            ("Content-Length", "\(payload.count)"),
            ("Content-Type", "video/mp4"),
            ("Content-Type", "audio/mp4; codecs=\"mp4a.40.5\""),
            ("Content-Type", "multipart/byteranges; boundary=range"),
            ("Content-Encoding", "gzip"),
            ("ETag", "\"media-v2\""),
            ("ETag", "")
        ]
        for (header, value) in changes {
            let fixture = try makeFixture { request in
                var stub = try Self.rangeStub(request, payload: payload)
                if request.value(forHTTPHeaderField: "Range") != "bytes=0-1048575" {
                    if header == "Content-Range" { stub.headers.removeValue(forKey: "Content-Length") }
                    stub.headers[header] = value.isEmpty ? nil : value
                }
                return stub
            }
            try await assertRejected(fixture, url: url, requests: 2, context: "\(header): \(value)")
        }
        let appearingTag = try makeFixture { request in
            var stub = try Self.rangeStub(request, payload: payload)
            if request.value(forHTTPHeaderField: "Range") == "bytes=0-1048575" { stub.headers.removeValue(forKey: "ETag") }
            return stub
        }
        try await assertRejected(appearingTag, url: url, requests: 2, context: "An ETag must remain consistent across the response sequence")
    }

    func testAWholeResponseToALaterRangeCannotAppendDuplicateBytes() async throws {
        let payload = Self.payload()
        let fixture = try makeFixture { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=0-1048575" { return Self.partial(payload, start: 0) }
            return CatalogStub(headers: ["Content-Type": "audio/mp4", "Content-Length": "\(payload.count)", "ETag": "\"media-v1\""], data: payload)
        }
        try await assertRejected(fixture, url: AudioCacheTests.remote(trackID, clen: payload.count), requests: 2)
    }

    func testShortAndOversizedRangeBodiesAreRejectedEvenWithoutContentLength() async throws {
        let payload = Self.payload()
        let url = AudioCacheTests.remote(trackID, clen: payload.count)
        for corruptFirst in [true, false] {
            for extraByte in [false, true] {
                let fixture = try makeFixture { request in
                    var stub = try Self.rangeStub(request, payload: payload)
                    let first = request.value(forHTTPHeaderField: "Range") == "bytes=0-1048575"
                    if first == corruptFirst {
                        stub.headers.removeValue(forKey: "Content-Length")
                        if extraByte { stub.data.append(0) } else { stub.data.removeLast() }
                    }
                    return stub
                }
                try await assertRejected(fixture, url: url, requests: corruptFirst ? 1 : 2,
                                         context: "first=\(corruptFirst), extra=\(extraByte)")
            }
        }
    }

    func testMultipartEncodedAndInvalidPrefixResponsesNeverPublish() async throws {
        let payload = Self.payload()
        let url = AudioCacheTests.remote(trackID, clen: payload.count)
        for fault in ["multipart", "encoding", "prefix"] {
            var stub = Self.partial(payload, start: 0)
            switch fault {
            case "multipart": stub.headers["Content-Type"] = "multipart/byteranges; boundary=range"
            case "encoding": stub.headers["Content-Encoding"] = "gzip"
            default: stub.data.replaceSubrange(0..<12, with: Data(repeating: 0, count: 12))
            }
            let invalid = stub
            let fixture = try makeFixture { _ in invalid }
            try await assertRejected(fixture, url: url, context: fault)
        }
    }

    func testCallerLimitAnd64MiBMaximumRejectOversizedInputsBeforeAnyRequest() async throws {
        for (size, limit) in [(Int64(1_048_577), Int64(1_048_576)), (Int64(64 << 20) + 1, Int64.max), (Int64.max, Int64.max), (Int64(12), Int64(0))] {
            let fixture = try makeFixture { _ in throw URLError(.badServerResponse) }
            let temporary = fixture.cache.directory.appendingPathComponent("\(trackID)-\(UUID()).part")
            let url = AudioCacheTests.remote(trackID, clen: Int(size))
            do {
                _ = try await AudioDownloader(session: fixture.mock.session).receive(trackID: trackID, from: url,
                    into: fixture.cache.directory, limit: limit, temporary: temporary)
                XCTFail("Oversized inputs must fail before transport starts")
            } catch { XCTAssertTrue(error is PlaybackStreamError, "\(error)") }
            XCTAssertTrue(fixture.mock.state.requests.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        }
        let fixture = try makeFixture { _ in
            CatalogStub(headers: ["Content-Type": "audio/mp4", "Content-Length": "\((64 << 20) + 1)"], data: OpusTestSupport.mp4)
        }
        try await assertRejected(fixture, url: AudioCacheTests.remote(trackID))
    }

    func testUnknownClenAndNonGoogleSourcesKeepTheVerifiedCompleteGETPath() async throws {
        let payload = OpusTestSupport.mp4
        let urls = [
            AudioCacheTests.remote(trackID),
            URL(string: "https://samples.example.com/audio?clen=\(payload.count)")!,
            URL(string: "https://googlevideo.com.example.com/audio?clen=\(payload.count)")!,
            URL(string: "http://audio.googlevideo.com/audio?clen=\(payload.count)")!,
            URL(string: "https://audio.googlevideo.com/audio?clen=\(payload.count).0")!,
            URL(string: "https://audio.googlevideo.com/audio?clen=\(payload.count)&clen=\(payload.count)")!
        ]
        for url in urls {
            let fixture = try makeFixture { _ in
                CatalogStub(headers: ["Content-Type": "audio/mp4", "Content-Length": "\(payload.count)"], data: payload)
            }
            let stored = try await fixture.cache.store(trackID: trackID, from: url, stream: ResolvedStream(url: url))
            XCTAssertEqual(try Data(contentsOf: stored.url), payload)
            XCTAssertEqual(fixture.mock.state.requests.count, 1)
            XCTAssertNil(fixture.mock.state.requests.first?.value(forHTTPHeaderField: "Range"))
        }
    }

    func testCancellingSharedWaitersBetweenRangesKeepsActiveBytesUntilTheWriterDrains() async throws {
        let payload = Self.payload(fullChunks: 2)
        let fixture = try makeFixture { request in
            var stub = try Self.rangeStub(request, payload: payload)
            if request.value(forHTTPHeaderField: "Range") != "bytes=0-1048575" { stub.delay = 10 }
            return stub
        }
        let id = trackID
        let url = AudioCacheTests.remote(id, clen: payload.count)
        let first = Task { try await fixture.cache.store(trackID: id, from: url, stream: ResolvedStream(url: url)) }
        let second = Task { try await fixture.cache.store(trackID: id, from: url, stream: ResolvedStream(url: url)) }
        defer { first.cancel(); second.cancel() }
        try await PlaybackTestSupport.eventually { await fixture.cache.activeWaiterCount == 2 }
        try await PlaybackTestSupport.eventually { fixture.mock.state.requests.count == 2 }
        let pending = try await fixture.cache.storageUsage()
        XCTAssertEqual(pending.bytes, Int64(Self.chunkBytes))
        XCTAssertEqual(pending.pendingDownloads, 1)
        XCTAssertEqual(pending.songCount, 0)
        let unpublished = await fixture.cache.entry(for: id)
        XCTAssertNil(unpublished)

        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let waiters = await fixture.cache.activeWaiterCount
        XCTAssertEqual(waiters, 1)
        XCTAssertEqual(fixture.mock.state.cancellations, 0)
        let stillActive = try await fixture.cache.storageUsage()
        XCTAssertEqual(stillActive.bytes, Int64(Self.chunkBytes))
        XCTAssertEqual(stillActive.pendingDownloads, 1)

        second.cancel()
        do { _ = try await second.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cleared = try await fixture.cache.clearUnused()
        XCTAssertEqual(cleared.bytes, 0)
        XCTAssertEqual(cleared.pendingDownloads, 0)
        XCTAssertEqual(cleared.songCount, 0)
        XCTAssertEqual(fixture.mock.state.requests.count, 2, "No third range starts after cancellation")
        try await PlaybackTestSupport.eventually { fixture.mock.state.cancellations == 1 }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path), [])
    }

    func testCancellationWhileWaitingForRangeBodyBytesStopsIOAndCleansThePart() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioCacheWaitingBodyProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajana-RangeBody-\(UUID())")
        let cache = AudioCache(directory: directory, session: session)
        addTeardownBlock {
            session.invalidateAndCancel()
            _ = try? await cache.clearUnused()
            try? FileManager.default.removeItem(at: directory)
        }
        let id = "waiting-\(UUID())"
        let url = AudioCacheTests.remote(id, clen: 2_097_152)
        let work = Task { try await cache.store(trackID: id, from: url, stream: ResolvedStream(url: url)) }
        defer { work.cancel() }
        try await PlaybackTestSupport.eventually { (try? await cache.storageUsage().bytes) == 262_144 }
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await PlaybackTestSupport.eventually { AudioCacheWaitingBodyProtocol.stopped.values.contains(url) }
        let cleared = try await cache.clearUnused()
        XCTAssertEqual(cleared.bytes, 0)
        XCTAssertEqual(cleared.pendingDownloads, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testRangePublicationCannotOverwriteAnExistingMediaFile() async throws {
        let payload = Self.payload()
        let fixture = try makeFixture { try Self.rangeStub($0, payload: payload) }
        let original = try fixture.seed(trackID)
        let originalBytes = try Data(contentsOf: original)
        let sidecar = fixture.cache.directory.appendingPathComponent("\(trackID).json")
        let originalMetadata = try Data(contentsOf: sidecar)
        let url = AudioCacheTests.remote(trackID, clen: payload.count)
        let temporary = fixture.cache.directory.appendingPathComponent("\(trackID)-\(UUID()).part")
        do {
            _ = try await AudioDownloader(session: fixture.mock.session).download(trackID: trackID, from: url,
                stream: ResolvedStream(url: url), into: fixture.cache.directory, limit: AudioCache.maximumFileBytes, temporary: temporary)
            XCTFail("A complete range download must not replace an existing encoding")
        } catch { XCTAssertTrue(error is AudioCache.ManagementError, "\(error)") }
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: sidecar), originalMetadata)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path).sorted(),
                       ["\(trackID).json", "\(trackID).wav"])
    }

    private func makeFixture(preparation: @escaping AudioCache.OpusPreparation = OpusTestSupport.prepare,
                             handler: @escaping CatalogMockState.Handler) throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(handler: handler, opusPreparation: preparation)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }

    private func assertRejected(_ fixture: CacheManagementFixture, url: URL, requests: Int = 1, context: String = "",
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await fixture.cache.store(trackID: trackID, from: url, stream: ResolvedStream(url: url))
            XCTFail("Invalid transport must not publish: \(context)", file: file, line: line)
        } catch { XCTAssertTrue(error is PlaybackStreamError || error is MusicServiceError, "\(context): \(error)", file: file, line: line) }
        XCTAssertEqual(fixture.mock.state.requests.count, requests, context, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path), [], context, file: file, line: line)
        let usage = try await fixture.cache.storageUsage()
        XCTAssertEqual(usage.bytes, 0, context, file: file, line: line)
        XCTAssertEqual(usage.songCount, 0, context, file: file, line: line)
        XCTAssertEqual(usage.pendingDownloads, 0, context, file: file, line: line)
    }

    private nonisolated static func payload(webM: Bool = false, fullChunks: Int = 1) -> Data {
        var data = Data((webM ? OpusTestSupport.webM : OpusTestSupport.mp4).prefix(12))
        data.reserveCapacity(fullChunks * chunkBytes + 333)
        for chunk in 0..<fullChunks {
            data.append(Data(repeating: UInt8(32 + chunk), count: chunkBytes - (chunk == 0 ? 12 : 0)))
        }
        data.append(contentsOf: (0..<333).map { UInt8($0 % 251) })
        return data
    }

    private nonisolated static func partial(_ payload: Data, start: Int, mime: String = "audio/mp4") -> CatalogStub {
        let end = min(start + chunkBytes, payload.count)
        return CatalogStub(status: 206, headers: ["Content-Type": mime, "Content-Length": "\(end - start)",
            "Content-Range": "bytes \(start)-\(end - 1)/\(payload.count)", "ETag": "\"media-v1\""], data: payload.subdata(in: start..<end))
    }

    private nonisolated static func rangeStub(_ request: URLRequest, payload: Data, mime: String = "audio/mp4") throws -> CatalogStub {
        for start in stride(from: 0, to: payload.count, by: chunkBytes) {
            if request.value(forHTTPHeaderField: "Range") == "bytes=\(start)-\(min(start + chunkBytes, payload.count) - 1)" {
                return partial(payload, start: start, mime: mime)
            }
        }
        throw URLError(.badServerResponse)
    }
}

private final class AudioCacheWaitingBodyProtocol: URLProtocol, @unchecked Sendable {
    static let stopped = CatalogTestRecorder<URL>()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mp4", "Content-Length": "1048576", "Content-Range": "bytes 0-1048575/2097152"]) else { return }
        let body = Data(OpusTestSupport.mp4.prefix(12)) + Data(repeating: 7, count: 262_144 - 12)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        // Leave the declared range unfinished so cancellation must wake a suspended byte iterator.
    }

    override func stopLoading() {
        if let url = request.url { Self.stopped.record(url) }
    }
}
