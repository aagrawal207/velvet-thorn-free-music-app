import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class HomeDiscoveryShelfTests: XCTestCase {
    func testHomeRemovesOnlyTheTwoHitlistIDsAndKeepsOtherEditorialAndRadio() async throws {
        let context = try makeContext(languages: [.hindi, .english])
        var hindiHitlist = AppModelFixtures.section("editorial-hindi", language: .hindi)
        hindiHitlist.title = "A renamed provider hitlist"
        var englishHitlist = AppModelFixtures.section("editorial-english")
        englishHitlist.title = "Another renamed provider hitlist"
        let hindiRadio = AppModelFixtures.section("radio-hindi", language: .hindi)
        let englishRadio = AppModelFixtures.section("radio-english")
        var otherEditorial = AppModelFixtures.section("editorial-acoustic")
        otherEditorial.title = "Pop hits"
        var futureEditorial = AppModelFixtures.section("editorial-classics", language: .hindi)
        futureEditorial.title = "Bollywood hits"
        let fallback = AppModelFixtures.section("starter-hindi", language: .hindi)
        await load([hindiHitlist, englishHitlist, hindiRadio, englishRadio, otherEditorial, futureEditorial, fallback], in: context)
        XCTAssertEqual(context.model.homeSections.map(\.id), ["radio-hindi", "radio-english", "editorial-acoustic", "editorial-classics", "starter-hindi"])
        XCTAssertEqual(context.model.homeSections.flatMap(\.tracks), [hindiRadio, englishRadio, otherEditorial, futureEditorial, fallback].flatMap(\.tracks))
        XCTAssertTrue(context.library.preferences.homeLayout.isVisible(.discovery))
        XCTAssertTrue(context.library.preferences.homeLayout.isVisible(.becauseYouLike))
    }

    func testHitlistsStayRemovedOnRefreshWithoutDisplacingPersonalRadio() async throws {
        let context = try makeContext()
        let seed = context.seedListener(primary: AppModelFixtures.track("listener"))
        let artistID = try XCTUnwrap(seed.artistID)
        let personal = AppModelFixtures.track("personal-pick")
        for includeRadio in [true, false] {
            await context.catalog.artists.enqueue(.success(context.artistPage(artistID, songs: [personal])))
            let hitlists = [AppModelFixtures.section("editorial-hindi", language: .hindi), AppModelFixtures.section("editorial-english")]
            let radio = includeRadio ? [AppModelFixtures.section("radio-english")] : []
            await load(hitlists + radio, in: context)
            XCTAssertEqual(context.model.homeSections.map(\.id), ["personal.\(artistID)"] + radio.map(\.id))
            XCTAssertEqual(context.model.homeSections.first?.tracks, [personal])
            XCTAssertNil(context.model.homeError)
        }
    }

    func testRemovingShelvesDoesNotDislikeOrRemoveTheirSongsFromTheLibrary() async throws {
        let context = try makeContext()
        let song = RecommendationFixtures.track("still-liked", title: "A song from the hitlist", language: .english)
        context.library.toggleFavorite(song)
        context.library.recordRecent(track: song, position: 15)
        await load([DiscoverySection(id: "editorial-english", title: "Pop hits", language: .english, tracks: [song])], in: context)
        XCTAssertTrue(context.model.homeSections.isEmpty)
        XCTAssertEqual(context.library.favorites, [song])
        XCTAssertEqual(context.library.recentlyPlayed.first?.track, song)
        XCTAssertTrue(context.library.disliked.isEmpty)
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
        await context.catalog.discoveries.enqueue(.success([AppModelFixtures.section("public-discovery")]))
        let task = context.start { await $0.loadHome(force: true) }
        for index in 0..<context.library.preferences.languages.count {
            let request = try await context.charts.charts.request(at: offset + index)
            let result: Result<ChartSnapshot, any Error>
            if let snapshot = snapshots.first(where: { $0.language == request.input }) { result = .success(snapshot) }
            else { result = .failure(MusicServiceError.unavailable("Other language chart is unchanged")) }
            try await context.charts.charts.complete(request, with: result)
        }
        await task.value
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

    private func load(_ sections: [DiscoverySection], in context: AppModelTestContext) async {
        await context.catalog.discoveries.enqueue(.success(sections))
        for _ in context.library.preferences.languages {
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
