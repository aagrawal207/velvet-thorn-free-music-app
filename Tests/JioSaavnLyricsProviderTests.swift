import XCTest
@testable import GanaBajana

@MainActor
final class JioSaavnLyricsProviderTests: XCTestCase {
    private var candidate: Track {
        var track = LyricsVariantFixtures.track
        track.id = "saavn:exactSong"
        track.isAudioRecording = true
        return track
    }

    func testExactCrossSourceMatchRebindsOnlyConsumerIdentityAndRetainsCredit() async throws {
        let match = candidate
        let calls = CatalogTestRecorder<Track>()
        let provider = JioSaavnLyricsProvider(search: { _ in [match] }, fetch: { track in
            calls.record(track)
            return LyricsDocument(trackID: track.id, kind: .plain, plainText: LyricsVariantFixtures.nativeText,
                                  source: "JioSaavn", attributionText: "Lyrics powered by JioSaavn")
        })
        let document = try await provider.lyrics(for: LyricsVariantFixtures.track)
        XCTAssertEqual(calls.values, [match])
        XCTAssertEqual(document.trackID, LyricsVariantFixtures.track.id)
        XCTAssertEqual(document.providerTrackID, "saavn:exactSong")
        XCTAssertEqual(document.source, "JioSaavn")
        XCTAssertEqual(document.attributionText, "Lyrics powered by JioSaavn")
        XCTAssertNil(document.sourceURL, "A provider song URL must not be invented from an opaque id")
        XCTAssertEqual(document.kind, .plain)
        XCTAssertTrue(document.lines.isEmpty)
        XCTAssertEqual(LyricsVariant(document).script, .gurmukhi)
    }

    func testWrongRecordingDurationAlbumArtistVersionLanguageAndMissingDurationAreRejected() async throws {
        let track = LyricsVariantFixtures.track
        var rejected: [Track] = []
        var wrong = candidate
        wrong.title += " (Live)"; rejected.append(wrong)
        wrong = candidate; wrong.artists = ["Other Singer"]; rejected.append(wrong)
        wrong = candidate; wrong.artists.append("Another Singer"); rejected.append(wrong)
        wrong = candidate; wrong.albumTitle = "Different Release"; rejected.append(wrong)
        wrong = candidate; wrong.duration = 203; rejected.append(wrong)
        wrong = candidate; wrong.duration = nil; rejected.append(wrong)
        wrong = candidate; wrong.isAudioRecording = false; rejected.append(wrong)
        wrong = candidate; wrong.id = "gaana:foreign"; rejected.append(wrong)
        for rejectedTrack in rejected {
            XCTAssertFalse(JioSaavnLyricsProvider.matches(rejectedTrack, to: track))
        }
        let rejectedCandidates = rejected
        let calls = CatalogTestRecorder<Int>()
        let provider = JioSaavnLyricsProvider(search: { _ in rejectedCandidates }, fetch: { track in
            calls.record(1)
            return LyricsVariantFixtures.native(track)
        })
        let result = try await provider.lyrics(for: track)
        XCTAssertEqual(result.kind, .unavailable)
        XCTAssertTrue(calls.values.isEmpty)
        var hindi = track
        hindi.language = .hindi
        wrong = candidate; wrong.language = .english
        XCTAssertFalse(JioSaavnLyricsProvider.matches(wrong, to: hindi))
        var noDuration = track
        noDuration.duration = nil
        XCTAssertFalse(JioSaavnLyricsProvider.matches(candidate, to: noDuration))
    }

    func testAmbiguousRecordingsAreNotChosenAndDuplicateSearchRowsDoNotAddRequests() async throws {
        let first = candidate
        var second = first
        second.id = "saavn:secondSong"
        let another = second
        let calls = CatalogTestRecorder<Int>()
        let ambiguous = JioSaavnLyricsProvider(search: { _ in [first, another] }, fetch: { track in
            calls.record(1)
            return LyricsDocument(trackID: track.id, kind: .plain, plainText: "Published sample", source: "JioSaavn")
        })
        let missing = try await ambiguous.lyrics(for: LyricsVariantFixtures.track)
        XCTAssertEqual(missing.kind, .unavailable)
        XCTAssertTrue(calls.values.isEmpty)
        let duplicate = JioSaavnLyricsProvider(search: { _ in [first, first] }, fetch: { track in
            calls.record(1)
            return LyricsDocument(trackID: track.id, kind: .plain, plainText: "Published sample", source: "JioSaavn")
        })
        let found = try await duplicate.lyrics(for: LyricsVariantFixtures.track)
        XCTAssertEqual(found.kind, .plain)
        XCTAssertEqual(calls.values, [1])
    }

