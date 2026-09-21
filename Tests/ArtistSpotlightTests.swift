import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightTests: XCTestCase {
    func testProviderCountsDescendWithZeroBeforeUnknownAndDeterministicTies() {
        let tracks = [
            ArtistSpotlightTestSupport.track("nil", title: "A missing count"),
            ArtistSpotlightTestSupport.track("negative", title: "Z invalid count", count: -20),
            ArtistSpotlightTestSupport.track("zero", title: "Zero", count: 0),
            ArtistSpotlightTestSupport.track("tie-b", title: "Same title", count: 500),
            ArtistSpotlightTestSupport.track("tie-a", title: "Same title", count: 500),
            ArtistSpotlightTestSupport.track("alpha", title: "Alpha", count: 500),
            ArtistSpotlightTestSupport.track("most", title: "Zebra", count: 9_000_000),
        ]
        let expected = ["most", "alpha", "tie-a", "tie-b", "zero", "nil", "negative"]
        XCTAssertEqual(ArtistSpotlight.sorted(tracks).map(\.id), expected)
        XCTAssertEqual(ArtistSpotlight.sorted(Array(tracks.reversed())).map(\.id), expected)
        XCTAssertNil(ArtistSpotlight.sorted(tracks).last?.playCount)
    }

    func testDuplicateIDsFillMissingMetadataWithoutSummingOrCollapsingLanguageVersions() {
        var missing = ArtistSpotlightTestSupport.track("one", title: "Same song")
        missing.duration = nil
        let complete = ArtistSpotlightTestSupport.track("one", title: "Same song", count: 700, language: .hindi)
        let newerCount = ArtistSpotlightTestSupport.track("one", title: "Same song", count: 900)
        let dubbed = ArtistSpotlightTestSupport.track("dubbed", title: "Same song", count: 800)
        let result = ArtistSpotlight.sorted([missing, complete, newerCount, dubbed])
        XCTAssertEqual(result.map(\.id), ["dubbed", "one"])
        XCTAssertEqual(result.last?.playCount, 700, "The first available listing count wins; counts are not combined")
        XCTAssertEqual(result.last?.duration, 240)
        XCTAssertEqual(result.last?.language, .hindi)
    }

    func testConflictingDuplicateLanguageMetadataDoesNotBecomeAnAssertion() {
        let hindi = ArtistSpotlightTestSupport.track("one", count: 700, language: .hindi)
        let english = ArtistSpotlightTestSupport.track("one", count: 700, language: .english)
        XCTAssertNil(ArtistSpotlight.mergedTracks([hindi, english]).first?.language)
    }

    func testCountsBelongToMatchedIDsAndCannotComeFromCoversOrChangedTitles() {
        let original = ArtistSpotlightTestSupport.track("original", title: "River Lights")
        let artist = ArtistSpotlightTestSupport.page([original])
        var unrelated = original
        unrelated.credits = [ArtistCredit(name: "Someone Else", id: "UCelse")]
        unrelated.playCount = 100_000
        var wrongTitle = original
        wrongTitle.title = "River Lights (Live)"
        wrongTitle.playCount = 50_000
        let otherID = ArtistSpotlightTestSupport.track("other-version", title: original.title, count: 1_000_000)
        XCTAssertNil(ArtistSpotlight.matchingCount(for: original, in: [unrelated, wrongTitle, otherID], artist: artist))
        var exact = original
        exact.playCount = 750
        XCTAssertEqual(ArtistSpotlight.matchingCount(for: original, in: [unrelated, otherID, exact], artist: artist), 750)
    }

    func testSecondaryAndUnlinkedInitialCreditsMatchWithoutFuzzyArtistContamination() {
        let artist = ArtistSpotlightFixtures.page
        var song = ArtistSpotlightTestSupport.track("collaboration")
        song.credits = [ArtistCredit(name: "Primary Singer", id: "UCprimary"), ArtistSpotlightFixtures.artist]
        XCTAssertTrue(ArtistSpotlight.credits(artist, on: song))
        song.credits = [ArtistCredit(name: "Singer & A.R. Rahman")]
        XCTAssertTrue(ArtistSpotlight.credits(artist, on: song))
        song.credits = [ArtistCredit(name: "A. R. Rehman")]
        XCTAssertFalse(ArtistSpotlight.credits(artist, on: song))
        song.credits = [ArtistCredit(name: artist.name, id: "UCunrelated")]
        XCTAssertFalse(ArtistSpotlight.credits(artist, on: song))
    }

    func testLanguageFiltersRetainPopularityOrderAndAllKeepsUnclassifiedSongs() {
        let tracks = [ArtistSpotlightTestSupport.track("ta", count: 900),
                      ArtistSpotlightTestSupport.track("hi-low", count: 100, language: .hindi),
                      ArtistSpotlightTestSupport.track("te", count: 500),
                      ArtistSpotlightTestSupport.track("hi-high", count: 700),
                      ArtistSpotlightTestSupport.track("en", count: 300, language: .english),
                      ArtistSpotlightTestSupport.track("unknown-count"),
                      ArtistSpotlightTestSupport.track("unclassified", count: 800)]
        let languages: [String: ArtistSongLanguageResult] = [
            "ta": .identified(.tamil, source: .matchedLyrics), "te": .identified(.telugu, source: .matchedLyrics),
            "hi-high": .identified(.hindi, source: .matchedLyrics), "unknown-count": .identified(.tamil, source: .matchedLyrics),
            "unclassified": .unclassified(.uncertainLanguage),
        ]
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .all, languages: languages).map(\.id),
                       ["ta", "unclassified", "hi-high", "te", "en", "hi-low", "unknown-count"])
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .language(.hindi), languages: languages).map(\.id), ["hi-high", "hi-low"])
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .language(.tamil), languages: languages).map(\.id), ["ta", "unknown-count"])
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .language(.telugu), languages: languages).map(\.id), ["te"])
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .language(.english), languages: languages).map(\.id), ["en"])
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .unclassified, languages: languages).map(\.id), ["unclassified"])
    }

    func testOneAvailableLanguageStillShowsAllAndUnknownDoesNotInheritArtistLanguage() {
        let hindi = ArtistSpotlightTestSupport.track("hi", language: .hindi)
        let unknown = ArtistSpotlightTestSupport.track("unknown")
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([hindi, unknown]))
        XCTAssertEqual(loader.filters, [.all, .language(.hindi), .unclassified])
        XCTAssertEqual(loader.unclassifiedCount, 1)
        XCTAssertEqual(loader.collection.title, "This is A. R. Rahman")
        XCTAssertEqual(loader.collection.kind, .mix)
        XCTAssertNil(loader.collection.language)
    }
}
