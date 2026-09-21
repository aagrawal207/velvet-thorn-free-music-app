import XCTest
@testable import GanaBajana

final class LyricsMatchingTests: XCTestCase {
    func testSearchRanksCandidatesInsteadOfChoosingFirstOrNearestAlone() {
        let records = [
            LyricsTestFixtures.record(id: 1, title: "Paper Satellites (Live)", duration: 200),
            LyricsTestFixtures.record(id: 2, artist: "Unrelated Singer", duration: 200),
            LyricsTestFixtures.record(id: 3, album: "972M plays", duration: 200),
            LyricsTestFixtures.record(id: 4, duration: 199)
        ]
        let result = LyricsMatcher.bestMatch(in: records, for: LyricsTestFixtures.track)
        XCTAssertEqual(result?.record.id, 4)
        XCTAssertEqual(result?.durationDifference, 1)
        XCTAssertEqual(result?.isExact, true)
    }

    func testVideoClutterAndArtistOrderDoNotChangeRecordingIdentity() {
        var track = LyricsTestFixtures.track
        track.title = "Paper Satellites (Official Music Video)"
        track.artists = ["Test Singer", "Second Singer"]
        let record = LyricsTestFixtures.record(artist: "Second Singer & Test Singer")
        XCTAssertEqual(LyricsMatcher.evaluate(record, for: track)?.isExact, true)
        XCTAssertEqual(LyricsMatcher.cleanTitle("Test Singer - Paper Satellites | Official Audio", artists: ["Test Singer"]),
                       "Paper Satellites")
        XCTAssertEqual(LyricsMatcher.cleanTitle("Paper Satellites (Live) [Official 4K Video]"), "Paper Satellites (Live)")
        XCTAssertEqual(LyricsMatcher.cleanTitle("Paper Satellites - Official Audio - Test Singer", artists: ["Test Singer"]),
                       "Paper Satellites")
        XCTAssertEqual(LyricsMatcher.cleanTitle("The Official Audio Waltz"), "The Official Audio Waltz")
    }

    func testSourceAlbumSuffixIsPresentationButVersionsAreNot() {
        var track = LyricsTestFixtures.track
        track.title = "Paper Satellites (From \"Imaginary Sky\")"
        XCTAssertNotNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(), for: track))
        for version in ["Live", "DJ Test Remix", "Slowed + Reverb", "Sped Up", "Acoustic", "Radio Edit",
                        "Demo", "Instrumental", "Karaoke", "Hindi Version", "Remastered 2025"] {
            var variant = LyricsTestFixtures.track
            variant.title += " (\(version))"
            XCTAssertNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(), for: variant), version)
            XCTAssertNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(title: variant.title),
                                                for: LyricsTestFixtures.track), version)
        }
    }

    func testDifferentNamedRemixesAndLiveAlbumsAreRejected() {
        var track = LyricsTestFixtures.track
        track.title += " (North Remix)"
        XCTAssertNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(title: "Paper Satellites (South Remix)"), for: track))
        XCTAssertNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(album: "Live at the Test Hall"),
                                            for: LyricsTestFixtures.track))
    }

    func testUnicodeMarksArePreservedAndRomanizedMetadataCanMatch() {
        var native = LyricsTestFixtures.track
        native.title = "नई सुबह"
        XCTAssertNotNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(title: "नई सुबह"), for: native))
        XCTAssertNotEqual(LyricsMatcher.normalized("कल"), LyricsMatcher.normalized("काल"))
        native.title = "कल"
        XCTAssertNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(title: "काल"), for: native))
        var romanized = LyricsTestFixtures.track
        romanized.title = "Nayī Subah"
        XCTAssertNotNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(title: "Nayi Subah"), for: romanized))
        romanized.title = "तुम ही हो"
        XCTAssertNotNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(title: "Tum Hi Ho"), for: romanized))
    }

    func testDurationToleranceIsBoundedAndRequiresStrongerEvidenceOutsideTwoSeconds() {
        XCTAssertEqual(LyricsMatcher.searchTolerance(for: 1_000), 6)
        XCTAssertNotNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(duration: 203), for: LyricsTestFixtures.track))
        XCTAssertNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(duration: 203.01), for: LyricsTestFixtures.track))
        XCTAssertNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(album: "Different Album", duration: 203),
                                            for: LyricsTestFixtures.track))
        XCTAssertNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(duration: 230), for: LyricsTestFixtures.track))
    }

    func testCompetingTimingIsAmbiguousButIdenticalCompilationDuplicatesAreNot() {
        let first = LyricsTestFixtures.record(id: 1)
        let conflicting = LyricsTestFixtures.record(id: 2, synced: "[00:09]A conflicting synthetic timing")
        XCTAssertNil(LyricsMatcher.bestMatch(in: [first, conflicting], for: LyricsTestFixtures.track))
        let duplicate = LyricsTestFixtures.record(id: 3)
        XCTAssertEqual(LyricsMatcher.bestMatch(in: [duplicate, first], for: LyricsTestFixtures.track)?.record.id, 1)
    }

    func testCollaborationSubsetNeedsExactDurationAndCannotSplitBandIdentity() {
        var duet = LyricsTestFixtures.track
        duet.artists = ["Test Singer", "Second Singer"]
        XCTAssertNotNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(), for: duet))
        XCTAssertNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(duration: 203), for: duet))
        duet.artists = ["Test Singer & Second Singer"]
        XCTAssertNil(LyricsMatcher.evaluate(LyricsTestFixtures.record(), for: duet))
    }

    func testCacheKeyPreservesVersionDurationAndNativeMarks() {
        let track = LyricsTestFixtures.track
        var alternate = track
        alternate.id = "another-catalog-id"
        XCTAssertEqual(LyricsMatcher.RecordingKey(track), LyricsMatcher.RecordingKey(alternate))
        alternate.duration = 201
        XCTAssertNotEqual(LyricsMatcher.RecordingKey(track), LyricsMatcher.RecordingKey(alternate))
        alternate = track
        alternate.title += " (Slowed)"
        XCTAssertNotEqual(LyricsMatcher.RecordingKey(track), LyricsMatcher.RecordingKey(alternate))
        alternate = track
        alternate.artists = ["First Artist", "Second Artist"]
        var band = alternate
        band.artists = ["First Artist & Second Artist"]
        XCTAssertNotEqual(LyricsMatcher.RecordingKey(band), LyricsMatcher.RecordingKey(alternate))
    }

    func testSymbolAlbumNamesRemainDistinct() {
        var track = LyricsTestFixtures.track
        track.albumTitle = "÷"
        XCTAssertEqual(LyricsMatcher.evaluate(LyricsTestFixtures.record(album: "÷"), for: track)?.isExact, true)
        XCTAssertEqual(LyricsMatcher.evaluate(LyricsTestFixtures.record(album: "×"), for: track)?.isExact, false)
        var other = track
        other.albumTitle = "×"
        XCTAssertNotEqual(LyricsMatcher.RecordingKey(track), LyricsMatcher.RecordingKey(other))
    }
}
