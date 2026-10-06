import XCTest
@testable import GanaBajana

@MainActor
final class LyricsVariantProviderTests: XCTestCase {
    func testLRCLIBSearchKeepsExactPunjabiScriptsAndUsesOnlyTwoDocumentedQueries() async throws {
        let records = [
            LyricsTestFixtures.record(id: 101, plain: LyricsVariantFixtures.nativeText, synced: nil),
            LyricsTestFixtures.record(id: 102, synced: "[00:01]Kaagaz de taare ambar vich"),
            LyricsTestFixtures.record(id: 103, title: "Paper Satellites (Live)", plain: LyricsVariantFixtures.nativeText, synced: nil),
            LyricsTestFixtures.record(id: 104, artist: "Wrong Singer", plain: LyricsVariantFixtures.nativeText, synced: nil),
            LyricsTestFixtures.record(id: 105, duration: 225, plain: LyricsVariantFixtures.nativeText, synced: nil)
        ]
        let transport = LyricsStubTransport { _, _ in try LyricsTestFixtures.response(records) }
        let service = LRCLyricsService(transport: transport, clientConfiguration: LyricsTestFixtures.clientConfiguration())
        let documents = try await service.lyricVariants(for: LyricsVariantFixtures.track)
        XCTAssertEqual(Set(documents.compactMap(\.sourceID)), [101, 102])
        XCTAssertEqual(Set(documents.map { LyricsVariant($0).script }), [.gurmukhi, .latin])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.path, "/api/search")
            XCTAssertEqual(LyricsTestFixtures.items(request)["track_name"], "Paper Satellites")
            XCTAssertNil(LyricsTestFixtures.items(request)["language"])
            XCTAssertNil(LyricsTestFixtures.items(request)["script"])
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
        XCTAssertEqual(documents.first(where: { $0.sourceID == 101 })?.plainText, LyricsVariantFixtures.nativeText)
        XCTAssertEqual(documents.first(where: { $0.sourceID == 101 })?.sourceURL?.absoluteString,
                       "https://lrclib.net/api/get/101")
    }

    func testVariantDiscoveryDoesNotRelaxSameScriptAmbiguityOrUnknownDuration() async throws {
        let client = LRCLIBClient(transport: LyricsStubTransport { _, _ in throw MusicServiceError.invalidResponse })
        let first = LyricsTestFixtures.record(id: 1)
        let conflict = LyricsTestFixtures.record(id: 2, synced: "[00:09]Conflicting synthetic timing")
        let native = LyricsTestFixtures.record(id: 3, plain: LyricsVariantFixtures.nativeText, synced: nil)
        let documents = await client.variantDocuments(in: [first, conflict, native], for: LyricsVariantFixtures.track)
        XCTAssertEqual(documents.compactMap(\.sourceID), [3])
        XCTAssertNil(LyricsMatcher.bestMatch(in: [first, conflict], for: LyricsVariantFixtures.track))
        var noDuration = LyricsVariantFixtures.track
        noDuration.duration = nil
        let missing = try await client.variants(noDuration)
        XCTAssertTrue(missing.isEmpty)
        let unknown = await client.variantDocuments(in: [native], for: noDuration)
        XCTAssertTrue(unknown.isEmpty)
    }

    func testPlainOriginalWithinATimedLatinRecordNeverBorrowsTiming() async throws {
        let client = LRCLIBClient(transport: LyricsStubTransport { _, _ in throw MusicServiceError.invalidResponse })
        let record = LyricsTestFixtures.record(id: 7, plain: LyricsVariantFixtures.nativeText,
                                              synced: "[00:03]Kaagaz de taare ambar vich")
        let documents = await client.variantDocuments(in: [record], for: LyricsVariantFixtures.track)
        XCTAssertEqual(documents.count, 2)
        let plain = try XCTUnwrap(documents.first { $0.kind == .plain })
        let timed = try XCTUnwrap(documents.first { $0.kind == .synced })
        XCTAssertTrue(plain.lines.isEmpty)
        XCTAssertEqual(plain.plainText, LyricsVariantFixtures.nativeText)
        XCTAssertEqual(timed.lines.first?.time, 3)
        XCTAssertEqual(timed.sourceID, plain.sourceID)
        XCTAssertNotEqual(timed.selectionID, plain.selectionID)
    }

    func testLRCLIBCancellationAndMalformedSearchAreNotSuccessfulAbsence() async throws {
        let gate = LyricsTestGate()
        addTeardownBlock { await gate.open() }
        let transport = LyricsStubTransport { _, _ in
            await gate.wait()
            try Task.checkCancellation()
            return try LyricsTestFixtures.response([LyricsTestFixtures.record()])
        }
        let service = LRCLyricsService(transport: transport, clientConfiguration: LyricsTestFixtures.clientConfiguration())
        let pending = Task { try await service.lyricVariants(for: LyricsVariantFixtures.track) }
        try await AppModelFixtures.eventually { await transport.requests.count == 1 }
        pending.cancel()
        await gate.open()
        do { _ = try await pending.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let bad = LRCLyricsService(transport: LyricsStubTransport { _, _ in
            LRCHTTPResponse(data: Data("{\"unexpected\":true}".utf8), statusCode: 200)
        })
        do { _ = try await bad.lyricVariants(for: LyricsVariantFixtures.track); XCTFail("Malformed search became empty") }
        catch { XCTAssertTrue(error is MusicServiceError) }
    }

    func testCombinedDiscoveryEnrichesAttributionAndCachesOnlyCompleteResults() async throws {
        let discovery = LyricsVariantDiscovery()
        let calls = CatalogTestRecorder<Int>()
        let baseline = LyricsVariantFixtureProvider(baseline: { track in
            calls.record(1)
            return LyricsDocument(trackID: track.id, kind: .plain, plainText: "Published sample", source: "JioSaavn")
        })
        let source = LyricsVariantFixtureProvider(discover: { track in
            calls.record(2)
            return [LyricsDocument(trackID: track.id, kind: .plain, plainText: "Published sample", source: "JioSaavn",
                                   attributionText: "Lyrics powered by JioSaavn", providerTrackID: "saavn:exact")]
        })
        let documents = try await discovery.documents(for: LyricsVariantFixtures.track, baseline: baseline, sources: [source])
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?.attributionText, "Lyrics powered by JioSaavn")
        XCTAssertEqual(documents.first?.providerTrackID, "saavn:exact")
        _ = try await discovery.documents(for: LyricsVariantFixtures.track, baseline: baseline, sources: [source])
        XCTAssertEqual(calls.values, [1, 2])

        let partial = LyricsVariantDiscovery()
        let failure = LyricsVariantFixtureProvider(discover: { _ in throw MusicServiceError.rateLimited })
        let available = try await partial.documents(for: LyricsVariantFixtures.track, baseline: baseline, sources: [failure])
        XCTAssertEqual(available.count, 1)
        let activity = await partial.activity
        XCTAssertEqual(activity.cachedRecordings, 0)
    }

    func testNoDataOutageWrongRecordingAndInstrumentalAreDistinct() async throws {
        let missing = LyricsVariantFixtureProvider(baseline: { LyricsDocument(trackID: $0.id, kind: .unavailable) }, discover: { _ in [] })
        let discovery = LyricsVariantDiscovery()
        let empty = try await discovery.documents(for: LyricsVariantFixtures.track, baseline: missing, sources: [missing])
        XCTAssertEqual(empty.first?.kind, .unavailable)
        for source in [
            LyricsVariantFixtureProvider(discover: { _ in throw MusicServiceError.rateLimited }),
            LyricsVariantFixtureProvider(discover: { _ in [LyricsDocument(trackID: "wrong", kind: .plain, plainText: "Other recording")] })
        ] {
            let discovery = LyricsVariantDiscovery()
            do { _ = try await discovery.documents(for: LyricsVariantFixtures.track, baseline: missing, sources: [source]); XCTFail("Expected error") }
            catch { XCTAssertTrue(error is LyricsLookupError) }
            let activity = await discovery.activity
            XCTAssertEqual(activity.cachedRecordings, 0)
        }
        let calls = CatalogTestRecorder<Int>()
        let instrumental = LyricsVariantFixtureProvider(baseline: { LyricsDocument(trackID: $0.id, kind: .instrumental) })
        let forbidden = LyricsVariantFixtureProvider(discover: { _ in calls.record(1); return [] })
        let result = try await LyricsVariantDiscovery().documents(for: LyricsVariantFixtures.track, baseline: instrumental, sources: [forbidden])
        XCTAssertEqual(result.first?.kind, .instrumental)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testCoalescedCancellationDoesNotCancelOtherWaitersAndLastCancellationCannotCache() async throws {
        let gate = AppModelRequestGate<Track, LyricsDocument>()
        addTeardownBlock { await gate.close() }
        let baseline = LyricsVariantFixtureProvider(baseline: { try await gate.receive($0) })
        let discovery = LyricsVariantDiscovery()
        let first = Task { try await discovery.documents(for: LyricsVariantFixtures.track, baseline: baseline, sources: []) }
        let request = try await gate.request(at: 0)
        let second = Task { try await discovery.documents(for: LyricsVariantFixtures.track, baseline: baseline, sources: []) }
        try await AppModelFixtures.eventually { await discovery.activity.waitingCallers == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        try await gate.complete(request, with: .success(LyricsVariantFixtures.native()))
        let result = try await second.value
        XCTAssertEqual(result.first?.plainText, LyricsVariantFixtures.nativeText)

        let cancelledDiscovery = LyricsVariantDiscovery()
        let last = Task { try await cancelledDiscovery.documents(for: LyricsVariantFixtures.track, baseline: baseline, sources: []) }
        let late = try await gate.request(at: 1)
        last.cancel()
        do { _ = try await last.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        try await gate.complete(late, with: .success(LyricsVariantFixtures.native()))
        let activity = await cancelledDiscovery.activity
        XCTAssertEqual(activity.cachedRecordings, 0)
        XCTAssertEqual(activity.activeLookups, 0)
    }

    func testVariantCacheHonorsCapacityBytesAndExpiry() async throws {
        let clock = LyricsTestClock()
        var configuration = LyricsVariantDiscovery.Configuration()
        configuration.capacity = 1
        configuration.lifetime = 10
        let discovery = LyricsVariantDiscovery(configuration: configuration, now: { clock.now() })
        let calls = CatalogTestRecorder<String>()
        let provider = LyricsVariantFixtureProvider(baseline: { track in calls.record(track.id); return LyricsVariantFixtures.native(track) })
        let track = LyricsVariantFixtures.track
        var next = track
        next.id = "another-id"
        _ = try await discovery.documents(for: track, baseline: provider, sources: [])
        _ = try await discovery.documents(for: next, baseline: provider, sources: [])
        _ = try await discovery.documents(for: track, baseline: provider, sources: [])
        XCTAssertEqual(calls.values.count, 3)
        clock.advance(11)
        _ = try await discovery.documents(for: track, baseline: provider, sources: [])
        XCTAssertEqual(calls.values.count, 4)
        let activity = await discovery.activity
        XCTAssertEqual(activity.cachedRecordings, 1)
        XCTAssertLessThanOrEqual(activity.cachedBytes, configuration.maximumBytes)
        configuration.maximumBytes = 1
        let tiny = LyricsVariantDiscovery(configuration: configuration)
        _ = try await tiny.documents(for: track, baseline: provider, sources: [])
        let tinyActivity = await tiny.activity
        XCTAssertEqual(tinyActivity.cachedRecordings, 0)
    }

    func testSourceTimeoutPreservesBaselineAndDoesNotCachePartialDiscovery() async throws {
        var configuration = LyricsVariantDiscovery.Configuration()
        configuration.sourceTimeout = 0.01
        let discovery = LyricsVariantDiscovery(configuration: configuration)
        let slow = LyricsVariantFixtureProvider(discover: { track in
            try await Task.sleep(for: .seconds(30))
            return [LyricsVariantFixtures.native(track)]
        })
        let documents = try await discovery.documents(for: LyricsVariantFixtures.track, baseline: LyricsVariantFixtureProvider(), sources: [slow])
        XCTAssertEqual(documents.first?.kind, .synced)
        let activity = await discovery.activity
        XCTAssertEqual(activity.cachedRecordings, 0)
    }

    func testCompositeDiscoversWithoutChangingLegacyFallbackOrderAndPreparesDurationOnly() async throws {
        let calls = CatalogTestRecorder<String>()
        let primary = LyricsVariantFixtureProvider(baseline: { track in
            calls.record("primary")
            return LyricsVariantFixtures.latin(track)
        }, discover: { track in
            calls.record("variants")
            XCTAssertEqual(track.duration, 200)
            XCTAssertEqual(track.title, LyricsVariantFixtures.track.title)
            return [LyricsVariantFixtures.native(track)]
        })
        let fallback = LyricsVariantFixtureProvider(baseline: { track in
            calls.record("fallback")
            return LyricsDocument(trackID: track.id, kind: .unavailable)
        }, discover: { _ in calls.record("fallbackVariants"); return [] })
        let extra = LyricsVariantFixtureProvider(discover: { _ in calls.record("extra"); return [] })
        let provider = CompositeLyricsProvider(primary: primary, fallback: fallback, prepareTrack: { track in
            var prepared = track
            prepared.duration = 200
            prepared.title = "Untrusted metadata title"
            return prepared
        }, additionalVariantSource: extra)
        var track = LyricsVariantFixtures.track
        track.duration = nil
        let baseline = try await provider.lyrics(for: track)
        XCTAssertEqual(baseline.kind, .synced)
        XCTAssertEqual(calls.values, ["primary"])
        let variants = try await provider.lyricVariants(for: track)
        XCTAssertEqual(Set(variants.map { LyricsVariant($0).script }), [.latin, .gurmukhi])
        XCTAssertTrue(calls.values.contains("variants"))
        XCTAssertTrue(calls.values.contains("fallbackVariants"))
        XCTAssertTrue(calls.values.contains("extra"))
        XCTAssertFalse(calls.values.contains("fallback"))
        XCTAssertNil(track.duration)
    }
}
