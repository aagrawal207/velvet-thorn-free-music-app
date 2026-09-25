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
        let radioRequests = await context.catalog.autoplayRadios.requests
        let artistRequests = await context.catalog.artists.requests
        let targeted = await context.catalog.radios.requests
        XCTAssertEqual(radioRequests.count, 4)
        XCTAssertEqual(artistRequests.count, 2)
        XCTAssertTrue(targeted.isEmpty)
        let reloaded = LibraryStore(directory: context.directory)
        XCTAssertEqual(reloaded.mix(.discoverWeekly)?.tracks, context.model.discoverWeekly?.tracks)
        XCTAssertEqual(reloaded.mix(.dailyMix)?.tracks, context.model.dailyMix?.tracks)
    }

    func testNudgeChangeCancelsOldMixWithoutLettingItsCleanupStopTheReplacement() async throws {
        let context = try makeContext(languages: [.hindi])
        let seed = context.seedListener(primary: AppModelFixtures.track("hindi-seed", language: .hindi), language: .hindi)
        let familiarIDs = Set(context.library.events.map(\.track.id))
        let oldTask = try XCTUnwrap(context.model.refreshMixes())
        let old = try await pendingHarvest(in: context, at: 0)
        context.model.setLanguageNudge(.more, for: .english)
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences.languageNudges[.english], .more)
        for request in old.radios {
            try await AppModelFixtures.eventually { await context.catalog.autoplayRadios.cancellations.contains(request.id) }
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
        let freshIDs = Set(mixedResponse.map(\.id))
        try await complete(current, with: mixedResponse, in: context)
        let daily = try await pendingHarvest(in: context, at: 2)
        XCTAssertEqual(Set(context.model.discoverWeekly?.tracks.map(\.id) ?? []), freshIDs)
        try await complete(daily, with: mixedResponse, in: context)
        await currentTask.value
        let dailyMix = try XCTUnwrap(context.model.dailyMix)
        XCTAssertEqual(dailyMix.tracks.count, 25)
        XCTAssertEqual(Set(dailyMix.tracks.map(\.id)).count, 25)
        XCTAssertTrue(familiarIDs.isSubset(of: Set(dailyMix.tracks.map(\.id))), "More English does not ban familiar Hindi songs")
        XCTAssertTrue(dailyMix.tracks.contains { $0.id == seed.id })
        XCTAssertEqual(dailyMix.tracks.filter { !familiarIDs.contains($0.id) }.count, 23)
        XCTAssertTrue(dailyMix.tracks.allSatisfy { familiarIDs.contains($0.id) || freshIDs.contains($0.id) })
        XCTAssertEqual(Set(dailyMix.tracks.compactMap(\.language)), [.hindi, .english])
        XCTAssertFalse(context.library.mixes.flatMap(\.tracks).contains { $0.id.hasPrefix("old-hindi") })
        XCTAssertEqual(context.library.mixes.count, 2)
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertNil(context.library.errorMessage)
        try assertSavedMixes(in: context)
    }

    func testNudgeChangeBeforeTheTaskStartsPreventsCancelledProviderWork() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let task = try XCTUnwrap(context.model.refreshMixes())
        context.model.setLanguageNudge(.more, for: .hindi)
        await task.value
        let radios = await context.catalog.autoplayRadios.requests
        let artists = await context.catalog.artists.requests
        let targeted = await context.catalog.radios.requests
        XCTAssertTrue(radios.isEmpty)
        XCTAssertTrue(artists.isEmpty)
        XCTAssertTrue(targeted.isEmpty)
        XCTAssertTrue(context.library.mixes.isEmpty)
        XCTAssertFalse(context.model.isGeneratingMixes)
    }

    func testFailedNudgeSaveKeepsPendingMixGenerationAndAllowsPublication() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let original = context.model.listeningLanguageProfile
        let task = try XCTUnwrap(context.model.refreshMixes())
        let weekly = try await pendingHarvest(in: context, at: 0)
        try context.withBlockedLibraryFile {
            context.model.setLanguageNudge(.more, for: .hindi)
            XCTAssertNotNil(context.library.errorMessage)
            XCTAssertEqual(context.model.listeningLanguageProfile, original)
            XCTAssertTrue(context.model.isGeneratingMixes)
        }
        let cancellations = await context.catalog.autoplayRadios.cancellations
        XCTAssertTrue(weekly.radios.allSatisfy { !cancellations.contains($0.id) })
        let fresh = candidates("fresh", language: .english)
        try await complete(weekly, with: fresh, in: context)
        let daily = try await pendingHarvest(in: context, at: 1)
        try await complete(daily, with: fresh, in: context)
        await task.value
        XCTAssertEqual(Set(context.model.discoverWeekly?.tracks.map(\.id) ?? []), Set(fresh.map(\.id)))
        XCTAssertNotNil(context.model.dailyMix)
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertTrue(context.library.preferences.languageNudges.isAutomatic)
        try assertSavedMixes(in: context)
        XCTAssertNil(context.library.errorMessage)
    }

    func testDirectNudgePreferenceEditIsRecheckedBeforeSavingOrStartingTheDailyPhase() async throws {
        let context = try makeContext(languages: [.hindi])
        _ = context.seedListener(primary: AppModelFixtures.track("seed", language: .hindi), language: .hindi)
        let task = try XCTUnwrap(context.model.refreshMixes())
        let harvest = try await pendingHarvest(in: context, at: 0)
        context.library.preferences.languageNudges[.hindi] = .less
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences.languageNudges[.hindi], .less)
        try await complete(harvest, with: candidates("hindi", language: .hindi), in: context)
        await task.value
        XCTAssertTrue(context.library.mixes.isEmpty)
        XCTAssertFalse(context.model.isGeneratingMixes)
        let radios = await context.catalog.autoplayRadios.requests
        let artists = await context.catalog.artists.requests
        XCTAssertEqual(radios.count, 2, "Obsolete weekly work must not start a daily request from the same snapshot")
        XCTAssertEqual(artists.count, 1)
    }

    func testReturningToTheOriginalNudgeCannotReviveARetiredSnapshot() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let task = try XCTUnwrap(context.model.refreshMixes())
        let harvest = try await pendingHarvest(in: context, at: 0)
        let originalKey = context.model.listeningLanguageProfile.requestKey
        context.model.setLanguageNudge(.more, for: .hindi)
        context.model.setLanguageNudge(.automatic, for: .hindi)
        XCTAssertEqual(context.model.listeningLanguageProfile.requestKey, originalKey)
        try await complete(harvest, with: candidates("obsolete", language: .english), in: context)
        await task.value
        XCTAssertTrue(context.library.mixes.isEmpty)
        XCTAssertFalse(context.model.isGeneratingMixes)
    }

    func testClearedHistoryRetiresPendingMixWithoutBlockingANewListeningProfile() async throws {
        let context = try makeContext()
        context.model.setLanguageNudge(.more, for: .english)
        _ = context.seedListener(primary: AppModelFixtures.track("forgotten-seed"))
        let oldTask = try XCTUnwrap(context.model.refreshMixes())
        let old = try await pendingHarvest(in: context, at: 0)
        context.library.clearHistory()
        XCTAssertFalse(context.model.hasListeningProfile)
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertNil(context.model.refreshMixes())
        XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 0)
        XCTAssertEqual(context.library.preferences.languageNudges[.english], .more)

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
        XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 3)
    }

    func testPendingWorkCannotOverwriteAMixAlreadySavedForTheCurrentPeriod() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let task = try XCTUnwrap(context.model.refreshMixes())
        let harvest = try await pendingHarvest(in: context, at: 0)
        let proposed = GeneratedPlaylist(kind: .discoverWeekly, tracks: [AppModelFixtures.track("retained")],
            generatedAt: Date().addingTimeInterval(-60),
            periodKey: RecommendationEngine.weekKey(for: Date(), calendar: .autoupdatingCurrent), seedArtists: ["Retained artist"])
        context.library.saveMix(proposed)
        let retained = try XCTUnwrap(context.library.mix(.discoverWeekly))
        try await complete(harvest, with: candidates("late", language: .english), in: context)
        let daily = try await pendingHarvest(in: context, at: 1)
        XCTAssertEqual(context.model.discoverWeekly, retained)
        try await complete(daily, with: candidates("daily", language: .english), in: context)
        await task.value
        XCTAssertEqual(context.model.discoverWeekly, retained)
        XCTAssertNotNil(context.model.dailyMix)
        XCTAssertNil(context.model.refreshMixes())
        let saved = context.library.mixes
        let calls = await context.catalog.autoplayRadios.requests.count
        context.model.setLanguageNudge(.more, for: .tamil)
        XCTAssertNil(context.model.refreshMixes(), "A soft nudge affects future periods, not a saved mix's order")
        XCTAssertEqual(context.library.mixes, saved)
        try assertSavedMixes(in: context)
        let afterNudge = await context.catalog.autoplayRadios.requests.count
        XCTAssertEqual(afterNudge, calls)
    }

    private struct Harvest {
        let radios: [AppModelRequestGate<Track, [Track]>.Request]
        let artist: AppModelRequestGate<String, ArtistPage>.Request
    }

    private func pendingHarvest(in context: AppModelTestContext, at index: Int) async throws -> Harvest {
        // seedListener provides two recordings and one linked artist, with no related-artist fan-out.
        let radios = [try await context.catalog.autoplayRadios.request(at: index * 2),
                      try await context.catalog.autoplayRadios.request(at: index * 2 + 1)]
        let artist = try await context.catalog.artists.request(at: index)
        return Harvest(radios: radios, artist: artist)
    }

    private func complete(_ harvest: Harvest, with tracks: [Track], in context: AppModelTestContext) async throws {
        for request in harvest.radios { try await context.catalog.autoplayRadios.complete(request, with: .success(tracks)) }
        try await context.catalog.artists.complete(harvest.artist, with: .success(context.artistPage(harvest.artist.input, songs: tracks)))
    }

    private func candidates(_ prefix: String, language: MusicLanguage) -> [Track] {
        (0..<12).map { RecommendationFixtures.track("\(prefix)-\($0)", artist: "\(prefix) artist \($0)", language: language) }
    }

    private func assertSavedMixes(in context: AppModelTestContext) throws {
        let restored = LibraryStore(directory: context.directory)
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.mixes.map(\.kind), context.library.mixes.map(\.kind))
        for expected in context.library.mixes {
            let actual = try XCTUnwrap(restored.mix(expected.kind))
            XCTAssertEqual(actual.tracks, expected.tracks)
            XCTAssertEqual(actual.periodKey, expected.periodKey)
            XCTAssertEqual(actual.seedArtists, expected.seedArtists)
            XCTAssertEqual(actual.generatedAt.timeIntervalSince1970, expected.generatedAt.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    private func makeContext(languages: Set<MusicLanguage> = [.english]) throws -> AppModelTestContext {
        let context = try AppModelTestContext(languages: languages, generatesMixes: true)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
