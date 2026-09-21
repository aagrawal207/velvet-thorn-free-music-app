import XCTest
@testable import GanaBajana

@MainActor
final class LyricsServiceTests: XCTestCase {
    func testExactLookupUsesPublicHTTPSMetadataAndCachesAcrossCatalogIDs() async throws {
        let transport = LyricsStubTransport { _, _ in try LyricsTestFixtures.response(LyricsTestFixtures.record()) }
        let service = makeService(transport)
        let first = try await service.lyrics(for: LyricsTestFixtures.track)
        var duplicate = LyricsTestFixtures.track
        duplicate.id = "another-video"
        let second = try await service.lyrics(for: duplicate)
        XCTAssertEqual(first.kind, .synced)
        XCTAssertEqual(first.sourceID, 10)
        XCTAssertEqual(first.lines[0].time, 1.809, accuracy: 0.000_001)
        XCTAssertEqual(second.trackID, duplicate.id)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "lrclib.net")
        XCTAssertEqual(request.url?.path, "/api/get")
        XCTAssertEqual(LyricsTestFixtures.items(request)["duration"], "200.0")
        XCTAssertEqual(LyricsTestFixtures.items(request)["album_name"], "Imaginary Sky")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.httpShouldHandleCookies, false)
    }

    func testNotFoundFallsBackToScoredSearchAndChecksEvenExactResponseMetadata() async throws {
        let transport = LyricsStubTransport { request, _ in
            if request.url?.path == "/api/get" {
                return try LyricsTestFixtures.response(LyricsTestFixtures.record(id: 1, artist: "Wrong Artist"))
            }
            return try LyricsTestFixtures.response([
                LyricsTestFixtures.record(id: 2, title: "Paper Satellites (Slowed)"),
                LyricsTestFixtures.record(id: 3, duration: 180),
                LyricsTestFixtures.record(id: 4, duration: 201)
            ])
        }
        let result = try await makeService(transport).lyrics(for: LyricsTestFixtures.track)
        XCTAssertEqual(result.sourceID, 4)
        let requests = await transport.requests
        XCTAssertTrue(requests.contains { $0.url?.path == "/api/search" })
        XCTAssertTrue(requests.allSatisfy { LyricsTestFixtures.items($0)["q"] == nil })
    }

    func testArtistOrderAlternativeCanFindTheExactRecording() async throws {
        var track = LyricsTestFixtures.track
        track.artists = ["Test Singer", "Second Singer"]
        let transport = LyricsStubTransport { request, _ in
            if LyricsTestFixtures.items(request)["artist_name"] == "Second Singer, Test Singer" {
                return try LyricsTestFixtures.response(LyricsTestFixtures.record(artist: "Second Singer, Test Singer"))
            }
            return LRCHTTPResponse(statusCode: 404)
        }
        let result = try await makeService(transport).lyrics(for: track)
        XCTAssertEqual(result.kind, .synced)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/api/get" })
    }

    func testConfirmedMissingHasAShortNegativeCache() async throws {
        let clock = LyricsTestClock()
        let transport = LyricsStubTransport { request, _ in
            request.url?.path == "/api/get" ? LRCHTTPResponse(statusCode: 404) : try LyricsTestFixtures.response([])
        }
        var configuration = LRCLyricsService.CacheConfiguration()
        configuration.negativeLifetime = 10
        let service = makeService(transport, cache: configuration, clock: clock)
        let first = try await service.lyrics(for: LyricsTestFixtures.track)
        XCTAssertEqual(first.kind, .unavailable)
        let originalCount = await transport.requests.count
        _ = try await service.lyrics(for: LyricsTestFixtures.track)
        let cachedCount = await transport.requests.count
        XCTAssertEqual(cachedCount, originalCount)
        clock.advance(11)
        _ = try await service.lyrics(for: LyricsTestFixtures.track)
        let refreshedCount = await transport.requests.count
        XCTAssertEqual(refreshedCount, originalCount * 2)
    }

    func testMissingArtistMetadataDoesNotSearchOtherRecordings() async throws {
        var track = LyricsTestFixtures.track
        track.artists = []
        let transport = LyricsStubTransport { _, _ in throw URLError(.badURL) }
        let result = try await makeService(transport).lyrics(for: track)
        XCTAssertEqual(result.kind, .unavailable)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testServiceUnavailableAndNetworkFailuresAreErrorsAndNotNegativeCached() async throws {
        for failure in [503, 0] {
            let transport = LyricsStubTransport { _, index in
                if index == 0 {
                    if failure == 0 { throw URLError(.cannotFindHost) }
                    return LRCHTTPResponse(statusCode: failure)
                }
                return try LyricsTestFixtures.response(LyricsTestFixtures.record())
            }
            let service = makeService(transport)
            do {
                _ = try await service.lyrics(for: LyricsTestFixtures.track)
                XCTFail("Provider failure must throw")
            } catch {
                XCTAssertTrue(error is MusicServiceError)
            }
            let activity = await service.activity
            XCTAssertEqual(activity.cachedRecordings, 0)
            let retry = try await service.lyrics(for: LyricsTestFixtures.track)
            XCTAssertEqual(retry.kind, .synced)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testRateLimitHonorsRetryAfterWithoutCachingMissing() async throws {
        let clock = LyricsTestClock()
        let transport = LyricsStubTransport { _, index in
            if index == 0 { return LRCHTTPResponse(statusCode: 429, retryAfter: "60") }
            return try LyricsTestFixtures.response(LyricsTestFixtures.record())
        }
        let service = makeService(transport, clock: clock)
        for _ in 0..<2 {
            do {
                _ = try await service.lyrics(for: LyricsTestFixtures.track)
                XCTFail("Expected a rate-limit error")
            } catch MusicServiceError.rateLimited { }
        }
        let blockedRequests = await transport.requests
        XCTAssertEqual(blockedRequests.count, 1)
        let activity = await service.activity
        XCTAssertEqual(activity.cachedRecordings, 0)
        clock.advance(61)
        let result = try await service.lyrics(for: LyricsTestFixtures.track)
        XCTAssertEqual(result.kind, .synced)
    }

    func testMalformedJSONAndSearchHTTP404AreErrors() async throws {
        let malformed = LyricsStubTransport { _, _ in LRCHTTPResponse(data: Data("{".utf8), statusCode: 200) }
        do {
            _ = try await makeService(malformed).lyrics(for: LyricsTestFixtures.track)
            XCTFail("Malformed JSON must throw")
        } catch MusicServiceError.invalidResponse { }

        let missingEndpoint = LyricsStubTransport { _, _ in LRCHTTPResponse(statusCode: 404) }
        do {
            _ = try await makeService(missingEndpoint).lyrics(for: LyricsTestFixtures.track)
            XCTFail("A missing search endpoint is not a missing lyric")
        } catch {
            XCTAssertTrue(error is MusicServiceError)
        }
    }

    func testMalformedMatchedLRCIsAnErrorRatherThanACachedMiss() async throws {
        let record = LyricsTestFixtures.record(synced: "[00:99]Invalid synthetic timestamp")
        let transport = LyricsStubTransport { request, _ in
            if request.url?.path == "/api/get" { return try LyricsTestFixtures.response(record) }
            return try LyricsTestFixtures.response([record])
        }
        let service = makeService(transport)
        do { _ = try await service.lyrics(for: LyricsTestFixtures.track); XCTFail("Expected an invalid-data error") }
        catch MusicServiceError.invalidResponse { }
        let activity = await service.activity
        XCTAssertEqual(activity.cachedRecordings, 0)
    }

    func testLookupRequestBudgetAndUnicodeQueryEncoding() async throws {
        var track = LyricsTestFixtures.track
        track.title = "नई सुबह + Dawn (Official Video)"
        track.artists = ["First Singer", "Second Singer", "Third Singer"]
        let transport = LyricsStubTransport { request, _ in
            request.url?.path == "/api/get" ? LRCHTTPResponse(statusCode: 404) : try LyricsTestFixtures.response([])
        }
        let result = try await makeService(transport).lyrics(for: track)
        XCTAssertEqual(result.kind, .unavailable)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 10)
        XCTAssertTrue(requests.contains { $0.url?.path == "/api/search" })
        XCTAssertTrue(requests.first?.url?.absoluteString.contains("%2B") == true)
        XCTAssertEqual(LyricsTestFixtures.items(try XCTUnwrap(requests.first))["track_name"], track.title)
    }

    func testHTTPDateRetryAfterAndOversizedPayloadAreHandled() async throws {
        let clock = LyricsTestClock()
        let transport = LyricsStubTransport { _, index in
            if index == 0 { return LRCHTTPResponse(statusCode: 429, retryAfter: "Thu, 01 Jan 1970 00:18:20 GMT") }
            return try LyricsTestFixtures.response(LyricsTestFixtures.record())
        }
        let service = makeService(transport, clock: clock)
        for _ in 0..<2 {
            do { _ = try await service.lyrics(for: LyricsTestFixtures.track); XCTFail("Expected cooldown") }
            catch MusicServiceError.rateLimited { }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        clock.advance(101)
        let result = try await service.lyrics(for: LyricsTestFixtures.track)
        XCTAssertEqual(result.kind, .synced)

        let oversized = LyricsStubTransport { _, _ in
            LRCHTTPResponse(data: Data(count: LRCURLSessionTransport.maximumResponseBytes + 1), statusCode: 200)
        }
        do { _ = try await makeService(oversized).lyrics(for: LyricsTestFixtures.track); XCTFail("Expected size limit") }
        catch MusicServiceError.invalidResponse { }
    }

    func testPlainInstrumentalAndImplausibleTimingRemainDistinct() async throws {
        let cases: [(LRCLIBRecord, LyricsKind)] = [
            (LyricsTestFixtures.record(plain: "Only synthetic prose", synced: nil), .plain),
            (LyricsTestFixtures.record(instrumental: true, synced: nil), .instrumental),
            (LyricsTestFixtures.record(plain: "Only synthetic prose", synced: "[20:00]A late invented phrase"), .plain)
        ]
        for (record, expected) in cases {
            let transport = LyricsStubTransport { _, _ in try LyricsTestFixtures.response(record) }
            let document = try await makeService(transport).lyrics(for: LyricsTestFixtures.track)
            XCTAssertEqual(document.kind, expected)
            XCTAssertTrue(document.lines.isEmpty)
        }
    }

    func testUnknownDurationDoesNotVendUnverifiedTiming() async throws {
        var track = LyricsTestFixtures.track
        track.duration = nil
        let transport = LyricsStubTransport { request, _ in
            if request.url?.path == "/api/get" { return try LyricsTestFixtures.response(LyricsTestFixtures.record()) }
            return try LyricsTestFixtures.response([LyricsTestFixtures.record()])
        }
        let document = try await makeService(transport).lyrics(for: track)
        XCTAssertEqual(document.kind, .plain)
        XCTAssertTrue(document.lines.isEmpty)
        XCTAssertFalse(document.plainText?.isEmpty ?? true)
    }

    func testCoalescedCallersShareARequestAndOneCancellationDoesNotCancelTheOther() async throws {
        let gate = LyricsTestGate()
        let transport = LyricsStubTransport { _, _ in
            await gate.wait()
            return try LyricsTestFixtures.response(LyricsTestFixtures.record())
        }
        let service = makeService(transport)
        let first = Task { try await service.lyrics(for: LyricsTestFixtures.track) }
        var otherTrack = LyricsTestFixtures.track
        otherTrack.id = "other-id"
        let secondTrack = otherTrack
        let second = Task { try await service.lyrics(for: secondTrack) }
        try await LyricsTestFixtures.waitForWaiters(2, service: service)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled waiter completed") }
        catch is CancellationError { }
        await gate.open()
        let result = try await second.value
        XCTAssertEqual(result.trackID, secondTrack.id)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testLastCancellationCancelsWorkAndCannotPopulateTheCache() async throws {
        let transport = LyricsStubTransport { _, _ in
            try await Task.sleep(for: .seconds(20))
            return try LyricsTestFixtures.response(LyricsTestFixtures.record())
        }
        let service = makeService(transport)
        let task = Task { try await service.lyrics(for: LyricsTestFixtures.track) }
        try await LyricsTestFixtures.waitForWaiters(1, service: service)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let activity = await service.activity
        XCTAssertEqual(activity.activeLookups, 0)
        XCTAssertEqual(activity.cachedRecordings, 0)
    }

    func testCacheIsLRUBoundedAndPositiveEntriesExpire() async throws {
        let clock = LyricsTestClock()
        let transport = LyricsStubTransport { request, _ in
            let title = LyricsTestFixtures.items(request)["track_name"] ?? ""
            return try LyricsTestFixtures.response(LyricsTestFixtures.record(title: title))
        }
        var configuration = LRCLyricsService.CacheConfiguration()
        configuration.capacity = 2
        configuration.positiveLifetime = 100
        let service = makeService(transport, cache: configuration, clock: clock)
        var second = LyricsTestFixtures.track
        second.title = "Second Synthetic Title"
        var third = LyricsTestFixtures.track
        third.title = "Third Synthetic Title"
        _ = try await service.lyrics(for: LyricsTestFixtures.track)
        _ = try await service.lyrics(for: second)
        _ = try await service.lyrics(for: LyricsTestFixtures.track)
        _ = try await service.lyrics(for: third)
        _ = try await service.lyrics(for: LyricsTestFixtures.track)
        let beforeEvictedRead = await transport.requests.count
        XCTAssertEqual(beforeEvictedRead, 3)
        _ = try await service.lyrics(for: second)
        let afterEvictedRead = await transport.requests.count
        XCTAssertEqual(afterEvictedRead, 4)
        let activity = await service.activity
        XCTAssertEqual(activity.cachedRecordings, 2)
        clock.advance(101)
        _ = try await service.lyrics(for: second)
        let afterExpiry = await transport.requests.count
        XCTAssertEqual(afterExpiry, 5)
    }

    func testMemoryAndInFlightLimitsAreEnforced() async throws {
        let transport = LyricsStubTransport { _, _ in try LyricsTestFixtures.response(LyricsTestFixtures.record()) }
        var smallCache = LRCLyricsService.CacheConfiguration()
        smallCache.maximumBytes = 1
        let uncached = makeService(transport, cache: smallCache)
        _ = try await uncached.lyrics(for: LyricsTestFixtures.track)
        let empty = await uncached.activity
        XCTAssertEqual(empty.cachedBytes, 0)

        let gate = LyricsTestGate()
        let blocked = LyricsStubTransport { _, _ in
            await gate.wait()
            return try LyricsTestFixtures.response(LyricsTestFixtures.record())
        }
        var limited = LRCLyricsService.CacheConfiguration()
        limited.maximumConcurrentLookups = 1
        limited.maximumWaitersPerLookup = 1
        let service = makeService(blocked, cache: limited)
        let first = Task { try await service.lyrics(for: LyricsTestFixtures.track) }
        try await LyricsTestFixtures.waitForWaiters(1, service: service)
        for differentSignature in [false, true] {
            var track = LyricsTestFixtures.track
            if differentSignature { track.title = "A Different Synthetic Title" }
            do { _ = try await service.lyrics(for: track); XCTFail("Expected bounded work") }
            catch { XCTAssertTrue(error is MusicServiceError) }
        }
        await gate.open()
        _ = try await first.value
    }

    private func makeService(_ transport: LyricsStubTransport,
                             cache: LRCLyricsService.CacheConfiguration = LRCLyricsService.CacheConfiguration(),
                             clock: LyricsTestClock = LyricsTestClock()) -> LRCLyricsService {
        LRCLyricsService(transport: transport, cacheConfiguration: cache,
                         clientConfiguration: LyricsTestFixtures.clientConfiguration(), now: { clock.now() })
    }
}
