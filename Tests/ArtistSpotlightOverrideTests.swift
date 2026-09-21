import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightOverrideTests: XCTestCase {
    func testOverridesPersistAndClearingOnePreservesOtherChoicesAndListeningData() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let track = libraryTestTrack()
            library.toggleFavorite(track)
            library.recordListening(track: track, sessionID: UUID(), startedAt: Date().addingTimeInterval(-30), seconds: 10)
            library.setLyricsOffset(0.5, for: track.id)
            XCTAssertTrue(library.setRecordingLanguageOverride("ta", for: track.id))
            XCTAssertTrue(library.setRecordingLanguageOverride("future-code", for: "other-recording"))
            let loaded = LibraryStore(directory: directory)
            XCTAssertEqual(loaded.recordingLanguageOverrides[track.id], "ta")
            XCTAssertEqual(loaded.recordingLanguageOverrides["other-recording"], "future-code")
            XCTAssertTrue(loaded.setRecordingLanguageOverride(nil, for: track.id))
            let cleared = LibraryStore(directory: directory)
            XCTAssertNil(cleared.recordingLanguageOverrides[track.id])
            XCTAssertEqual(cleared.recordingLanguageOverrides["other-recording"], "future-code")
            XCTAssertEqual(cleared.events.count, 1)
            XCTAssertEqual(cleared.favorites.map(\.id), [track.id])
            XCTAssertEqual(cleared.lyricsOffset(for: track.id), 0.5)
        }
    }

    func testOldDocumentsDecodeMissingOverrideFieldAndFutureCodesRemainIntact() throws {
        let data = try LibraryPersistence.encode(LibraryDocument())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "recordingLanguageOverrides")
        let old = try LibraryPersistence.decode(JSONSerialization.data(withJSONObject: object), now: Date())
        XCTAssertTrue(old.recordingLanguageOverrides.isEmpty)
        object["recordingLanguageOverrides"] = ["song": "future-code"]
        let future = try LibraryPersistence.decode(JSONSerialization.data(withJSONObject: object), now: Date())
        XCTAssertEqual(future.recordingLanguageOverrides["song"], "future-code")
        XCTAssertEqual(ArtistSongLanguageResult.userOverride("future-code"), .unclassified(.userOverride))
    }

    func testManualChoiceWinsOverPrebuiltMetadataAndUnknownChoiceStaysUnclassified() {
        let track = ArtistSpotlightTestSupport.track("metadata", language: .hindi)
        let automated: [String: ArtistSongLanguageResult] = [track.id: .identified(.english, source: .matchedLyrics)]
        XCTAssertEqual(ArtistSpotlight.languageResult(for: track, in: automated, overrides: [track.id: "ta"]), .identified(.tamil, source: .userOverride))
        XCTAssertNil(ArtistSpotlight.languageResult(for: track, in: automated, overrides: [track.id: "und"])?.language)
        XCTAssertEqual(ArtistSpotlight.languageResult(for: track, in: automated)?.language, .hindi)
    }

    func testCorrectionWinsWhenAnOlderNetworkResultArrivesAndClearRevealsThatResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Breezy-LanguageTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let provider = ArtistSpotlightLyricsFixture()
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await provider.requests.close(); await catalog.close() }
        let track = LyricsFallbackFixtures.track
        let service = ArtistSpotlightLanguageService(provider: provider, hypotheses: { _ in ["en": 0.99] })
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([track]),
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(), languageService: service, library: library)
        let task = Task { await loader.load(catalog: catalog, lyrics: provider) }
        let request = try await provider.requests.request(at: 0)
        XCTAssertTrue(library.setRecordingLanguageOverride("ta", for: track.id))
        XCTAssertEqual(loader.languageResult(for: track)?.language, .tamil)
        try await provider.requests.complete(request, with: .success(LyricsFallbackFixtures.plain()))
        await task.value
        XCTAssertEqual(loader.languageResult(for: track), .identified(.tamil, source: .userOverride))
        XCTAssertTrue(library.setRecordingLanguageOverride(nil, for: track.id))
        loader.overridesChanged()
        XCTAssertEqual(loader.languageResult(for: track)?.language, .english)
    }
}
