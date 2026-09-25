import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightMultiSignalTests: XCTestCase {
    func testTitleLabelsAndScriptsAreOnlySuggestionsAndLatinTextIsNotEnglishProof() {
        XCTAssertEqual(ArtistSpotlightLanguageSignals.titleHint("New day (Hindi Version)"), .likely(.hindi, source: .titleLabel))
        XCTAssertEqual(ArtistSpotlightLanguageSignals.titleHint("New day [English]"), .likely(.english, source: .titleLabel))
        XCTAssertEqual(ArtistSpotlightLanguageSignals.titleHint("புதிய காலை மலர்கள்"), .likely(.tamil, source: .titleScript))
        XCTAssertEqual(ArtistSpotlightLanguageSignals.titleHint("కొత్త ఉదయం పూలు"), .likely(.telugu, source: .titleScript))
        XCTAssertNil(ArtistSpotlightLanguageSignals.titleHint("nayi subah mere dil ki baat"))
        XCTAssertNil(ArtistSpotlightLanguageSignals.titleHint("A. R. Rahman"))
        XCTAssertNil(ArtistSpotlightLanguageSignals.titleHint("नई सुबह में हवा"), "Devanagari alone cannot distinguish Hindi from other languages")
        let track = ArtistSpotlightTestSupport.track("likely")
        let results: [String: ArtistSongLanguageResult] = [track.id: .likely(.tamil, source: .titleScript)]
        XCTAssertTrue(ArtistSpotlight.filtered([track], by: .language(.tamil), languages: results).isEmpty)
        XCTAssertEqual(ArtistSpotlight.filtered([track], by: .unclassified, languages: results).map(\.id), [track.id])
    }

    func testExactRecordingLinkedLyricsCanClassifyButBadIdentityCannot() {
        let track = LyricsFallbackFixtures.track
        let document = LyricsFallbackFixtures.plain(text: ArtistSpotlightFixtures.tamilText)
        let result = ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: { _ in ["ta": 0.99] })
        XCTAssertEqual(result, .identified(.tamil, source: .linkedLyrics))
        var wrong = document
        wrong.trackID = "J7p4bzqLvCw"
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(wrong, for: track, hypotheses: { _ in ["ta": 0.99] }), .unclassified(.noMatchedLyrics))
        let romanized = LyricsFallbackFixtures.plain(text: "nayi subah mere dil ki baat")
        XCTAssertNil(ArtistSpotlightLanguageClassifier.classify(romanized, for: track, hypotheses: { _ in ["en": 1] }).language)
    }

    func testConflictingStrongSourcesRemainUnclassifiedAndMetadataCanFillMissingLyrics() async throws {
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await provider.requests.close() }
        let track = LyricsFallbackFixtures.track
        let work = ArtistSongLanguageResult.identified(.hindi, source: .musicBrainzWork(recordingID: "recording", workID: "work"))
        XCTAssertEqual(ArtistSpotlightLanguageSignals.combine(lyrics: .identified(.tamil, source: .linkedLyrics), metadata: work, title: track.title),
                       .unclassified(.conflictingEvidence))
        await provider.requests.enqueue(.success(LyricsDocument(trackID: track.id, kind: .unavailable)))
        let service = ArtistSpotlightLanguageService(provider: provider, metadataLookup: { _ in work })
        let result = try await service.classification(for: track)
        XCTAssertEqual(result, work)
    }

    func testAnExplicitConflictCannotBeReplacedByAnotherSourceOrATitleHint() {
        let conflict = ArtistSongLanguageResult.unclassified(.conflictingEvidence)
        let english = ArtistSongLanguageResult.identified(.english, source: .matchedLyrics)
        let work = ArtistSongLanguageResult.identified(.english, source: .musicBrainzWork(recordingID: "recording", workID: "work"))
        for (lyrics, metadata) in [(conflict, work), (english, conflict), (conflict, conflict)] {
            XCTAssertEqual(ArtistSpotlightLanguageSignals.combine(lyrics: lyrics, metadata: metadata, title: "Song (English Version)"), conflict)
        }
        XCTAssertEqual(ArtistSpotlightLanguageSignals.combine(lyrics: nil, metadata: conflict, title: "Song (Hindi)"), conflict)
        XCTAssertEqual(ArtistSpotlightLanguageSignals.combine(lyrics: conflict, metadata: nil, title: "Song (Tamil)"), conflict)
    }

    func testAnExplicitUnsupportedWorkLanguageDoesNotBecomeAnEnglishLyricsFallback() {
        XCTAssertEqual(ArtistSpotlightLanguageSignals.combine(lyrics: .identified(.english, source: .linkedLyrics),
            metadata: .unclassified(.uncertainLanguage), title: "Song (English)"), .unclassified(.uncertainLanguage))
    }

    func testDifferentProviderIDsDoNotShareLinkedLanguageEvenWithIdenticalMetadata() async throws {
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await provider.requests.close() }
        let first = LyricsFallbackFixtures.track
        var second = first
        second.id = "J7p4bzqLvCw"
        await provider.requests.enqueue(.success(LyricsFallbackFixtures.plain(first)))
        await provider.requests.enqueue(.success(LyricsFallbackFixtures.plain(second, text: ArtistSpotlightFixtures.tamilText)))
        let service = ArtistSpotlightLanguageService(provider: provider, hypotheses: ArtistSpotlightTestSupport.originalScriptHypotheses)
        let a = try await service.classification(for: first)
        let b = try await service.classification(for: second)
        XCTAssertEqual(a.language, .english)
        XCTAssertEqual(b.language, .tamil)
        let count = await provider.requests.requests.count
        XCTAssertEqual(count, 2)
    }

    func testOriginalScriptWithoutRecognizerConfidenceStaysASuggestion() {
        let track = LyricsFallbackFixtures.track
        for (text, language) in [(ArtistSpotlightFixtures.tamilText, ArtistSongLanguage.tamil), (ArtistSpotlightFixtures.teluguText, .telugu)] {
            let result = ArtistSpotlightLanguageClassifier.classify(LyricsFallbackFixtures.plain(text: text), for: track,
                                                                   hypotheses: { _ in [:] })
            XCTAssertEqual(result, .likely(language, source: .lyricsScript))
            XCTAssertNil(result.language)
        }
        let mixed = LyricsFallbackFixtures.plain(text: ArtistSpotlightFixtures.tamilText + "\n" + ArtistSpotlightFixtures.hindiText)
        XCTAssertNil(ArtistSpotlightLanguageClassifier.classify(mixed, for: track, hypotheses: { _ in [:] }).language)
    }

    func testAutomaticChecksStopAtTwelveWhileAllSongsRemainAvailable() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await catalog.close() }
        let lyrics = AppModelLyricsProvider()
        let tracks = (0..<13).map { ArtistSpotlightTestSupport.track("batch-\($0)", count: Int64(100 - $0)) }
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page(tracks),
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(),
            languageService: ArtistSpotlightLanguageService(provider: lyrics))
        XCTAssertEqual(loader.visibleTracks.count, 13)
        await loader.load(catalog: catalog, lyrics: lyrics)
        let automatic = await lyrics.requests.count
        XCTAssertEqual(automatic, 12)
        XCTAssertEqual(loader.visibleTracks.count, 13)
        XCTAssertTrue(loader.canCheckMoreLanguages)
        loader.checkMoreLanguages()
        try await AppModelFixtures.eventually { !loader.isBusy }
        let total = await lyrics.requests.count
        XCTAssertEqual(total, 13)
        XCTAssertFalse(loader.canCheckMoreLanguages)
    }
}