    func testCancellationAfterSearchCannotStartLyricsRequest() async throws {
        let gate = AppModelRequestGate<Track, [Track]>()
        addTeardownBlock { await gate.close() }
        let calls = CatalogTestRecorder<Int>()
        let provider = JioSaavnLyricsProvider(search: { try await gate.receive($0) }, fetch: { track in
            calls.record(1)
            return LyricsVariantFixtures.native(track)
        })
        let pending = Task { try await provider.lyrics(for: LyricsVariantFixtures.track) }
        let request = try await gate.request(at: 0)
        pending.cancel()
        try await gate.complete(request, with: .success([candidate]))
        do { _ = try await pending.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testSourceRecordingMismatchAndTransportErrorDoNotBecomeNoData() async throws {
        let match = candidate
        let fetches: [JioSaavnLyricsProvider.Fetch] = [
            { _ in throw MusicServiceError.rateLimited },
            { _ in LyricsDocument(trackID: "saavn:wrong", kind: .plain, plainText: "Wrong recording", source: "JioSaavn") }
        ]
        for fetch in fetches {
            let provider = JioSaavnLyricsProvider(search: { _ in [match] }, fetch: fetch)
            do { _ = try await provider.lyrics(for: LyricsVariantFixtures.track); XCTFail("Expected error") }
            catch { XCTAssertTrue(error is LyricsLookupError || error is MusicServiceError) }
        }
    }

    func testExistingTransportFetchesPublishedLyricsWithCreditAndNoTrackingRequest() async throws {
        let mock = CatalogMockSession { _ in
            CatalogStub(data: Data(#"{"lyrics":"ਕਾਗਜ਼ ਦੇ ਤਾਰੇ<br>ਨਵੀਂ ਸਵੇਰ","lyrics_copyright":"Publisher &amp; Songwriter","script_tracking_url":"https://example.org/do-not-fetch"}"#.utf8))
        }
        defer { mock.close() }
        let provider = JioSaavnLyricsProvider(catalog: JioSaavnCatalogService(session: mock.session))
        let result = try await provider.lyrics(for: candidate)
        XCTAssertEqual(result.plainText, "ਕਾਗਜ਼ ਦੇ ਤਾਰੇ\nਨਵੀਂ ਸਵੇਰ")
        XCTAssertEqual(result.attributionText, "Publisher & Songwriter")
        XCTAssertEqual(mock.state.requests.count, 1)
        let request = try XCTUnwrap(mock.state.requests.first)
        XCTAssertEqual(request.url?.host, "www.jiosaavn.com")
        XCTAssertEqual(request.url?.path, "/api.php")
        XCTAssertEqual(LyricsTestFixtures.items(request)["__call"], "lyrics.getLyrics")
        XCTAssertEqual(LyricsTestFixtures.items(request)["lyrics_id"], "exactSong")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(result.attributionURL)
    }

    func testFailureEnvelopeAndEmptyLyricsAreNoDataButMalformedPayloadIsAnError() async throws {
        for payload in [#"{"status":"failure","error":{"msg":"Lyrics unavailable"}}"#, #"{"lyrics":"  "}"#] {
            let mock = CatalogMockSession { _ in CatalogStub(data: Data(payload.utf8)) }
            defer { mock.close() }
            let provider = JioSaavnLyricsProvider(catalog: JioSaavnCatalogService(session: mock.session))
            let result = try await provider.lyrics(for: candidate)
            XCTAssertEqual(result.kind, .unavailable)
        }
        for payload in [#"{"unexpected":true}"#, #"{"lyrics":123}"#] {
            let mock = CatalogMockSession { _ in CatalogStub(data: Data(payload.utf8)) }
            defer { mock.close() }
            let provider = JioSaavnLyricsProvider(catalog: JioSaavnCatalogService(session: mock.session))
            do { _ = try await provider.lyrics(for: candidate); XCTFail("Malformed payload became absence") }
            catch { XCTAssertTrue(error is MusicServiceError) }
        }
    }

    func testOversizedLyricsAndCopyrightAreRejected() throws {
        for value in [
            ["lyrics": String(repeating: "x", count: LRCParser.maximumSourceBytes + 1)],
            ["lyrics": "Published sample", "lyrics_copyright": String(repeating: "c", count: 4_097)]
        ] {
            let json = try CatalogJSON.decode(JSONSerialization.data(withJSONObject: value))
            XCTAssertThrowsError(try JioSaavnLyricsProvider.document(JioSaavnResponse(json: json, fetchedAt: Date()), for: candidate))
        }
    }
}
