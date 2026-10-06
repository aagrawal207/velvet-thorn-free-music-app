import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightLanguagePresentationTests: XCTestCase {
    func testUnknownCatalogsStartWithPopularSongsAndAnOptInLanguageControl() {
        let tracks = [ArtistSpotlightTestSupport.track("unknown-low", count: 100),
                      ArtistSpotlightTestSupport.track("unknown-high", count: 900)]
        for name in ["Kanye West", "Radiohead", "A. R. Rahman"] {
            var page = ArtistSpotlightTestSupport.page(tracks)
            page.name = name
            let loader = ArtistSpotlightLoader(artist: page)
            XCTAssertEqual(loader.filter, .all)
            XCTAssertFalse(loader.isBrowsingLanguages)
            XCTAssertFalse(loader.hasUsefulLanguageFacets)
            XCTAssertEqual(loader.languageControlTitle, "Languages")
            XCTAssertTrue(loader.availableLanguages.isEmpty)
            XCTAssertEqual(loader.unclassifiedCount, 2)
            XCTAssertEqual(loader.visibleTracks.map(\.id), ["unknown-high", "unknown-low"])
            XCTAssertNil(loader.collection.language)
        }
    }

    func testOneKnownLanguageDoesNotAssignItsUnknownNeighborsOrExpandDetails() {
        let english = ArtistSpotlightTestSupport.track("english", count: 900, language: .english)
        let unknown = ArtistSpotlightTestSupport.track("unknown", count: 1_000)
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([english, unknown]))
        XCTAssertEqual(loader.availableLanguages, [.english])
        XCTAssertEqual(loader.filters, [.all, .language(.english), .unclassified])
        XCTAssertEqual(loader.languageControlTitle, "Languages")
        XCTAssertFalse(loader.isBrowsingLanguages)
        XCTAssertFalse(loader.hasUsefulLanguageFacets)
        XCTAssertNil(loader.languageResult(for: unknown))
        XCTAssertEqual(loader.visibleTracks.map(\.id), [unknown.id, english.id])
        loader.isBrowsingLanguages = true
        XCTAssertTrue(loader.isBrowsingLanguages)
        XCTAssertTrue(loader.canCheckMoreLanguages)
    }

    func testOnlyTwoConfirmedRecordingLanguagesMakeUsefulFacets() {
        let english = ArtistSpotlightTestSupport.track("english", language: .english)
        let likelyTamil = ArtistSpotlightTestSupport.track("likely", title: "Song (Tamil Version)")
        let hindi = ArtistSpotlightTestSupport.track("hindi", language: .hindi)
        let suggestion = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([english, likelyTamil]))
        XCTAssertFalse(suggestion.hasUsefulLanguageFacets)
        XCTAssertEqual(suggestion.availableLanguages, [.english])
        XCTAssertEqual(suggestion.unclassifiedCount, 1)
        let multilingual = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([english, likelyTamil, hindi]))
        XCTAssertTrue(multilingual.hasUsefulLanguageFacets)
        XCTAssertEqual(multilingual.languageControlTitle, "Browse by Language")
        XCTAssertEqual(multilingual.availableLanguages, [.english, .hindi])
        XCTAssertFalse(multilingual.isBrowsingLanguages)
        XCTAssertEqual(multilingual.visibleTracks.count, 3)
    }

    func testArrivingLanguagesKeepTheUsersCollapsedBrowserAndEmptyUnknownSelection() async throws {
        let provider = ArtistSpotlightLyricsFixture()
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await provider.requests.close(); await catalog.close() }
        let english = ArtistSpotlightTestSupport.track("known", count: 900, language: .english)
        let tamil = ArtistSpotlightTestSupport.track("pending", count: 1_000)
        let service = ArtistSpotlightLanguageService(provider: provider, hypotheses: { _ in ["ta": 0.99] })
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([english, tamil]),
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(), languageService: service)
        let load = Task { await loader.load(catalog: catalog, lyrics: provider) }
        let request = try await provider.requests.request(at: 0)
        loader.isBrowsingLanguages = true
        loader.filter = .unclassified
        loader.isBrowsingLanguages = false
        try await provider.requests.complete(request, with: .success(ArtistSpotlightTestSupport.document(tamil, text: ArtistSpotlightFixtures.tamilText)))
        await load.value
        XCTAssertTrue(loader.hasUsefulLanguageFacets)
        XCTAssertEqual(loader.languageControlTitle, "Browse by Language")
        XCTAssertFalse(loader.isBrowsingLanguages)
        XCTAssertEqual(loader.filter, .unclassified)
        XCTAssertTrue(loader.visibleTracks.isEmpty)
        XCTAssertEqual(loader.count(for: .unclassified), 0)
        XCTAssertTrue(loader.filters.contains(.unclassified))
        loader.filter = .all
        XCTAssertEqual(loader.visibleTracks.map(\.id), [tamil.id, english.id])
        XCTAssertEqual(loader.collection.tracks.map(\.id), [tamil.id, english.id])
    }

    func testManualCorrectionCanEmptyASelectedLanguageWithoutChangingBrowsingIntent() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let english = ArtistSpotlightTestSupport.track("english", count: 100, language: .english)
            let hindi = ArtistSpotlightTestSupport.track("hindi", count: 900, language: .hindi)
            let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([english, hindi]), library: library)
            loader.isBrowsingLanguages = true
            loader.filter = .language(.hindi)
            XCTAssertTrue(library.setRecordingLanguageOverride("und", for: hindi.id))
            XCTAssertTrue(loader.isBrowsingLanguages)
            XCTAssertFalse(loader.hasUsefulLanguageFacets)
            XCTAssertEqual(loader.languageControlTitle, "Languages")
            XCTAssertEqual(loader.filter, .language(.hindi))
            XCTAssertEqual(loader.count(for: .language(.hindi)), 0)
            XCTAssertTrue(loader.filters.contains(.language(.hindi)))
            XCTAssertTrue(loader.visibleTracks.isEmpty)
            XCTAssertEqual(loader.unclassifiedCount, 1)
            XCTAssertEqual(loader.count(for: .all), 2)
            XCTAssertEqual(loader.languageResult(for: hindi), .unclassified(.userOverride))
            XCTAssertTrue(library.setRecordingLanguageOverride(nil, for: hindi.id))
            XCTAssertTrue(loader.hasUsefulLanguageFacets)
            XCTAssertTrue(loader.isBrowsingLanguages)
            XCTAssertEqual(loader.visibleTracks.map(\.id), [hindi.id])
            XCTAssertEqual(loader.collection.tracks.map(\.id), [hindi.id, english.id])
        }
    }

    func testAnEmptyCatalogHasOnlyAllAndNeverMakesUpALanguage() {
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([]))
        XCTAssertEqual(loader.filters, [.all])
        XCTAssertEqual(loader.count(for: .all), 0)
        XCTAssertEqual(loader.unclassifiedCount, 0)
        XCTAssertFalse(loader.hasUsefulLanguageFacets)
        XCTAssertFalse(loader.isBrowsingLanguages)
        XCTAssertFalse(loader.canCheckMoreLanguages)
        loader.filter = .unclassified
        XCTAssertEqual(loader.filters, [.all, .unclassified])
        XCTAssertTrue(loader.visibleTracks.isEmpty)
    }
}
