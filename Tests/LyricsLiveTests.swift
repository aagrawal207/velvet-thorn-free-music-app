import XCTest
@testable import GanaBajana

@MainActor
final class LyricsLiveTests: XCTestCase {
    func testRecordingLinkedYouTubeLyricsKeepTheirSourceAndRecordingIdentity() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1")
        let track = Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", artists: ["Arijit Singh"], duration: 262)
        let document = try await YouTubeMusicService().lyrics(for: track)
        XCTAssertEqual(document.trackID, track.id)
        guard document.kind != .unavailable else { throw XCTSkip("The provider currently has no linked lyrics for this recording.") }
        XCTAssertEqual(document.kind, .plain)
        XCTAssertFalse((document.plainText ?? "").isEmpty)
        XCTAssertTrue(document.lines.isEmpty, "Plain provider lyrics must not gain invented synchronization.")
        XCTAssertNotNil(document.providerSource)
        XCTAssertNotNil(document.matchedTitle)
        XCTAssertNotNil(document.matchedArtist)
        print("LYRICS LIVE linked recording=\(track.id) source=\(document.source) kind=\(document.kind)")
    }

    func testConfiguredMusicBrainzWorkLookupPreservesUnknownEvidence() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1")
        let service = try XCTUnwrap(ArtistSpotlightMusicBrainz.shared, "A public contact URL must enable the integrated provider.")
        let track = Track(id: "J7p4bzqLvCw", title: "Blinding Lights", artists: ["The Weeknd"], duration: 202)
        if let result = try await service.language(for: track) {
            guard case .identified(.english, .musicBrainzWork) = result else {
                return XCTFail("An identified result must be the matching English work: \(result)")
            }
        } else {
            print("LANGUAGE LIVE MusicBrainz returned no unambiguous work evidence; recording remains unclassified.")
        }
    }

    func testProductionRecordingMatches() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1",
                          "Set GANABAJANA_LIVE_TESTS=1 to contact the public LRCLIB API.")
        let tracks: [Track] = [
            Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", artists: ["Arijit Singh"],
                  albumTitle: "Aashiqui 2", duration: 262),
            Track(id: "NJAv_7lHUIU", title: "Kesariya (From \"Brahmastra\")", artists: ["Arijit Singh"],
                  albumTitle: "Kesariya (From \"Brahmastra\")", duration: 269),
            Track(id: "FOA9iyxsW_A", title: "AGAR TUM SAATH HO", artists: ["Arijit Singh", "Alka Yagnik"],
                  albumTitle: "Tamasha", duration: 342),
            Track(id: "J7p4bzqLvCw", title: "Blinding Lights", artists: ["The Weeknd"],
                  albumTitle: "After Hours", duration: 202),
            Track(id: "xTvyyoF_LZY", title: "Shape of You", artists: ["Ed Sheeran"],
                  albumTitle: "÷", duration: 234)
        ]
        let service = LRCLyricsService()
        for track in tracks {
            let document = try await service.lyrics(for: track)
            XCTAssertEqual(document.kind, .synced, "Expected verified timing for \(track.title)")
            XCTAssertNotNil(document.sourceID)
            XCTAssertNotNil(document.matchedTitle)
            XCTAssertNotNil(document.matchedArtist)
            XCTAssertFalse(document.lines.isEmpty)
            XCTAssertTrue(document.lines.allSatisfy { $0.time >= 0 && $0.time <= (track.duration ?? 0) })
        }
    }

    func testVerifiedPublicRecordIDsDecodeWithoutSavingLyricFixtures() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1",
                          "Set GANABAJANA_LIVE_TESTS=1 to contact the public LRCLIB API.")
        let transport = LRCURLSessionTransport()
        for id in [9_910_251, 11_918_452, 16_987_467, 511_842, 1_301_175] {
            let url = try XCTUnwrap(URL(string: "https://lrclib.net/api/get/\(id)"))
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("GanaBajana/1.0 (iOS; native LRCLIB client)", forHTTPHeaderField: "User-Agent")
            let response = try await transport.send(request)
            XCTAssertEqual(response.statusCode, 200, "LRCLIB record \(id)")
            let record = try JSONDecoder().decode(LRCLIBRecord.self, from: response.data)
            XCTAssertEqual(record.id, id)
            XCTAssertFalse(LRCParser.parse(record.syncedLyrics ?? "", duration: record.duration).isEmpty)
            try await Task.sleep(for: .milliseconds(150))
        }
    }
}
