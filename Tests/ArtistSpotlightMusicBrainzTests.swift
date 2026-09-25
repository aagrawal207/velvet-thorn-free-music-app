import XCTest
@testable import GanaBajana

enum ArtistSpotlightMusicBrainzFixtures {
    static let recordingID = "11111111-1111-4111-8111-111111111111"
    static let workID = "22222222-2222-4222-8222-222222222222"

    static func recording(id: String = recordingID, language: String? = "eng", attributes: [CatalogJSON] = []) -> CatalogJSON {
        ["id": .string(id), "title": .string(LyricsFallbackFixtures.track.title), "length": 200_000, "video": false,
         "disambiguation": "", "artist-credit": [["name": "Test Singer"]],
         "releases": [["country": "IN", "text-representation": ["language": "tam"]]],
         "relations": [["type": "performance", "target-type": "work", "direction": "forward", "attributes": .array(attributes),
                        "work": work(language: language)]]]
    }

    static func work(language: String? = "eng") -> CatalogJSON {
        var value: [String: CatalogJSON] = ["id": .string(workID), "type": "Song", "title": .string(LyricsFallbackFixtures.track.title)]
        if let language {
            value["language"] = .string(language)
            value["languages"] = [.string(language)]
        }
        return .object(value)
    }

    static func search(_ records: [CatalogJSON], count: Int? = nil) -> CatalogJSON {
        ["count": .number(Double(count ?? records.count)), "recordings": .array(records)]
    }
}

@MainActor
final class ArtistSpotlightMusicBrainzTests: XCTestCase {
    func testRecordingMatchesTitleCreditsDurationAndVersionRatherThanScoreOrCountry() {
        let track = LyricsFallbackFixtures.track
        let record = ArtistSpotlightMusicBrainzFixtures.recording()
        XCTAssertEqual(ArtistSpotlightMusicBrainz.matchedRecording(in: ArtistSpotlightMusicBrainzFixtures.search([record]), for: track),
                       ArtistSpotlightMusicBrainzFixtures.recordingID)
        var collaboration = track
        collaboration.credits.insert(ArtistCredit(name: "A. R. Rahman"), at: 0)
        XCTAssertEqual(ArtistSpotlightMusicBrainz.matchedRecording(in: ArtistSpotlightMusicBrainzFixtures.search([record]), for: collaboration),
                       ArtistSpotlightMusicBrainzFixtures.recordingID, "A recording can credit a singer after its composer")
        let mutations: [(String, CatalogJSON)] = [
            ("id", "not-an-mbid"), ("title", "Paper Satellites (Live)"), ("length", 220_000),
            ("artist-credit", [["name": "Another Singer"]]), ("disambiguation", "radio edit"), ("video", true),
        ]
        for (key, value) in mutations {
            var wrong = record.object
            wrong[key] = value
            XCTAssertNil(ArtistSpotlightMusicBrainz.matchedRecording(in: ArtistSpotlightMusicBrainzFixtures.search([.object(wrong)]), for: track), key)
        }
        var noDuration = track
        noDuration.duration = nil
        XCTAssertNil(ArtistSpotlightMusicBrainz.matchedRecording(in: ArtistSpotlightMusicBrainzFixtures.search([record]), for: noDuration))
    }

    func testAmbiguousTruncatedAndMismatchedRecordingResponsesCannotSupplyLanguage() {
        let track = LyricsFallbackFixtures.track
        let record = ArtistSpotlightMusicBrainzFixtures.recording()
        let other = ArtistSpotlightMusicBrainzFixtures.recording(id: "33333333-3333-4333-8333-333333333333")
        XCTAssertNil(ArtistSpotlightMusicBrainz.matchedRecording(in: ArtistSpotlightMusicBrainzFixtures.search([record, other]), for: track))
        XCTAssertNil(ArtistSpotlightMusicBrainz.matchedRecording(in: ArtistSpotlightMusicBrainzFixtures.search([record], count: 2), for: track))
        XCTAssertNil(ArtistSpotlightMusicBrainz.matchedRecording(in: ArtistSpotlightMusicBrainzFixtures.search([record], count: 0), for: track))
        XCTAssertNil(ArtistSpotlightMusicBrainz.workLanguage(in: other, recordingID: ArtistSpotlightMusicBrainzFixtures.recordingID, for: track))
    }

