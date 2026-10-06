import Foundation
import Observation
import XCTest
@testable import GanaBajana

@MainActor
final class ListeningProjectionCacheTests: XCTestCase {
    func testRepeatedProfileAndSummaryReadsBuildOnceAndPlaybackOnlyCommitHits() throws {
        let context = try makeContext()
        let now = minuteNow()
        let song = AppModelFixtures.track("cached", language: .hindi)
        record(song, in: context, at: now.addingTimeInterval(-120))
        context.model.genreEvidence.record(GenreFixtures.distribution([(.pop, 1)]), for: LyricsRequestKey(song))

        for offset in 0..<30 {
            let date = now.addingTimeInterval(Double(offset))
            XCTAssertEqual(context.model.listeningLanguageProfile(now: date).orderedLanguages, [.hindi])
            XCTAssertEqual(context.model.listeningGenreProfile(now: date).topFamily, .pop)
            XCTAssertEqual(context.model.listeningLanguageSummary(now: date).totalPlays, 1)
            XCTAssertEqual(context.model.listeningGenreSummary(now: date).totalPlays, 1)
        }
        let counts = context.model.listeningProjectionBuildCounts
        XCTAssertEqual(counts, [.summary: 1, .languageSummary: 1, .genreSummary: 1, .languageProfile: 1, .genreProfile: 1])
        let historyRevision = context.library.historyRevision
        context.library.updatePlayback(PlaybackSnapshot(queue: [song], position: 17))
        XCTAssertNil(context.library.errorMessage)
        XCTAssertEqual(context.library.historyRevision, historyRevision)
        _ = context.model.listeningLanguageProfile(now: now)
        _ = context.model.listeningGenreProfile(now: now)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts, counts)
    }

    func testSecondsAndMetadataCorrectionsInvalidateWithoutChangingEventCount() throws {
        let context = try makeContext()
        let now = minuteNow()
        var song = AppModelFixtures.track("corrected", language: .english)
        let session = UUID()
        let started = now.addingTimeInterval(-120)
        record(song, in: context, id: session, at: started, seconds: 29)
        XCTAssertEqual(context.model.listeningLanguageSummary(now: now).totalPlays, 0)
        record(song, in: context, id: session, at: started, seconds: 1)
        XCTAssertEqual(context.model.listeningLanguageSummary(now: now).rows.first?.language, .english)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.summary], 2)

        song.language = .hindi
        song.title = "Corrected title"
        song.artists = ["Corrected performer"]
        try replaceSavedEvents(in: context) { $0[0].track = song }
        XCTAssertEqual(context.library.events.count, 1)
        XCTAssertEqual(context.model.listeningLanguageProfile(now: now).orderedLanguages, [.hindi])
        let summary = context.model.listeningSummary(now: now)
        XCTAssertEqual(summary.seconds, 30)
        XCTAssertEqual(summary.topTracks.first?.track.title, "Corrected title")
        XCTAssertEqual(summary.topArtists.first?.name, "Corrected performer")
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.summary], 3)
    }

    func testReloadSameCountSameTotalAndSameLastSessionInvalidatesBothProfiles() throws {
        let context = try makeContext()
        let now = minuteNow()
        let first = AppModelFixtures.track("replaced", language: .english)
        let last = AppModelFixtures.track("unchanged-last", language: .english)
        record(first, in: context, at: now.addingTimeInterval(-60))
        record(last, in: context, at: now.addingTimeInterval(-120))
        context.model.genreEvidence.record(GenreFixtures.distribution([(.rock, 1)]), for: LyricsRequestKey(first))
        XCTAssertTrue(context.model.listeningGenreProfile(now: now).isLearned)
        XCTAssertEqual(context.model.listeningLanguageProfile(now: now).orderedLanguages, [.english])
        let lastID = context.library.events.last?.id
        let before = context.model.listeningProjectionBuildCounts
        let replacement = AppModelFixtures.track("replacement", language: .hindi)
        try replaceSavedEvents(in: context) { events in events[0].track = replacement }

        XCTAssertEqual(context.library.events.count, 2)
        XCTAssertEqual(context.library.events.last?.id, lastID)
        XCTAssertEqual(context.model.listeningSummary(now: now).seconds, 60)
        XCTAssertEqual(Set(context.model.listeningLanguageProfile(now: now).orderedLanguages), [.english, .hindi])
        XCTAssertFalse(context.model.listeningGenreProfile(now: now).isLearned)
        for kind in [MusicAppModel.ListeningProjectionKind.summary, .languageProfile, .genreProfile] {
            XCTAssertEqual(context.model.listeningProjectionBuildCounts[kind], (before[kind] ?? 0) + 1)
        }
    }

    func testRejectedHistoryAndCorrectionWritesKeepCachedProjection() throws {
        let context = try makeContext()
        let now = minuteNow()
        let song = AppModelFixtures.track("durable", language: .english)
        record(song, in: context, at: now.addingTimeInterval(-120))
        let before = context.model.listeningLanguageProfile(now: now)
        let counts = context.model.listeningProjectionBuildCounts
        try context.withBlockedLibraryFile {
            XCTAssertFalse(context.library.recordListening(track: song, sessionID: UUID(), startedAt: now, seconds: 30))
            XCTAssertFalse(context.library.setRecordingLanguageOverride("ta", for: song.id))
            XCTAssertEqual(context.model.listeningLanguageProfile(now: now), before)
            XCTAssertEqual(context.model.listeningProjectionBuildCounts, counts)
        }
    }

    func testCorrectionsAndNudgesInvalidateOnlyTheirProjectionAndFallbackIsKeyed() throws {
        let context = try makeContext()
        let now = minuteNow()
        let song = AppModelFixtures.track("override", language: .english)
        record(song, in: context, at: now.addingTimeInterval(-120))
        _ = context.model.listeningLanguageProfile(now: now)
        _ = context.model.listeningGenreProfile(now: now)
        XCTAssertTrue(context.library.setRecordingLanguageOverride("ta", for: song.id))
        XCTAssertEqual(context.model.listeningLanguageProfile(now: now).orderedLanguages, [.tamil])
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.summary], 1)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.languageSummary], 2)
        context.model.setLanguageNudge(.more, for: .hindi)
        XCTAssertEqual(context.model.listeningLanguageProfile(now: now).nudges[.hindi], .more)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.languageSummary], 2)
        context.model.setGenreNudge(.less, for: .rock)
        XCTAssertEqual(context.model.listeningGenreProfile(now: now).nudges[.rock], .less)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.genreSummary], 1)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.summary], 1)

        XCTAssertTrue(context.library.setRecordingLanguageOverride(nil, for: song.id))
        XCTAssertEqual(context.model.listeningLanguageProfile(now: now).language(for: song), .english)
        context.library.clearHistory()
        context.model.resetLanguageNudges()
        XCTAssertEqual(context.model.listeningLanguageProfile(now: now).orderedLanguages, [.english])
        context.model.updatePreferences { $0.languages = [.hindi] }
        XCTAssertEqual(context.model.listeningLanguageProfile(now: now).orderedLanguages, [.hindi])
    }

    func testLanguageResultsRevisionChangesOnlyWithEvidenceAndResetForgetsCachedEvidence() async throws {
        let now = minuteNow()
        let service = ArtistSpotlightLanguageService(provider: AppModelLyricsProvider(), metadataLookup: { _ in
            .identified(.tamil, source: .musicBrainzWork(recordingID: ArtistSpotlightMusicBrainzFixtures.recordingID,
                                                      workID: ArtistSpotlightMusicBrainzFixtures.workID))
        })
        let discovery = ListeningLanguageDiscovery(service: service, now: { now })
        let context = try makeContext(discovery: discovery)
        var song = AppModelFixtures.track("evidence")
        song.language = nil
        record(song, in: context, at: now.addingTimeInterval(-120))
        XCTAssertFalse(context.model.listeningLanguageProfile(now: now).isLearned)
        XCTAssertEqual(discovery.resultsRevision, 0)
        discovery.refresh(events: context.library.events, overrides: [:], enabled: true, now: now)
        await discovery.waitForChecks()
        XCTAssertEqual(discovery.resultsRevision, 1)
        XCTAssertEqual(context.model.listeningLanguageProfile(now: now).language(for: song), .tamil)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.summary], 1)
        let counts = context.model.listeningProjectionBuildCounts
        discovery.refresh(events: context.library.events, overrides: [:], enabled: true, now: now)
        await discovery.waitForChecks()
        discovery.pause()
        XCTAssertEqual(discovery.resultsRevision, 1)
        _ = context.model.listeningLanguageProfile(now: now)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts, counts)
        discovery.reset()
        XCTAssertEqual(discovery.resultsRevision, 2)
        XCTAssertNil(context.model.listeningLanguageProfile(now: now).language(for: song))
        XCTAssertFalse(context.model.listeningLanguageProfile(now: now).isLearned)
        discovery.reset()
        XCTAssertEqual(discovery.resultsRevision, 2)
    }

    func testGenreEvidenceReplacementAndPrivacyClearInvalidateCachedResults() throws {
        let context = try makeContext()
        let now = minuteNow()
        let song = AppModelFixtures.track("genre")
        record(song, in: context, at: now.addingTimeInterval(-120))
        let key = LyricsRequestKey(song)
        context.model.genreEvidence.record(GenreFixtures.distribution([(.pop, 1)]), for: key)
        XCTAssertEqual(context.model.listeningGenreProfile(now: now).topFamily, .pop)
        context.model.genreEvidence.record(GenreFixtures.distribution([(.rock, 1)]), for: key)
        XCTAssertEqual(context.model.listeningGenreProfile(now: now).topFamily, .rock)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.summary], 1)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.genreSummary], 2)
        context.model.updatePreferences { $0.saveListeningHistory = false }
        XCTAssertEqual(context.model.listeningGenreProfile(now: now).topFamily, .rock, "History off preserves saved counts")
        context.library.clearHistory()
        XCTAssertFalse(context.model.listeningGenreProfile(now: now).isLearned)
        XCTAssertEqual(context.model.listeningGenreSummary(now: now).totalPlays, 0)
        XCTAssertEqual(context.model.listeningLanguageSummary(now: now).totalPlays, 0)
        XCTAssertTrue(context.model.genreEvidence.distributions.isEmpty)
    }

    func testMinuteRolloverExpiresRollingWindowWithoutHistoryWrite() throws {
        let context = try makeContext()
        let calendar = libraryTestCalendar()
        let now = minuteNow()
        let cutoff = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: now))
        let song = AppModelFixtures.track("boundary", language: .hindi)
        record(song, in: context, at: cutoff)
        context.model.genreEvidence.record(GenreFixtures.distribution([(.pop, 1)]), for: LyricsRequestKey(song))
        XCTAssertTrue(context.model.listeningLanguageProfile(now: now, calendar: calendar).isLearned)
        XCTAssertTrue(context.model.listeningGenreProfile(now: now, calendar: calendar).isLearned)
        let revision = context.library.historyRevision
        let later = now.addingTimeInterval(60)
        XCTAssertFalse(context.model.listeningLanguageProfile(now: later, calendar: calendar).isLearned)
        XCTAssertFalse(context.model.listeningGenreProfile(now: later, calendar: calendar).isLearned)
        XCTAssertEqual(context.library.historyRevision, revision)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.summary], 2)
    }

    func testMidnightTimeZoneAndCalendarChangesInvalidateWithoutExactDateKeys() throws {
        let context = try makeContext()
        let utc = libraryTestCalendar()
        let midnight = utc.startOfDay(for: Date())
        let before = midnight.addingTimeInterval(-30)
        record(AppModelFixtures.track("midnight"), in: context, at: before.addingTimeInterval(-60))
        let first = context.model.listeningSummary(now: before, calendar: utc)
        let after = context.model.listeningSummary(now: midnight.addingTimeInterval(30), calendar: utc)
        XCTAssertEqual(first.days.last?.date, midnight.addingTimeInterval(-86_400))
        XCTAssertEqual(after.days.last?.date, midnight)
        XCTAssertEqual(after.streak, 1)
        let india = libraryTestCalendar(timeZone: "Asia/Kolkata")
        let local = context.model.listeningSummary(now: midnight.addingTimeInterval(30), calendar: india)
        XCTAssertEqual(local.days.last?.date, india.startOfDay(for: midnight))
        XCTAssertNotEqual(local.days.last?.date, after.days.last?.date)
        var otherCalendar = Calendar(identifier: .buddhist)
        otherCalendar.timeZone = india.timeZone
        _ = context.model.listeningSummary(now: midnight.addingTimeInterval(30), calendar: otherCalendar)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.summary], 4)
    }

    func testMonthlyProjectionReuseDoesNotBorrowAllTimeLanguageScope() throws {
        let context = try makeContext()
        let now = minuteNow()
        record(AppModelFixtures.track("month", language: .hindi), in: context, at: now.addingTimeInterval(-120))
        record(AppModelFixtures.track("older", language: .english), in: context, at: now.addingTimeInterval(-40 * 86_400))
        let month = context.model.listeningSummary(for: .month, now: now)
        let monthlyLanguages = ListeningAnalytics.languageSummary(listening: month)
        XCTAssertEqual(context.model.listeningLanguageSummary(now: now), monthlyLanguages)
        XCTAssertEqual(monthlyLanguages.rows.map(\.language), [.hindi])
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.summary], 1)
        let allTime = ListeningAnalytics.allAvailableSummary(events: context.library.events, now: now)
        let sharedLanguages = ListeningAnalytics.languageSummary(listening: allTime)
        XCTAssertEqual(sharedLanguages.totalPlays, 2)
        XCTAssertEqual(Set(sharedLanguages.rows.map(\.language)), [.hindi, .english])
        XCTAssertEqual(context.model.listeningLanguageSummary(now: now).totalPlays, 1)
        XCTAssertEqual(context.model.listeningLanguageSummary(for: .year, now: now).totalPlays, 2)
        _ = context.model.listeningLanguageSummary(now: now)
        XCTAssertEqual(context.model.listeningProjectionBuildCounts[.summary], 2, "Windows must not evict one another")
    }

    func testCachePopulationIsObservationSilentAndRevisionStillObservedOnHit() throws {
        let context = try makeContext()
        let now = minuteNow()
        let song = AppModelFixtures.track("observed")
        record(song, in: context, at: now.addingTimeInterval(-120))
        let changes = CatalogTestRecorder<Bool>()
        withObservationTracking {
            _ = context.model.listeningLanguageProfile(now: now)
            _ = context.model.listeningGenreProfile(now: now)
        } onChange: { changes.record(true) }
        XCTAssertTrue(changes.values.isEmpty)
        withObservationTracking {
            _ = context.model.listeningLanguageProfile(now: now)
        } onChange: { changes.record(true) }
        XCTAssertTrue(changes.values.isEmpty)
        XCTAssertTrue(context.library.setRecordingLanguageOverride("ta", for: song.id))
        XCTAssertFalse(changes.values.isEmpty)
        XCTAssertEqual(context.model.listeningLanguageProfile(now: now).orderedLanguages, [.tamil])
    }

    private func makeContext(discovery: ListeningLanguageDiscovery? = nil) throws -> AppModelTestContext {
        let context = try AppModelTestContext(languageDiscovery: discovery)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }

    private func minuteNow() -> Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
    }

    private func record(_ track: Track, in context: AppModelTestContext, id: UUID = UUID(), at: Date, seconds: Double = 30) {
        XCTAssertTrue(context.library.recordListening(track: track, sessionID: id, startedAt: at, seconds: seconds))
        XCTAssertNil(context.library.errorMessage)
    }

    private func replaceSavedEvents(in context: AppModelTestContext, _ change: (inout [ListeningEvent]) -> Void) throws {
        let file = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let now = Date()
        var document = try LibraryPersistence.decode(Data(contentsOf: file), now: now)
        change(&document.events)
        // External replacements must carry receipts and a journal matching the edited events, including their metadata.
        document.lifetimeListening = LifetimeListeningRollup()
        for event in document.events { try document.lifetimeListening.include(event) }
        document.syncState = try LibrarySyncJournal.seed(document, now: now, writer: UUID())
        let replacement = try LibraryPersistence.encode(document)
        _ = try LibraryPersistence.decode(replacement, now: now)
        try replacement.write(to: file, options: .atomic)
        XCTAssertNotEqual(context.library.reloadFromDisk(), .failed)
        XCTAssertNil(context.library.errorMessage)
    }
}
