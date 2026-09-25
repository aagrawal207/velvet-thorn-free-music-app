import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class RadioSetupPlaybackTests: XCTestCase {
    func testCancellingADraftKeepsTheCurrentQueueAndAnAlreadyPendingRadio() async throws {
        let old = libraryTestTrack("keep-playing")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [old], position: 42))
        let f = ExperienceRadioFixtures.self
        let wording = Set(f.gym.selection(for: context.model.listeningLanguageProfile).styleQueries)
        let pendingRadio = context.model.startRadio(f.gym)
        _ = try await context.catalog.searches.request(at: 2)
        let setup = RadioSetupModel(station: f.melancholy, languages: context.library.preferences.languages,
                                   catalog: context.catalog)
        defer { setup.cancel() }
        setup.artistQuery = "Norah"
        let draft = Task { await setup.searchArtists() }
        defer { draft.cancel() }
        let request = try await context.catalog.searches.request(at: 3)
        XCTAssertEqual(request.input.query, "Norah")
        XCTAssertEqual(request.input.filter, .artists)
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 42)
        setup.cancel()
        try await context.catalog.searches.complete(request, with: .success(CatalogPage()))
        await draft.value
        XCTAssertNil(setup.submit())
        XCTAssertTrue(context.model.isLoadingRadio)
        XCTAssertEqual(context.model.selectedRadioExperience, f.gym)
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 42)
        let firstWave = try await f.answerStyleSearches(context, from: 0, count: 3, songs: [], expecting: wording)
        let secondWave = try await f.answerStyleSearches(context, from: 4, count: 3, songs: [], expecting: wording)
        for query in wording {
            XCTAssertEqual((firstWave + secondWave).filter { $0.query == query && $0.filter == .songs }.count, 1)
            XCTAssertEqual((firstWave + secondWave).filter { $0.query == query && $0.filter == .playlists }.count, 1)
        }
        try await f.answerSearches(context, from: 7, with: f.gymSearches)
        try await f.answerRadios(context, from: 0, with: f.gymRadios)
        await pendingRadio.value
        XCTAssertEqual(context.model.activeRadioExperience, f.gym)
        XCTAssertEqual(context.player.currentTrack, f.zinda)
        XCTAssertEqual(context.player.queue, [f.zinda, f.goat, f.sultan, f.punjabi])
        XCTAssertEqual(context.model.activeRadioContentLabel, "Automatic discovery")
        XCTAssertNil(context.model.radioError)
        XCTAssertEqual(context.library.preferences.languages, [.hindi, .english])
        XCTAssertTrue(context.library.preferences.languageNudges.isAutomatic)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        let searches = await context.catalog.searches.requests
        let radios = await context.catalog.radioRefreshRequests
        XCTAssertEqual(searches.count, 9, "The draft search is separate from six style requests and two backup cue searches")
        XCTAssertEqual(radios.map(\.forceRefresh), [false, false])
    }

    func testConfiguredRetryKeepsResolvedRecordingsAndUnsavedLanguageScope() async throws {
        let old = libraryTestTrack("keep-this-song")
        let context = try makeContext(languages: [.hindi], snapshot: PlaybackSnapshot(queue: [old], position: 31))
        let f = ExperienceRadioFixtures.self
        let experience = configuredMelancholy()
        let failed = context.model.startRadio(experience, languages: [.english])
        try await f.answerRadios(context, from: 0, with: f.melancholyRadios, fail: true)
        try await f.answerRadios(context, from: 2, with: f.melancholyRadios, fail: true)
        await failed.value
        XCTAssertNotNil(context.model.radioError)
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 31)
        XCTAssertEqual(context.library.preferences.languages, [.hindi])
        context.model.retryRadio()
        try await f.answerRadios(context, from: 4, with: [f.cas.id: [f.sultan, f.dream], f.pixies.id: [f.alt]])
        try await AppModelFixtures.eventually { !context.model.isLoadingRadio }
        XCTAssertNil(context.model.radioError)
        XCTAssertEqual(context.model.activeRadioExperience, experience)
        XCTAssertEqual(context.model.activeRadioContentLabel, "English · Anytime")
        XCTAssertEqual(context.player.queue.map(\.id), ["catalog-cas", "catalog-pixies", "catalog-dream", "catalog-alt"])
        XCTAssertTrue(context.player.isRadioSession)
        XCTAssertEqual(context.library.preferences.languages, [.hindi])
        let searches = await context.catalog.searches.requests
        XCTAssertTrue(searches.isEmpty, "Start and retry must use the already resolved provider recordings")
        XCTAssertTrue(context.library.recentSearches.isEmpty)
    }

    func testExplicitSetupScopeSurvivesPreferenceEditsButNotANewPlaybackIntent() async throws {
        for playsAnotherSong in [false, true] {
            let context = try makeContext(languages: [.english])
            let experience = configuredMelancholy()
            let pending = context.model.startRadio(experience, languages: [.english])
            _ = try await context.catalog.autoplayRadios.request(at: 1)
            context.model.updatePreferences { $0.languages = [.hindi] }
            XCTAssertTrue(context.model.isLoadingRadio)
            let explicit = libraryTestTrack("explicit-selection")
            if playsAnotherSong {
                context.model.play(explicit)
                XCTAssertFalse(context.model.isLoadingRadio)
            }
            try await ExperienceRadioFixtures.answerRadios(context, from: 0, with: ExperienceRadioFixtures.melancholyRadios)
            await pending.value
            XCTAssertEqual(context.library.preferences.languages, [.hindi])
            if playsAnotherSong {
                XCTAssertEqual(context.player.queue, [explicit])
                XCTAssertNil(context.model.activeRadioExperience)
                XCTAssertFalse(context.player.isRadioSession)
            } else {
                XCTAssertEqual(context.model.activeRadioExperience, experience)
                XCTAssertEqual(context.player.queue.map(\.id), ["catalog-cas", "catalog-pixies", "catalog-dream", "catalog-alt"])
                XCTAssertTrue(context.player.isRadioSession)
            }
            XCTAssertNil(context.model.radioError)
        }
    }

    func testLateMoodFallbackCannotReplaceANewerExplicitQueue() async throws {
        let context = try makeContext(languages: [.english])
        let f = ExperienceRadioFixtures.self
        let experience = RadioExperience(id: "fallback-mood", title: "Mood fixture", description: "Dream pop", symbol: "radio",
            discoveryLanguages: [.english], contentLabel: "English", seeds: configuredMelancholy().seeds,
            styleQueries: ["dream pop songs"])
        let pending = context.model.startRadio(experience, languages: [.english])
        try await f.answerRadios(context, from: 0, with: [f.cas.id: [], f.pixies.id: []])
        let requests = [try await context.catalog.searches.request(at: 0), try await context.catalog.searches.request(at: 1)]
        let explicit = libraryTestTrack("new-explicit-queue")
        context.model.play(explicit)
        XCTAssertFalse(context.model.isLoadingRadio)
        for request in requests {
            try await context.catalog.searches.complete(request, with: .success(CatalogPage(tracks: [f.cas, f.pixies, f.dream, f.alt])))
        }
        await pending.value
        XCTAssertEqual(context.player.queue, [explicit])
        XCTAssertFalse(context.player.isRadioSession)
        XCTAssertNil(context.model.activeRadioExperience)
        XCTAssertNil(context.model.radioError)
        let radio = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(radio.count, 2)
    }

    private func configuredMelancholy() -> RadioExperience {
        let f = ExperienceRadioFixtures.self
        let prepared = RadioExperience(id: f.melancholy.id, title: f.melancholy.title, description: f.melancholy.description,
            symbol: f.melancholy.symbol, discoveryLanguages: [.english], contentLabel: "English", seeds: [
                .init(recording: f.cas, artist: f.melancholy.seeds[0].artist),
                .init(recording: f.pixies, artist: f.melancholy.seeds[1].artist),
            ])
        return RadioConfiguration(station: prepared, languages: [.english]).experience()
    }

    private func makeContext(languages: Set<MusicLanguage> = [.hindi, .english],
                             snapshot: PlaybackSnapshot = PlaybackSnapshot()) throws -> AppModelTestContext {
        let context = try AppModelTestContext(languages: languages, snapshot: snapshot)
        addTeardownBlock { @MainActor in
            context.model.cancelPendingRadio()
            try await context.close()
        }
        return context
    }
}