    func testUnambiguousPerformanceWorkLanguageSupportsIndianLanguagesAndEnglish() {
        for (code, language) in [("hin", ArtistSongLanguage.hindi), ("tam", .tamil), ("tel", .telugu), ("eng", .english), ("ben", .bengali)] {
            let result = ArtistSpotlightMusicBrainz.workLanguage(in: ArtistSpotlightMusicBrainzFixtures.recording(language: code),
                recordingID: ArtistSpotlightMusicBrainzFixtures.recordingID, for: LyricsFallbackFixtures.track)
            XCTAssertEqual(result?.language, language)
            XCTAssertEqual(result?.source, .musicBrainzWork(recordingID: ArtistSpotlightMusicBrainzFixtures.recordingID,
                                                           workID: ArtistSpotlightMusicBrainzFixtures.workID))
        }
    }

    func testInstrumentalMultipleWorksMixedLanguagesAndReleaseLanguageAreNotProof() {
        let id = ArtistSpotlightMusicBrainzFixtures.recordingID
        let track = LyricsFallbackFixtures.track
        XCTAssertNil(ArtistSpotlightMusicBrainz.workLanguage(in: ArtistSpotlightMusicBrainzFixtures.recording(attributes: ["instrumental"]), recordingID: id, for: track))
        var record = ArtistSpotlightMusicBrainzFixtures.recording().object
        let relation = record["relations"]!.array[0]
        record["relations"] = [relation, relation]
        XCTAssertNil(ArtistSpotlightMusicBrainz.workLanguage(in: .object(record), recordingID: id, for: track))
        let ambiguous: [(CatalogJSON, ArtistSongLanguageResult?)] = [
            (["eng", "hin"], .unclassified(.conflictingEvidence)), ([], nil), (["eng", 7], nil),
        ]
        for (languages, expected) in ambiguous {
            var work = relation["work"].object
            work["languages"] = languages
            work["language"] = .null
            var changed = relation.object
            changed["work"] = .object(work)
            record["relations"] = [.object(changed)]
            XCTAssertEqual(ArtistSpotlightMusicBrainz.workLanguage(in: .object(record), recordingID: id, for: track), expected)
        }
    }

    func testClientUsesSharedRateLimitIdentifiableAnonymousRequestsAndMemoryCache() async throws {
        let clock = CatalogTestClock()
        let times = CatalogTestRecorder<Date>()
        let limiter = MusicBrainzRateLimiter(now: { clock.now }, sleep: { clock.advance($0) })
        let recording = try ArtistSpotlightMusicBrainzFixtures.recording().encoded()
        let search = try ArtistSpotlightMusicBrainzFixtures.search([ArtistSpotlightMusicBrainzFixtures.recording()]).encoded()
        let mock = CatalogMockSession { request in
            times.record(clock.now)
            return CatalogStub(data: request.url?.path.hasSuffix(ArtistSpotlightMusicBrainzFixtures.recordingID) == true ? recording : search)
        }
        defer { mock.close() }
        let contact = try XCTUnwrap(URL(string: "https://example.org/support"))
        let first = ArtistSpotlightMusicBrainz(contactURL: contact, session: mock.session, limiter: limiter, now: { clock.now })
        let second = ArtistSpotlightMusicBrainz(contactURL: contact, session: mock.session, limiter: limiter, now: { clock.now })
        let result = try await first.language(for: LyricsFallbackFixtures.track)
        XCTAssertEqual(result?.language, .english)
        _ = try await first.language(for: LyricsFallbackFixtures.track)
        XCTAssertEqual(mock.state.requests.count, 2, "The second lookup uses only memory")
        _ = try await second.language(for: LyricsFallbackFixtures.track)
        XCTAssertEqual(times.values.count, 4)
        for (earlier, later) in zip(times.values, times.values.dropFirst()) { XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 1) }
        for request in mock.state.requests {
            XCTAssertEqual(request.url?.host, "musicbrainz.org")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Breezy/1.0 (https://example.org/support)")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testRateLimitCooldownPreventsMoreRequestsWithinTheLookupDeadline() async throws {
        let clock = CatalogTestClock()
        let limiter = MusicBrainzRateLimiter(now: { clock.now }, sleep: { clock.advance($0) })
        let mock = CatalogMockSession { _ in CatalogStub(status: 503, headers: ["Retry-After": "30"], data: Data("{}".utf8)) }
        defer { mock.close() }
        let service = ArtistSpotlightMusicBrainz(contactURL: try XCTUnwrap(URL(string: "https://example.org/support")),
                                                session: mock.session, limiter: limiter, now: { clock.now })
        for _ in 0..<2 {
            do { _ = try await service.language(for: LyricsFallbackFixtures.track); XCTFail("Expected cooldown") }
            catch { }
        }
        XCTAssertEqual(mock.state.requests.count, 1)
    }

    func testSearchEscapesLuceneSyntaxInsteadOfChangingTheQueryMeaning() {
        XCTAssertEqual(ArtistSpotlightMusicBrainz.quoted("A+B / \"Live\""), "\"A\\+B \\/ \\\"Live\\\"\"")
    }
}
