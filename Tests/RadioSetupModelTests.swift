import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class RadioSetupModelTests: XCTestCase {
    func testNoArtistHintsCanSubmitTheMoodDefaultsAndSubmissionIsOneShot() async throws {
        let catalog = ExperienceRadioCatalogFixture()
        let setup = try makeSetup(catalog: catalog)
        XCTAssertTrue(setup.selectedArtists.isEmpty)
        XCTAssertTrue(setup.canStart)
        let experience = try XCTUnwrap(setup.submit())
        XCTAssertTrue(experience.id.hasPrefix("melancholy.setup."))
        XCTAssertEqual(experience.stationID, "melancholy")
        XCTAssertEqual(experience.seeds, setup.station.seeds)
        XCTAssertEqual(experience.styleQueries, setup.station.styleQueries)
        XCTAssertTrue(experience.artistHints.isEmpty)
        XCTAssertFalse(setup.canStart)
        XCTAssertNil(setup.submit())
        setup.selectEra(.newer)
        setup.setLanguage(.english, selected: false)
        setup.toggleArtist(setup.artistChoices[0])
        XCTAssertEqual(setup.era, .anytime)
        XCTAssertEqual(setup.languages, [.hindi, .english])
        XCTAssertTrue(setup.selectedArtists.isEmpty)
        let searches = await catalog.searchRequests
        let radio = await catalog.radioRequests
        XCTAssertTrue(searches.isEmpty && radio.isEmpty, "Editing and submitting a draft must not start provider work on their own")
    }

    func testSingleAllAndClearedArtistHintsNeverGateAValidDraft() throws {
        let setup = try makeSetup()
        let artists = setup.artistChoices
        setup.toggleArtist(artists[0])
        XCTAssertEqual(setup.selectedArtists.count, 1)
        XCTAssertTrue(setup.canStart)
        for artist in artists { setup.setArtist(artist, selected: true) }
        XCTAssertEqual(setup.selectedArtists.count, 4)
        XCTAssertTrue(setup.canStart)
        setup.selectEra(.older)
        XCTAssertTrue(setup.canStart)
        setup.selectEra(.newer)
        XCTAssertTrue(setup.canStart)
        setup.clearArtistHints()
        XCTAssertTrue(setup.selectedArtists.isEmpty)
        XCTAssertTrue(setup.canStart)
        let experience = try XCTUnwrap(setup.submit())
        XCTAssertEqual(experience.defaultEra, .newer)
        XCTAssertEqual(experience.seeds, setup.station.seeds)
        XCTAssertTrue(experience.artistHints.isEmpty)
    }

    func testSearchedArtistKeepsItsProviderIDAndTheHintLimit() async throws {
        let setup = try makeSetup(catalog: DebugMusicFixtures())
        setup.artistQuery = "Norah"
        await setup.searchArtists()
        let norah = try XCTUnwrap(setup.artistResults.first { $0.id == "UCfixtureRadioNorah00001" })
        setup.addArtist(norah)
        XCTAssertEqual(setup.selectedArtists, [DebugMusicFixtures.radioSetupNorah])
        XCTAssertTrue(setup.canStart)
        XCTAssertTrue(setup.artistQuery.isEmpty && setup.artistResults.isEmpty)
        for artist in setup.artistChoices where artist.id != norah.id { setup.setArtist(artist, selected: true) }
        XCTAssertEqual(setup.selectedArtists.count, 4)
        XCTAssertNotNil(setup.notice)
        setup.selectEra(.newer)
        let experience = try XCTUnwrap(setup.submit())
        XCTAssertTrue(experience.artistHints.contains(DebugMusicFixtures.radioSetupNorah))
        XCTAssertEqual(experience.defaultEra, .newer)
        XCTAssertEqual(experience.seeds, setup.station.seeds, "Hints must not replace the mood definition")
    }

    func testLanguageEditsKeepEligibleHintsWithoutAutomaticallySelectingArtists() throws {
        let setup = try makeSetup(stationID: "left-field-rap")
        XCTAssertTrue(setup.selectedArtists.isEmpty)
        setup.setArtist(try XCTUnwrap(setup.artistChoices.first { $0.name == "Kanye West" }), selected: true)
        setup.setArtist(try XCTUnwrap(setup.artistChoices.first { $0.name == "Char Diwaari" }), selected: true)
        setup.setLanguage(.hindi, selected: false)
        XCTAssertEqual(setup.selectedArtists.map(\.name), ["Kanye West"])
        XCTAssertEqual(setup.artistChoices.map(\.name), ["Kanye West", "Tyler, The Creator"])
        setup.setLanguage(.english, selected: false)
        XCTAssertTrue(setup.canStart, "An empty legacy scope is automatic rather than a required user choice")
        XCTAssertNil(setup.configuration.validationMessage)
        XCTAssertEqual(setup.configuration.experience().variants, setup.station.variants)
        setup.setLanguage(.hindi, selected: true)
        XCTAssertTrue(setup.canStart)
        XCTAssertTrue(setup.selectedArtists.isEmpty)
        XCTAssertEqual(setup.artistChoices.map(\.name), ["Char Diwaari", "Seedhe Maut"])
        XCTAssertEqual(try XCTUnwrap(setup.submit()).seeds.map(\.artist.name), ["Char Diwaari", "Seedhe Maut"])
    }

    func testOtherLanguagesStartWithoutCuesAndWithoutAnArtistRequirement() throws {
        let setup = try makeSetup(stationID: "hindi-gym")
        setup.setLanguage(.english, selected: true)
        setup.setLanguage(.hindi, selected: false)
        XCTAssertEqual(setup.languages, [.english])
        XCTAssertTrue(setup.canStart, "Every station starts in any non-empty language set")
        XCTAssertEqual(setup.startHelp, "Start from the station’s mood. No artist hints needed.")
        XCTAssertTrue(setup.artistChoices.isEmpty, "Hindi cues are not offered as English hints")
        setup.addArtist(MusicCollection(id: "UCoptionalArtist", title: "Optional Artist", kind: .artist))
        XCTAssertTrue(setup.canStart)
        XCTAssertEqual(setup.selectedArtists.map(\.name), ["Optional Artist"])
        setup.clearArtistHints()
        XCTAssertTrue(setup.canStart)
        let experience = try XCTUnwrap(setup.submit())
        XCTAssertTrue(experience.seeds.isEmpty)
        let english = try XCTUnwrap(experience.selection(for: [.english]))
        XCTAssertEqual(english.contentLabel, "English · Anytime")
        XCTAssertEqual(english.styleQueries, setup.station.styleQueries(for: .english))
        XCTAssertGreaterThanOrEqual(english.styleQueries.count, 2)
    }

    func testHindiOnlyMelancholyIsStartableAndOffersNoEnglishCuesAsHints() throws {
        let setup = try makeSetup()
        XCTAssertEqual(setup.languages, [.hindi, .english], "Automatic setup keeps all legacy cue variants available")
        XCTAssertEqual(setup.artistChoices.count, 4)
        setup.setLanguage(.english, selected: false)
        XCTAssertEqual(setup.languages, [.hindi])
        XCTAssertTrue(setup.canStart)
        XCTAssertTrue(setup.artistChoices.isEmpty)
        let experience = try XCTUnwrap(setup.submit())
        XCTAssertTrue(experience.seeds.isEmpty)
        XCTAssertEqual(experience.selection(for: [.hindi])?.contentLabel, "Hindi · Anytime")
        XCTAssertEqual(experience.selection(for: [.hindi])?.styleQueries, setup.station.styleQueries(for: .hindi))
    }

    func testRapidTogglesAndEraChangesRemainIndependentOfPendingArtistSearch() async throws {
        let catalog = AppModelCatalogProvider()
        addTeardownBlock { await catalog.close() }
        let setup = try makeSetup(catalog: catalog)
        let originalOrder = setup.artistChoices
        setup.artistQuery = "Norah"
        let pending = Task { await setup.searchArtists() }
        defer { pending.cancel() }
        let request = try await catalog.searches.request(at: 0)
        let pixies = try XCTUnwrap(setup.artistChoices.first { $0.name == "Pixies" })
        setup.toggleArtist(pixies)
        setup.toggleArtist(pixies)
        setup.toggleArtist(pixies)
        XCTAssertEqual(setup.selectedArtists, [pixies])
        setup.selectEra(.older)
        setup.clearArtistHints()
        try await catalog.searches.complete(request, with: .success(CatalogPage(collections: [
            MusicCollection(id: "UCNorah", title: "Norah Jones", kind: .artist),
        ])))
        await pending.value
        XCTAssertEqual(setup.artistChoices, originalOrder)
        XCTAssertTrue(setup.selectedArtists.isEmpty)
        XCTAssertEqual(setup.era, .older)
        XCTAssertTrue(setup.canStart)
    }

    func testArtistSearchFailureIsRetryableAndDoesNotDisableMoodDefaults() async throws {
        let catalog = AppModelCatalogProvider()
        addTeardownBlock { await catalog.close() }
        let setup = try makeSetup(catalog: catalog)
        setup.artistQuery = "Norah"
        await catalog.searches.enqueue(.failure(MusicServiceError.network("Search unavailable")))
        await setup.searchArtists()
        XCTAssertNotNil(setup.artistSearchError)
        XCTAssertTrue(setup.canStart)
        let previous = setup.searchRequest
        setup.retryArtistSearch()
        XCTAssertNotEqual(setup.searchRequest, previous)
        await catalog.searches.enqueue(.success(CatalogPage(collections: [MusicCollection(id: "UCNorah", title: "Norah Jones", kind: .artist)])))
        await setup.searchArtists()
        XCTAssertNil(setup.artistSearchError)
        XCTAssertEqual(setup.artistResults.map(\.id), ["UCNorah"])
        XCTAssertTrue(setup.canStart)
    }

    func testArtistSearchRejectsStaleResultsAndKeepsResultsForWhitespaceOnlyEdits() async throws {
        let catalog = AppModelCatalogProvider()
        addTeardownBlock { await catalog.close() }
        let setup = RadioSetupModel(station: ExperienceRadioFixtures.melancholy, languages: [.english], catalog: catalog)
        defer { setup.cancel() }
        setup.artistQuery = "Norah"
        let old = Task { await setup.searchArtists() }
        defer { old.cancel() }
        let earlier = try await catalog.searches.request(at: 0)
        setup.artistQuery = "Radiohead"
        let current = Task { await setup.searchArtists() }
        defer { current.cancel() }
        let request = try await catalog.searches.request(at: 1)
        XCTAssertEqual(request.input, AppModelSearchRequest(query: "Radiohead", filter: .artists, continuation: nil))
        let artist = MusicCollection(id: "UCRadiohead", title: "Radiohead", kind: .artist)
        try await catalog.searches.complete(request, with: .success(CatalogPage(collections: [
            artist, artist, MusicCollection(id: "album", title: "Radiohead", kind: .album),
            MusicCollection(id: "blank-name", title: "  ", kind: .artist),
        ])))
        await current.value
        XCTAssertEqual(setup.artistResults, [artist])
        let identity = setup.searchRequest
        setup.artistQuery = " Radiohead  "
        XCTAssertEqual(setup.searchRequest, identity)
        XCTAssertEqual(setup.artistResults, [artist])
        try await catalog.searches.complete(earlier, with: .success(CatalogPage(collections: [
            MusicCollection(id: "UCNorah", title: "Norah Jones", kind: .artist),
        ])))
        await old.value
        XCTAssertEqual(setup.artistResults, [artist])
        XCTAssertFalse(setup.isSearchingArtists)
        XCTAssertTrue(setup.hasSearchedArtists)
        XCTAssertNil(setup.artistSearchError)
    }

    func testCancellingTheDraftRejectsLateArtistResultsAndSubmission() async throws {
        let catalog = AppModelCatalogProvider()
        addTeardownBlock { await catalog.close() }
        let setup = try makeSetup(catalog: catalog)
        setup.artistQuery = "Norah"
        let pending = Task { await setup.searchArtists() }
        defer { pending.cancel() }
        let request = try await catalog.searches.request(at: 0)
        setup.cancel()
        XCTAssertNil(setup.submit())
        try await catalog.searches.complete(request, with: .success(CatalogPage(collections: [
            MusicCollection(id: "UCNorah", title: "Norah Jones", kind: .artist),
        ])))
        await pending.value
        XCTAssertFalse(setup.canStart)
        XCTAssertTrue(setup.artistResults.isEmpty)
        XCTAssertNil(setup.submit())
    }

    func testEmptyLegacyLanguageScopeSubmitsEveryVariantWithNoRequiredArtistHints() throws {
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "left-field-rap" })
        let setup = RadioSetupModel(station: station, languages: [], catalog: ExperienceRadioCatalogFixture())
        defer { setup.cancel() }
        XCTAssertTrue(setup.canStart)
        XCTAssertTrue(setup.selectedArtists.isEmpty)
        XCTAssertFalse(setup.artistChoices.isEmpty)
        let experience = try XCTUnwrap(setup.submit())
        XCTAssertEqual(experience.variants, station.variants)
        XCTAssertEqual(experience.seeds, station.seeds)
        XCTAssertTrue(experience.artistHints.isEmpty)
        XCTAssertNil(setup.submit())
    }

    private func makeSetup(stationID: String = "melancholy", catalog: any MusicCatalogProviding = ExperienceRadioCatalogFixture()) throws -> RadioSetupModel {
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == stationID })
        let setup = RadioSetupModel(station: station, catalog: catalog)
        addTeardownBlock { @MainActor in setup.cancel() }
        return setup
    }
}
