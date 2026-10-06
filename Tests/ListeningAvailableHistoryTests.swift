import XCTest
@testable import GanaBajana

final class ListeningAvailableHistoryTests: XCTestCase {
    func testAllTimeIncludesSavedEventsBeyond365DaysAndHonorsRetentionBoundary() throws {
        let calendar = libraryTestCalendar(timeZone: "America/New_York")
        let now = libraryTestDate(2026, 9, 26, calendar: calendar)
        let cutoff = try XCTUnwrap(calendar.date(byAdding: .day, value: -400, to: calendar.startOfDay(for: now)))
        let old = try XCTUnwrap(calendar.date(byAdding: .day, value: -390, to: now))
        var document = LibraryDocument()
        document.events = [event(at: now, seconds: 60), event(at: old, seconds: 90),
                           event(at: cutoff, seconds: 30), event(at: cutoff.addingTimeInterval(-0.001), seconds: 120)]
        LibraryHistoryRetention.apply(to: &document, now: now, calendar: calendar)
        XCTAssertEqual(document.events.count, 3)
        let originalIDs = document.events.map(\.id)
        let summary = ListeningAnalytics.allAvailableSummary(events: document.events, now: now, calendar: calendar)
        XCTAssertEqual(summary.seconds, 180)
        XCTAssertEqual(summary.plays, 3)
        XCTAssertEqual(summary.days.first?.date, cutoff)
        XCTAssertEqual(ListeningAnalytics.summary(events: document.events, for: .year, now: now, calendar: calendar).seconds, 60)
        XCTAssertEqual(document.events.map(\.id), originalIDs, "Reading All Time must not rewrite saved history")
    }

    func testAllTimeKeepsOnlyValidUniqueSavedSessionsAndSparseDays() {
        let calendar = libraryTestCalendar(timeZone: "America/Los_Angeles")
        let now = libraryTestDate(2026, 3, 9, calendar: calendar)
        let old = event(at: libraryTestDate(2001, 1, 1, calendar: calendar), seconds: 60)
        let current = event(at: now, seconds: 30)
        let events = [old, old, current, event(at: now.addingTimeInterval(0.001), seconds: 120),
                      event(at: Date(timeIntervalSince1970: .nan), seconds: 60), event(at: now, seconds: .nan)]
        let summary = ListeningAnalytics.allAvailableSummary(events: events, now: now, calendar: calendar)
        XCTAssertEqual(summary.seconds, 90)
        XCTAssertEqual(summary.plays, 2)
        XCTAssertEqual(summary.days.count, 2, "A gap must not allocate thousands of empty days")
        XCTAssertEqual(summary.days.last?.date, calendar.startOfDay(for: now))
        XCTAssertTrue(ListeningAnalytics.allAvailableSummary(events: events, now: Date(timeIntervalSince1970: .nan)).days.isEmpty)
        XCTAssertTrue(ListeningAnalytics.allAvailableSummary(events: [], now: now).days.isEmpty)
    }

    func testOlderStreakSamplesCountOnlyTheSessionsStillSaved() {
        let calendar = libraryTestCalendar()
        let now = libraryTestDate(2026, 9, 26, calendar: calendar)
        var document = LibraryDocument()
        for age in 1...402 {
            let date = calendar.date(byAdding: .day, value: -age, to: now)!
            document.events.append(contentsOf: [event(at: date, seconds: 30), event(at: date, seconds: 30)])
        }
        LibraryHistoryRetention.apply(to: &document, now: now, calendar: calendar)
        let summary = ListeningAnalytics.allAvailableSummary(events: document.events, now: now, calendar: calendar)
        XCTAssertEqual(summary.streak, 402)
        XCTAssertEqual(summary.plays, 802, "Two older days retain only one actual session each")
        XCTAssertEqual(summary.seconds, 24_060, "Deleted sessions must not be reconstructed from the streak")
        XCTAssertEqual(RecapListeningBuckets.allAvailable(days: summary.days, now: now, calendar: calendar)
            .reduce(0) { $0 + $1.seconds }, 24_060)
    }

