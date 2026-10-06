import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelListeningLanguageTests: XCTestCase {
    func testDurableCheckpointsUpdateCountsImmediatelyWithoutUsingProviderPlayCount() async throws {
        let context = try makeContext()
        var song = AppModelFixtures.track("counted-song", language: .hindi)
        song.playCount = 9_000_000_000
        let callback = try XCTUnwrap(context.player.onListeningProgress)
        let session = UUID()
        let started = Date().addingTimeInterval(-120)
        context.player.onTrackStarted?(song)
        XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 0)

        XCTAssertTrue(callback(song, session, started, 29))
        XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 0)
        XCTAssertEqual(context.library.events.first?.listenedSeconds, 29)
        XCTAssertTrue(callback(song, session, started, 1))
        let counted = context.model.listeningLanguageSummary()
        XCTAssertEqual(counted.totalPlays, 1)
        XCTAssertEqual(counted.totalSongs, 1)
        XCTAssertEqual(counted.rows.map(\.language), [.hindi])
        XCTAssertEqual(counted.rows.first?.plays, 1)
        XCTAssertTrue(context.model.listeningLanguageProfile.isLearned)
        XCTAssertEqual(context.model.listeningLanguageProfile.orderedLanguages, [.hindi])

        XCTAssertTrue(callback(song, session, started, 30))
        XCTAssertEqual(context.model.listeningLanguageSummary(), counted, "A second checkpoint is not a second play")
        let restored = LibraryStore(directory: context.directory)
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.events.first?.listenedSeconds, 60)
        XCTAssertEqual(restored.events.first?.track.playCount, 9_000_000_000)
        XCTAssertEqual(restored.languageSummary(for: .month), counted)
    }

    func testFiveQualifiedPlaysProduceUsableRollingLanguageProportions() throws {
        let context = try makeContext(languages: [.english])
        let now = Date()
        let hindi = AppModelFixtures.track("hindi", language: .hindi)
        let english = AppModelFixtures.track("english")
        for index in 1...4 { try record(hindi, in: context, startedAt: now.addingTimeInterval(-Double(index) * 60)) }
        try record(english, in: context, startedAt: now.addingTimeInterval(-360))
        try record(hindi, in: context, startedAt: now.addingTimeInterval(-31 * 86_400))

        let month = context.model.listeningLanguageSummary(for: .month, now: now)
        let hindiStat = try XCTUnwrap(month.rows.first { $0.language == .hindi })
        let englishStat = try XCTUnwrap(month.rows.first { $0.language == .english })
        XCTAssertEqual(month.totalPlays, 5)
        XCTAssertEqual(month.totalSongs, 2)
        XCTAssertEqual(month.unclassifiedPlays, 0)
        XCTAssertEqual(hindiStat.plays, 4)
        XCTAssertEqual(englishStat.plays, 1)
        XCTAssertEqual(hindiStat.share, 0.8, accuracy: 1e-12)
        XCTAssertEqual(englishStat.share, 0.2, accuracy: 1e-12)
        XCTAssertEqual(context.model.listeningLanguageSummary(for: .year, now: now).totalPlays, 6)
        let profile = context.model.listeningLanguageProfile
        XCTAssertTrue(profile.isLearned)
        XCTAssertEqual(profile.orderedLanguages, [.hindi, .english])
        XCTAssertGreaterThan(try XCTUnwrap(profile.weights[.hindi]), try XCTUnwrap(profile.weights[.english]))
        XCTAssertEqual(Set(profile.scheduledLanguages(count: 4)), [.hindi, .english])
        XCTAssertEqual(context.library.preferences.languages, [.english], "Learning does not rewrite the legacy fallback")
    }

    func testFailedSavesCannotNudgeLearnOrInvalidatePendingHome() async throws {
        let context = try makeContext(languages: [.hindi])
        let hindi = AppModelFixtures.track("hindi", language: .hindi)
        try record(hindi, in: context)
        let original = context.model.listeningLanguageProfile
        let home = context.start { await $0.loadHome() }
        let radio = try await context.catalog.autoplayRadios.request(at: 0)
        let chart = try await context.charts.charts.request(at: 0)
        let english = AppModelFixtures.track("unsaved-english")
        let callback = try XCTUnwrap(context.player.onListeningProgress)
        let session = UUID()
        let started = Date().addingTimeInterval(-60)
        try context.withBlockedLibraryFile {
            context.model.setLanguageNudge(.more, for: .english)
            XCTAssertNotNil(context.library.errorMessage)
            XCTAssertTrue(context.library.preferences.languageNudges.isAutomatic)
            XCTAssertFalse(callback(english, session, started, 30))
            XCTAssertEqual(context.model.listeningLanguageProfile, original)
            XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 1)
            XCTAssertTrue(context.model.isLoadingHome, "Rejected preferences cannot retire a valid request")
        }
        let restored = LibraryStore(directory: context.directory)
        XCTAssertEqual(restored.events.map(\.track.id), [hindi.id])
        XCTAssertTrue(restored.preferences.languageNudges.isAutomatic)
        let candidate = AppModelFixtures.track("still-current", language: .hindi)
        try await context.catalog.autoplayRadios.complete(radio, with: .success([candidate]))
        try await context.charts.charts.complete(chart, with: .success(AppModelFixtures.chart("still-current-chart", language: .hindi)))
        await home.value
        XCTAssertEqual(context.model.homeSections.map(\.id), ["discovery.language.hi"])
        XCTAssertEqual(context.model.homeSections.first?.tracks, [candidate])
        XCTAssertEqual(context.model.charts.map(\.id), ["still-current-chart"])
        XCTAssertNil(context.model.homeError)
        XCTAssertFalse(context.model.isLoadingHome)

        XCTAssertTrue(callback(english, session, started, 30), "The rejected checkpoint remains retryable after storage recovers")
        XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 2)
        context.model.setLanguageNudge(.more, for: .english)
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences.languageNudges[.english], .more)
        XCTAssertNil(context.library.errorMessage)
    }

    func testHistoryOffPreservesLearnedEvidenceAndCountsButAddsNoNewPlays() async throws {
        let calls = CatalogTestRecorder<Track>()
        let evidence = work(.tamil)
        let context = try makeContext(metadataLookup: { track in calls.record(track); return evidence })
        context.model.activateDeviceServices()
        var song = AppModelFixtures.track("classified-song")
        song.language = nil
        try record(song, in: context)
        await context.model.languageDiscovery.waitForChecks()
        let before = context.model.listeningLanguageSummary()
        XCTAssertEqual(before.totalPlays, 1)
        XCTAssertEqual(before.rows.first?.language, .tamil)
        XCTAssertEqual(context.model.listeningLanguageProfile.language(for: song), .tamil)

        context.model.updatePreferences { $0.saveListeningHistory = false }
        XCTAssertEqual(context.model.listeningLanguageSummary(), before)
        try record(AppModelFixtures.track("not-recorded"), in: context)
        context.model.refreshListeningLanguages()
        await context.model.languageDiscovery.waitForChecks()
        XCTAssertEqual(context.model.listeningLanguageSummary(), before)
        XCTAssertTrue(context.model.listeningLanguageProfile.isLearned)
        XCTAssertFalse(context.model.languageDiscovery.isChecking)
        XCTAssertEqual(context.library.events.map(\.track.id), [song.id])
        XCTAssertEqual(calls.values.map(\.id), [song.id])
        let restored = LibraryStore(directory: context.directory)
        XCTAssertFalse(restored.preferences.saveListeningHistory)
        XCTAssertEqual(restored.events.map(\.track.id), [song.id])
    }

    func testClearRetiresDerivedEvidenceAndPendingChecksWhileKeepingNudges() async throws {
        let metadata = AppModelRequestGate<Track, ArtistSongLanguageResult?>()
        addTeardownBlock { await metadata.close() }
        let context = try makeContext(metadataLookup: { try await metadata.receive($0) })
        context.model.activateDeviceServices()
        context.model.setLanguageNudge(.more, for: .tamil)
        var first = AppModelFixtures.track("identified")
        first.language = nil
        try record(first, in: context)
        let initial = try await metadata.request(at: 0)
        try await metadata.complete(initial, with: .success(work(.tamil)))
        await context.model.languageDiscovery.waitForChecks()
        XCTAssertEqual(context.model.languageDiscovery.results[LyricsRequestKey(first)]?.language, .tamil)

        var second = AppModelFixtures.track("pending")
        second.language = nil
        try record(second, in: context)
        let pending = try await metadata.request(at: 1)
        try context.withBlockedLibraryFile {
            context.library.clearHistory()
            XCTAssertNotNil(context.library.errorMessage)
            XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 2)
            XCTAssertEqual(context.model.languageDiscovery.results[LyricsRequestKey(first)]?.language, .tamil)
            XCTAssertTrue(context.model.languageDiscovery.isChecking)
        }
        context.library.clearHistory()
        XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 0)
        XCTAssertTrue(context.model.languageDiscovery.results.isEmpty)
        XCTAssertFalse(context.model.languageDiscovery.isChecking)
        XCTAssertFalse(context.model.listeningLanguageProfile.isLearned)
        try await metadata.complete(pending, with: .success(work(.english)))
        await context.model.languageDiscovery.waitForChecks()
        XCTAssertTrue(context.model.languageDiscovery.results.isEmpty)
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertTrue(context.library.mixes.isEmpty)
        XCTAssertNil(context.model.listeningLanguageProfile.language(for: first))
        XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 0)
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences.languageNudges[.tamil], .more)

        context.model.resetLanguageNudges()
        XCTAssertTrue(context.library.preferences.languageNudges.isAutomatic)
        XCTAssertTrue(LibraryStore(directory: context.directory).preferences.languageNudges.isAutomatic)
        XCTAssertFalse(context.model.listeningLanguageProfile.isLearned)
    }

    func testPassiveLearningDoesNotCancelAutomaticRadioStartup() async throws {
        let old = AppModelFixtures.track("keep-playing")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [old], position: 17))
        let anchor = AppModelFixtures.track("anchor")
        let station = station(anchor: anchor)
        let before = context.model.listeningLanguageProfile.requestKey
        let task = context.model.startRadio(station)
        let request = try await context.catalog.autoplayRadios.request(at: 0)
        XCTAssertEqual(request.input.id, anchor.id)
        try record(AppModelFixtures.track("new-hindi-listen", language: .hindi), in: context)
        XCTAssertNotEqual(context.model.listeningLanguageProfile.requestKey, before)
        XCTAssertEqual(context.model.listeningLanguageProfile.orderedLanguages, [.hindi])
        XCTAssertTrue(context.model.isLoadingRadio)
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 17)
        let cancelled = await context.catalog.autoplayRadios.cancellations
        XCTAssertFalse(cancelled.contains(request.id))
        let neighbors = (0..<3).map { AppModelFixtures.track("neighbor-\($0)") }
        try await context.catalog.autoplayRadios.complete(request, with: .success(neighbors))
        await task.value
        XCTAssertEqual(context.player.queue, [anchor] + neighbors)
        XCTAssertTrue(context.player.isRadioSession)
        XCTAssertEqual(context.model.activeRadioExperience, station)
        XCTAssertFalse(context.model.isLoadingRadio)
        XCTAssertNil(context.model.radioError)
    }

    func testDurableNudgeCancelsPendingRadioAndRejectsLateSuccess() async throws {
        let old = AppModelFixtures.track("keep-playing")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [old], position: 17))
        let anchor = AppModelFixtures.track("anchor")
        let task = context.model.startRadio(station(anchor: anchor))
        let request = try await context.catalog.autoplayRadios.request(at: 0)
        context.model.setLanguageNudge(.more, for: .hindi)
        XCTAssertFalse(context.model.isLoadingRadio)
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences.languageNudges[.hindi], .more)
        try await AppModelFixtures.eventually { await context.catalog.autoplayRadios.cancellations.contains(request.id) }
        try await context.catalog.autoplayRadios.complete(request, with: .success((0..<3).map { AppModelFixtures.track("late-\($0)") }))
        await task.value
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 17)
        XCTAssertFalse(context.player.isRadioSession)
        XCTAssertNil(context.model.activeRadioExperience)
        XCTAssertNil(context.model.selectedRadioExperience)
        XCTAssertNil(context.model.radioError)
    }

    func testColdDefaultsStayUnlearnedAfterCatalogResultsArePublished() async throws {
        let context = try makeContext(languages: [.hindi, .english])
        XCTAssertFalse(context.model.listeningLanguageProfile.isLearned)
        XCTAssertTrue(context.model.listeningLanguageSummary().rows.isEmpty)
        let task = context.start { await $0.loadHome() }
        let searches = [try await context.catalog.searches.request(at: 0), try await context.catalog.searches.request(at: 1)]
        let charts = [try await context.charts.charts.request(at: 0), try await context.charts.charts.request(at: 1)]
        var song = AppModelFixtures.track("catalog-only")
        song.language = nil
        for request in searches {
            XCTAssertEqual(request.input.filter, .songs)
            XCTAssertNil(request.input.continuation)
            try await context.catalog.searches.complete(request, with: .success(CatalogPage(tracks: [song])))
        }
        for chart in charts {
            try await context.charts.charts.complete(chart, with: .success(AppModelFixtures.chart("weekly-\(chart.input.rawValue)", language: chart.input)))
        }
        await task.value
        XCTAssertEqual(Set(searches.map(\.input.query)), ["Hindi songs", "English songs"])
        XCTAssertEqual(Set(context.model.homeSections.map(\.id)), ["discovery.language.hi", "discovery.language.en"])
        XCTAssertTrue(context.model.homeSections.allSatisfy { $0.subtitle == "A starting point while Velvet Thorn learns your listening" })
        XCTAssertTrue(context.model.homeSections.flatMap(\.tracks).allSatisfy { $0.language == nil })
        XCTAssertFalse(context.model.listeningLanguageProfile.isLearned)
        XCTAssertFalse(context.model.hasListeningProfile)
        XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 0)
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertEqual(context.model.languageDiscovery.activity.snapshotRecordings, 0)
        let legacy = await context.catalog.discoveries.requests
        XCTAssertTrue(legacy.isEmpty)
    }

    func testOtherKnownLanguageUsesBothChartScopesWithoutRetaggingDiscovery() async throws {
        let context = try makeContext(languages: [.hindi])
        var tamil = AppModelFixtures.track("tamil-recording")
        tamil.language = nil
        XCTAssertTrue(context.library.setRecordingLanguageOverride("ta", for: tamil.id))
        for _ in 0..<5 { try record(tamil, in: context) }
        XCTAssertEqual(context.model.listeningLanguageProfile.orderedLanguages, [.tamil])
        let task = context.start { await $0.loadHome() }
        let radio = try await context.catalog.autoplayRadios.request(at: 0)
        let charts = [try await context.charts.charts.request(at: 0), try await context.charts.charts.request(at: 1)]
        XCTAssertEqual(radio.input.id, tamil.id)
        XCTAssertEqual(Set(charts.map(\.input)), [.hindi, .english])
        let neighbor = RecommendationFixtures.track("unknown-neighbor", artist: "Another performer")
        try await context.catalog.autoplayRadios.complete(radio, with: .success([neighbor]))
        for chart in charts {
            try await context.charts.charts.complete(chart, with: .success(AppModelFixtures.chart("weekly-\(chart.input.rawValue)", language: chart.input)))
        }
        await task.value
        XCTAssertEqual(Set(context.model.charts.map(\.language)), [.hindi, .english])
        XCTAssertEqual(context.model.homeSections.map(\.id), ["discovery.language.ta"])
        XCTAssertNil(context.model.homeSections.first?.language)
        XCTAssertEqual(context.model.homeSections.first?.tracks, [neighbor])
        XCTAssertEqual(context.model.listeningLanguageSummary().rows.first?.plays, 5)
        XCTAssertEqual(context.model.listeningLanguageSummary().rows.first?.language, .tamil)
    }

    private func record(_ track: Track, in context: AppModelTestContext,
                        startedAt: Date = Date().addingTimeInterval(-60)) throws {
        let callback = try XCTUnwrap(context.player.onListeningProgress)
        guard callback(track, UUID(), startedAt, 30) else {
            throw AppModelTestFailure.storage(context.library.errorMessage ?? "Checkpoint was not acknowledged")
        }
    }

    private func work(_ language: ArtistSongLanguage) -> ArtistSongLanguageResult {
        .identified(language, source: .musicBrainzWork(recordingID: ArtistSpotlightMusicBrainzFixtures.recordingID,
                                                       workID: ArtistSpotlightMusicBrainzFixtures.workID))
    }

    private func station(anchor: Track) -> RadioExperience {
        RadioExperience(id: "automatic-model-radio", title: "Model radio", description: "Fixture", symbol: "radio",
                        discoveryLanguages: [.english], contentLabel: "English",
                        seeds: [.init(recording: anchor, artist: anchor.credits[0])])
    }

    private func makeContext(languages: Set<MusicLanguage> = [.english], snapshot: PlaybackSnapshot = PlaybackSnapshot(),
                             metadataLookup: ArtistSpotlightLanguageService.MetadataLookup? = nil) throws -> AppModelTestContext {
        let service = ArtistSpotlightLanguageService(provider: AppModelLyricsProvider(), metadataLookup: metadataLookup)
        let context = try AppModelTestContext(languages: languages, snapshot: snapshot, recordingLanguageService: service)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
