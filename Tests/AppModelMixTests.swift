import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelMixTests: XCTestCase {
    func testWeeklyAndDailyPublicationRecheckDislikesIncludingCapturedFamiliarSongs() async throws {
        let context = try makeContext()
        let seed = context.seedListener(primary: AppModelFixtures.track("seed"))
        let other = try XCTUnwrap(context.library.events.first { $0.track.id != seed.id }?.track)
        let fresh = candidates("fresh", language: .english)
        let task = try XCTUnwrap(context.model.refreshMixes())
        let weekly = try await pendingHarvest(in: context, at: 0)
        XCTAssertTrue(context.model.isGeneratingMixes)

        context.model.toggleDislike(fresh[0])
        try await complete(weekly, with: fresh, in: context)
        let daily = try await pendingHarvest(in: context, at: 1)
        XCTAssertEqual(Set(context.model.discoverWeekly?.tracks.map(\.id) ?? []), Set(fresh.dropFirst().map(\.id)))
        let weeklyDate = try XCTUnwrap(context.model.discoverWeekly?.generatedAt)
        let weeklyPeriod = try XCTUnwrap(context.model.discoverWeekly?.periodKey)

        context.model.toggleDislike(fresh[1])
        context.library.toggleDislike(seed)
        try await complete(daily, with: fresh, in: context)
        await task.value
        let allowed = Array(fresh.dropFirst(2))
        XCTAssertEqual(Set(context.model.discoverWeekly?.tracks.map(\.id) ?? []), Set(allowed.map(\.id)))
        XCTAssertEqual(Set(context.model.dailyMix?.tracks.map(\.id) ?? []), Set((allowed + [other]).map(\.id)),
                       "Daily familiar picks must not restore a seed disliked after the profile was captured")
        XCTAssertEqual(context.model.discoverWeekly?.generatedAt, weeklyDate)
        XCTAssertEqual(context.model.discoverWeekly?.periodKey, weeklyPeriod)
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertNil(context.library.errorMessage)

        let saved = context.library.mixes
        XCTAssertNil(context.model.refreshMixes())
        XCTAssertEqual(context.library.mixes, saved, "A dislike prunes the current period without reranking the remaining songs")
        let radioRequests = await context.catalog.radios.requests
        let artistRequests = await context.catalog.artists.requests
        XCTAssertEqual(radioRequests.count, 4)
        XCTAssertEqual(artistRequests.count, 2)
        let reloaded = LibraryStore(directory: context.directory)
        XCTAssertEqual(reloaded.mix(.discoverWeekly)?.tracks, context.model.discoverWeekly?.tracks)
        XCTAssertEqual(reloaded.mix(.dailyMix)?.tracks, context.model.dailyMix?.tracks)
    }

    func testLanguageChangeCancelsOldMixWithoutLettingItsCleanupStopTheReplacement() async throws {
        let context = try makeContext(languages: [.hindi])
        _ = context.seedListener(primary: AppModelFixtures.track("hindi-seed", language: .hindi), language: .hindi)
        let oldTask = try XCTUnwrap(context.model.refreshMixes())
        let old = try await pendingHarvest(in: context, at: 0)
        context.model.updatePreferences { $0.languages = [.english] }
        XCTAssertFalse(context.model.isGeneratingMixes)
        for request in old.radios {
            try await AppModelFixtures.eventually { await context.catalog.radios.cancellations.contains(request.id) }
        }
        try await AppModelFixtures.eventually { await context.catalog.artists.cancellations.contains(old.artist.id) }

        let currentTask = try XCTUnwrap(context.model.refreshMixes())
        let current = try await pendingHarvest(in: context, at: 1)
        try await complete(old, with: candidates("old-hindi", language: .hindi), in: context)
        await oldTask.value
        XCTAssertTrue(context.model.isGeneratingMixes, "Only the current generation owns its task and loading state")
        XCTAssertTrue(context.library.mixes.isEmpty)

        let english = candidates("english", language: .english)
        let mixedResponse = english + candidates("hindi", language: .hindi)
        try await complete(current, with: mixedResponse, in: context)
        let daily = try await pendingHarvest(in: context, at: 2)
        XCTAssertEqual(Set(context.model.discoverWeekly?.tracks.map(\.id) ?? []), Set(english.map(\.id)))
        try await complete(daily, with: mixedResponse, in: context)
        await currentTask.value
        XCTAssertEqual(Set(context.model.dailyMix?.tracks.map(\.id) ?? []), Set(english.map(\.id)),
                       "Familiar Hindi history cannot leak into a newly generated English mix")
        XCTAssertEqual(context.library.mixes.count, 2)
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertNil(context.library.errorMessage)
        XCTAssertTrue(LibraryStore(directory: context.directory).mixes.flatMap(\.tracks).allSatisfy { $0.language == .english })
    }

    func testLanguageChangeBeforeTheTaskStartsPreventsCancelledProviderWork() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let task = try XCTUnwrap(context.model.refreshMixes())
        context.model.updatePreferences { $0.languages = [.hindi] }
        await task.value
        let radios = await context.catalog.radios.requests
        let artists = await context.catalog.artists.requests
        XCTAssertTrue(radios.isEmpty)
        XCTAssertTrue(artists.isEmpty)
        XCTAssertTrue(context.library.mixes.isEmpty)
        XCTAssertFalse(context.model.isGeneratingMixes)
    }

    func testDirectPreferenceEditIsRecheckedBeforeSavingOrStartingTheDailyPhase() async throws {
        let context = try makeContext(languages: [.hindi])
        _ = context.seedListener(primary: AppModelFixtures.track("seed", language: .hindi), language: .hindi)
        let task = try XCTUnwrap(context.model.refreshMixes())
        let harvest = try await pendingHarvest(in: context, at: 0)
        context.library.preferences.languages = [.english]
        try await complete(harvest, with: candidates("hindi", language: .hindi), in: context)
        await task.value
        XCTAssertTrue(context.library.mixes.isEmpty)
        XCTAssertFalse(context.model.isGeneratingMixes)
        let radios = await context.catalog.radios.requests
        let artists = await context.catalog.artists.requests
        XCTAssertEqual(radios.count, 2, "Obsolete weekly work must not start a daily request from the same snapshot")
        XCTAssertEqual(artists.count, 1)
    }

    func testReturningToTheOriginalLanguageCannotReviveARetiredSnapshot() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let task = try XCTUnwrap(context.model.refreshMixes())
        let harvest = try await pendingHarvest(in: context, at: 0)
        context.model.updatePreferences { $0.languages = [.hindi] }
        context.model.updatePreferences { $0.languages = [.english] }
        try await complete(harvest, with: candidates("obsolete", language: .english), in: context)
        await task.value
        XCTAssertTrue(context.library.mixes.isEmpty)
        XCTAssertFalse(context.model.isGeneratingMixes)
    }

    func testClearedHistoryRetiresPendingMixWithoutBlockingANewListeningProfile() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("forgotten-seed"))
        let oldTask = try XCTUnwrap(context.model.refreshMixes())
        let old = try await pendingHarvest(in: context, at: 0)
        context.library.clearHistory()
        XCTAssertFalse(context.model.hasListeningProfile)
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertNil(context.model.refreshMixes())

        _ = context.seedListener(primary: AppModelFixtures.track("new-seed"))
        let currentTask = try XCTUnwrap(context.model.refreshMixes())
        let current = try await pendingHarvest(in: context, at: 1)
        try await complete(old, with: candidates("forgotten", language: .english), in: context)
        await oldTask.value
        XCTAssertTrue(context.model.isGeneratingMixes)
        XCTAssertTrue(context.model.hasListeningProfile)
        XCTAssertTrue(context.library.mixes.isEmpty)

        let fresh = candidates("new", language: .english)
        try await complete(current, with: fresh, in: context)
        let daily = try await pendingHarvest(in: context, at: 2)
        try await complete(daily, with: fresh, in: context)
        await currentTask.value
        XCTAssertEqual(Set(context.model.discoverWeekly?.tracks.map(\.id) ?? []), Set(fresh.map(\.id)))
        XCTAssertFalse(context.library.mixes.flatMap(\.tracks).contains { $0.id.hasPrefix("forgotten") })
        XCTAssertFalse(context.model.isGeneratingMixes)
    }

    func testPendingWorkCannotOverwriteAMixAlreadySavedForTheCurrentPeriod() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let task = try XCTUnwrap(context.model.refreshMixes())
        let harvest = try await pendingHarvest(in: context, at: 0)
        let retained = GeneratedPlaylist(kind: .discoverWeekly, tracks: [AppModelFixtures.track("retained")],
            generatedAt: Date().addingTimeInterval(-60),
            periodKey: RecommendationEngine.weekKey(for: Date(), calendar: .autoupdatingCurrent), seedArtists: ["Retained artist"])
        context.library.saveMix(retained)
        try await complete(harvest, with: candidates("late", language: .english), in: context)
        let daily = try await pendingHarvest(in: context, at: 1)
        XCTAssertEqual(context.model.discoverWeekly, retained)
        try await complete(daily, with: candidates("daily", language: .english), in: context)
        await task.value
        XCTAssertEqual(context.model.discoverWeekly, retained)
        XCTAssertNotNil(context.model.dailyMix)
        XCTAssertNil(context.model.refreshMixes())
    }

    private struct Harvest {
        let radios: [AppModelRequestGate<AppModelRadioRequest, [Track]>.Request]
        let artist: AppModelRequestGate<String, ArtistPage>.Request
    }

    private func pendingHarvest(in context: AppModelTestContext, at index: Int) async throws -> Harvest {
        // seedListener provides two recordings and one linked artist, with no related-artist fan-out.
        let radios = [try await context.catalog.radios.request(at: index * 2),
                      try await context.catalog.radios.request(at: index * 2 + 1)]
        let artist = try await context.catalog.artists.request(at: index)
        return Harvest(radios: radios, artist: artist)
    }

    private func complete(_ harvest: Harvest, with tracks: [Track], in context: AppModelTestContext) async throws {
        for request in harvest.radios { try await context.catalog.radios.complete(request, with: .success(tracks)) }
        try await context.catalog.artists.complete(harvest.artist, with: .success(context.artistPage(harvest.artist.input, songs: tracks)))
    }

    private func candidates(_ prefix: String, language: MusicLanguage) -> [Track] {
        (0..<12).map { RecommendationFixtures.track("\(prefix)-\($0)", artist: "\(prefix) artist \($0)", language: language) }
    }

    private func makeContext(languages: Set<MusicLanguage> = [.english]) throws -> AppModelTestContext {
        let context = try AppModelTestContext(languages: languages, generatesMixes: true)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
