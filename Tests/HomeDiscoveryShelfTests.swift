import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class HomeDiscoveryShelfTests: XCTestCase {
    func testHomeUsesAutomaticLanguageShelvesWithoutCallingLegacyDiscoveryOrHardFilteringSongs() async throws {
        let context = try makeContext(languages: [.hindi, .english])
        let hindi = RecommendationFixtures.track("hindi", artist: "Hindi performer", language: .hindi)
        let english = RecommendationFixtures.track("english", artist: "English performer", language: .english)
        let unknown = RecommendationFixtures.track("unknown", artist: "Unclassified performer")
        let songs = [hindi, english, unknown]
        await loadColdDiscovery(songs, in: context)
        XCTAssertEqual(Set(context.model.homeSections.map(\.id)), ["discovery.language.hi", "discovery.language.en"])
        for section in context.model.homeSections {
            XCTAssertEqual(Set(section.tracks.map(\.id)), Set(songs.map(\.id)))
            XCTAssertNil(section.tracks.first { $0.id == unknown.id }?.language)
        }
        let searches = await context.catalog.searches.requests
        let legacy = await context.catalog.discoveries.requests
        let targeted = await context.catalog.radios.requests
        XCTAssertEqual(Set(searches.map(\.input.query)), ["Hindi songs", "English songs"])
        XCTAssertTrue(searches.allSatisfy { $0.input.filter == .songs && $0.input.continuation == nil })
        XCTAssertTrue(legacy.isEmpty && targeted.isEmpty)
        XCTAssertTrue(context.library.preferences.homeLayout.isVisible(.discovery))
        XCTAssertTrue(context.library.preferences.homeLayout.isVisible(.becauseYouLike))
    }

    func testRefreshingLanguageShelvesKeepsPersonalSectionsAndDropsSuccessfulEmptyDiscovery() async throws {
        let context = try makeContext()
        let seed = context.seedListener(primary: AppModelFixtures.track("listener"))
        let artistID = try XCTUnwrap(seed.artistID)
        let personal = AppModelFixtures.track("personal-pick")
        let discovered = AppModelFixtures.track("language-pick")
        for hasDiscovery in [true, false] {
            await context.catalog.artists.enqueue(.success(context.artistPage(artistID, songs: [personal])))
            await context.catalog.autoplayRadios.enqueue(.success(hasDiscovery ? [discovered] : []))
            if !hasDiscovery { await context.catalog.searches.enqueue(.success(CatalogPage())) }
            await context.charts.charts.enqueue(.failure(MusicServiceError.unavailable("No chart fixture")))
            await context.model.loadHome(force: true)
            XCTAssertEqual(context.model.homeSections.map(\.id), ["personal.\(artistID)"] + (hasDiscovery ? ["discovery.language.en"] : []))
            XCTAssertEqual(context.model.homeSections.first?.tracks, [personal])
            if hasDiscovery { XCTAssertEqual(context.model.homeSections.last?.tracks, [discovered]) }
            XCTAssertNil(context.model.homeError)
        }
        let radios = await context.catalog.autoplayRadios.requests
        let searches = await context.catalog.searches.requests
        XCTAssertEqual(radios.map(\.input.id), [seed.id, seed.id])
        XCTAssertEqual(searches.map(\.input.query), ["English songs"])
    }

    func testHidingDiscoveryPreservesFavoritesRecentsAndAutoplayEligibility() async throws {
        let context = try makeContext()
        let song = RecommendationFixtures.track("still-liked", title: "A song from the hitlist", language: .english)
        context.library.toggleFavorite(song)
        context.library.recordRecent(track: song, position: 15)
        context.model.updatePreferences { $0.homeLayout.setVisible(false, for: .discovery) }
        await loadColdDiscovery([song], in: context)
        XCTAssertFalse(context.library.preferences.homeLayout.isVisible(.discovery))
        XCTAssertFalse(LibraryStore(directory: context.directory).preferences.homeLayout.isVisible(.discovery))
        XCTAssertEqual(context.model.homeSections.map(\.id), ["discovery.language.en"], "Visibility is presentation state, not a catalog or song exclusion")
        XCTAssertEqual(context.model.homeSections.first?.tracks, [song])
        XCTAssertEqual(context.library.favorites, [song])
        XCTAssertEqual(context.library.recentlyPlayed.first?.track, song)
        XCTAssertTrue(context.library.disliked.isEmpty)
        XCTAssertTrue(context.library.recentSearchSelections.isEmpty)
        XCTAssertEqual(MusicAppModel.autoplaySelection(from: [song], queue: [], disliked: context.library.dislikedTrackIDs), [song])
    }

    func testWeeklyChartRefreshReplacesTheLanguageSlotAcrossReportingPeriods() async throws {
        let context = try makeContext(languages: [.english, .hindi])
        let english = AppModelFixtures.chart("weekly-us-first")
        let hindi = AppModelFixtures.chart("weekly-in-first", language: .hindi)
        try await refreshCharts([english, hindi], in: context)
        var nextWeek = AppModelFixtures.chart("weekly-us-second")
        nextWeek.periodStart = english.periodStart?.addingTimeInterval(7 * 86_400)
        nextWeek.periodEnd = english.periodEnd?.addingTimeInterval(7 * 86_400)
        nextWeek.fetchedAt = english.fetchedAt.addingTimeInterval(7 * 86_400)
        nextWeek.entries = [ChartEntry(rank: 7, track: AppModelFixtures.track("new-week-song"), views: 123_456, previousRank: 12)]
        try await refreshCharts([nextWeek], in: context)

        XCTAssertEqual(context.model.charts.count, 2)
        XCTAssertEqual(Set(context.model.charts.map(\.id)), [nextWeek.id, hindi.id])
        try assertChart(nextWeek, in: context)
        try assertChart(hindi, in: context)
        XCTAssertFalse(context.model.isLoadingHome)
        XCTAssertNil(context.model.homeError)
    }

    func testGlobalChartFallbackReplacesItsRegionalSlotAndKeepsTheOtherLanguage() async throws {
        let context = try makeContext(languages: [.english, .hindi])
        var regional = AppModelFixtures.chart("weekly-us")
        regional.source = "YouTube Charts · United States"
        let hindi = AppModelFixtures.chart("weekly-in", language: .hindi)
        try await refreshCharts([regional, hindi], in: context)
        var fallback = AppModelFixtures.chart("weekly-global")
        fallback.source = "YouTube Charts · Global"
        fallback.subtitle = "Worldwide weekly songs"
        fallback.entries = [ChartEntry(rank: 11, track: AppModelFixtures.track("global-song"), views: 987_654, previousRank: 18)]
        try await refreshCharts([fallback], in: context)

        XCTAssertEqual(context.model.charts.count, 2)
        XCTAssertEqual(Set(context.model.charts.map(\.id)), [fallback.id, hindi.id])
        try assertChart(fallback, in: context)
        try assertChart(hindi, in: context)
    }

    private func refreshCharts(_ snapshots: [ChartSnapshot], in context: AppModelTestContext) async throws {
        let offset = await context.charts.charts.requests.count
        XCTAssertFalse(context.model.listeningLanguageProfile.isLearned)
        for _ in 0..<2 {
            await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [AppModelFixtures.track("public-discovery")])))
        }
        let task = context.start { await $0.loadHome(force: true) }
        var requested: Set<MusicLanguage> = []
        for index in 0..<2 {
            let request = try await context.charts.charts.request(at: offset + index)
            requested.insert(request.input)
            let result: Result<ChartSnapshot, any Error>
            if let snapshot = snapshots.first(where: { $0.language == request.input }) { result = .success(snapshot) }
            else { result = .failure(MusicServiceError.unavailable("Other language chart is unchanged")) }
            try await context.charts.charts.complete(request, with: result)
        }
        await task.value
        XCTAssertEqual(requested, [.hindi, .english])
    }

    private func assertChart(_ expected: ChartSnapshot, in context: AppModelTestContext,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(context.model.charts.first { $0.language == expected.language }, file: file, line: line)
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.title, expected.title, file: file, line: line)
        XCTAssertEqual(actual.subtitle, expected.subtitle, file: file, line: line)
        XCTAssertEqual(actual.source, expected.source, file: file, line: line)
        XCTAssertEqual(actual.periodStart, expected.periodStart, file: file, line: line)
        XCTAssertEqual(actual.periodEnd, expected.periodEnd, file: file, line: line)
        XCTAssertEqual(actual.fetchedAt, expected.fetchedAt, file: file, line: line)
        XCTAssertEqual(actual.entries.map(\.rank), expected.entries.map(\.rank), file: file, line: line)
        XCTAssertEqual(actual.entries.map(\.previousRank), expected.entries.map(\.previousRank), file: file, line: line)
        XCTAssertEqual(actual.entries.map(\.views), expected.entries.map(\.views), file: file, line: line)
        XCTAssertEqual(actual.entries.map(\.track), expected.entries.map(\.track), file: file, line: line)
    }

    private func loadColdDiscovery(_ tracks: [Track], in context: AppModelTestContext) async {
        XCTAssertFalse(context.model.listeningLanguageProfile.isLearned)
        for _ in context.library.preferences.languages {
            await context.catalog.searches.enqueue(.success(CatalogPage(tracks: tracks)))
            await context.charts.charts.enqueue(.failure(MusicServiceError.unavailable("No chart fixture")))
        }
        await context.model.loadHome(force: true)
    }

    private func makeContext(languages: Set<MusicLanguage> = [.english]) throws -> AppModelTestContext {
        let context = try AppModelTestContext(languages: languages)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