    func testAvailableHistoryBucketsAreBoundedAndConserveAllSecondsAcrossDecades() {
        let calendar = libraryTestCalendar(timeZone: "Pacific/Auckland")
        let now = libraryTestDate(2026, 9, 26, calendar: calendar)
        let days = (1971...2026).map { year in
            ListeningDay(date: libraryTestDate(year, 1, 1, calendar: calendar), seconds: 60)
        }
        let buckets = RecapListeningBuckets.allAvailable(days: days, now: now, calendar: calendar)
        XCTAssertLessThanOrEqual(buckets.count, 24)
        XCTAssertEqual(buckets.count, 19, "56 years use three-year spans")
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.seconds }, 56 * 60)
        XCTAssertEqual(buckets.filter(\.isCurrent).count, 1)
        XCTAssertEqual(buckets.first?.start, calendar.dateInterval(of: .year, for: days[0].date)?.start)
        XCTAssertEqual(buckets.map(\.start), buckets.map(\.start).sorted())
    }

    func testAvailableHistoryMonthsUseLocalCalendarBoundariesAndKeepEmptyGaps() {
        let calendar = libraryTestCalendar(timeZone: "America/Los_Angeles")
        let march = libraryTestDate(2026, 3, 1, hour: 0, calendar: calendar)
        let now = libraryTestDate(2026, 4, 2, calendar: calendar)
        let days = [ListeningDay(date: march.addingTimeInterval(-1), seconds: 60),
                    ListeningDay(date: march, seconds: 120)]
        let buckets = RecapListeningBuckets.allAvailable(days: days, now: now, calendar: calendar)
        XCTAssertEqual(buckets.map(\.seconds), [60, 120, 0])
        XCTAssertEqual(buckets.map(\.title), ["February 2026", "March 2026", "April 2026"])
        XCTAssertEqual(buckets.last?.isCurrent, true)
    }

    func testAllTimeGenreAndLanguageProjectionsUseTheSameQualifiedPlaysAndCorrections() {
        let calendar = libraryTestCalendar()
        let now = libraryTestDate(2026, 9, 26, calendar: calendar)
        let track = libraryTestTrack("classified")
        let old = ListeningEvent(id: UUID(), track: track,
            startedAt: calendar.date(byAdding: .day, value: -390, to: now)!, listenedSeconds: 60)
        let events = [old, event(at: now, seconds: 30), event(at: now, seconds: 1)]
        let summary = ListeningAnalytics.allAvailableSummary(events: events, now: now, calendar: calendar)
        let languages = ListeningAnalytics.languageSummary(listening: summary, overrides: [track.id: "te"])
        XCTAssertEqual(languages.totalPlays, 2)
        XCTAssertEqual(languages.rows.first?.language, .telugu)
        XCTAssertEqual(languages.rows.first?.plays, 1)
        XCTAssertEqual(languages.unclassifiedPlays, 1)
        let genres = ListeningAnalytics.genreSummary(listening: summary,
            evidence: [LyricsRequestKey(track): GenreFixtures.distribution([(.pop, 1)])])
        XCTAssertEqual(genres.totalPlays, 2)
        XCTAssertEqual(genres.classifiedPlays, 1)
        XCTAssertEqual(genres.coverage, 0.5)
        XCTAssertEqual(genres.rows.first?.share, 1)
        let rolling = ListeningAnalytics.summary(events: events, for: .month, now: now, calendar: calendar)
        XCTAssertEqual(ListeningAnalytics.languageSummary(events: events, for: .month, now: now, calendar: calendar),
                       ListeningAnalytics.languageSummary(listening: rolling))
    }

    func testAllTimeCardAndShareCopyStateCoverageAndUseSingularUnits() {
        let calendar = libraryTestCalendar()
        let now = libraryTestDate(2026, 9, 26, calendar: calendar)
        let old = calendar.date(byAdding: .day, value: -390, to: now)!
        let summary = ListeningAnalytics.allAvailableSummary(events: [event(at: old, seconds: 60)], now: now, calendar: calendar)
        let content = RecapShareCardContent(summary: summary, window: .year, now: now,
            genres: .init(), languages: .init(), allTime: true)
        XCTAssertEqual(content.periodTitle, "All available history")
        XCTAssertEqual(content.totalUnit, "minute listened")
        XCTAssertEqual(content.coverageNote, RecapText.savedHistoryNote)
        XCTAssertTrue(content.dateRange.contains("2025"), "The start date includes the saved event older than a year")
        let text = RecapText.share(summary: summary, window: .year, now: now, allTime: true)
        XCTAssertTrue(text.contains("All Time · All available history"))
        XCTAssertTrue(text.contains("1 play · 1 song · 1 artist"))
        XCTAssertTrue(text.contains(RecapText.savedHistoryNote))
        XCTAssertFalse(text.contains("365"))
        XCTAssertEqual(RecapText.totalUnit(1), "second listened")
        XCTAssertEqual(RecapText.totalUnit(2), "seconds listened")
        XCTAssertEqual(RecapText.totalUnit(120), "minutes listened")
        XCTAssertEqual(RecapText.dateRange(window: .year, now: now, allTime: true), "No saved listening")
        XCTAssertEqual(ListeningWindow.allCases.map(\.rawValue), ["week", "month", "year"], "Shared rolling-window API stays compatible")
    }

    private func event(at date: Date, seconds: TimeInterval) -> ListeningEvent {
        ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: date, listenedSeconds: seconds)
    }
}
