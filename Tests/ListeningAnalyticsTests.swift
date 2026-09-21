import XCTest
@testable import GanaBajana

final class ListeningAnalyticsTests: XCTestCase {
    private let calendar = libraryTestCalendar()

    func testRollingWindowIncludesExactBoundariesAndExcludesFutureAndOlderSessions() throws {
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let cutoff = calendar.date(byAdding: .day, value: -7, to: now)!
        let track = libraryTestTrack()
        let dates = [cutoff.addingTimeInterval(-0.001), cutoff, now, now.addingTimeInterval(0.001)]
        let events = dates.map { ListeningEvent(id: UUID(), track: track, startedAt: $0, listenedSeconds: 30) }
        let summary = ListeningAnalytics.summary(events: events, for: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.seconds, 60)
        XCTAssertEqual(summary.plays, 2)
        XCTAssertEqual(summary.days.count, 8)
        XCTAssertEqual(summary.days.reduce(0) { $0 + $1.seconds }, 60)
        XCTAssertEqual(summary.days.first?.date, calendar.startOfDay(for: cutoff))
        XCTAssertEqual(summary.days.last?.date, calendar.startOfDay(for: now))
    }

    func testWeekMonthAndYearUseSevenThirtyAnd365RollingDays() {
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let agesAndSeconds = [(6, 30.0), (20, 60.0), (200, 90.0), (366, 120.0)]
        let events = agesAndSeconds.map { age, seconds in
            ListeningEvent(
                id: UUID(), track: libraryTestTrack(),
                startedAt: calendar.date(byAdding: .day, value: -age, to: now)!, listenedSeconds: seconds
            )
        }
        XCTAssertEqual(ListeningAnalytics.summary(events: events, for: .week, now: now, calendar: calendar).seconds, 30)
        XCTAssertEqual(ListeningAnalytics.summary(events: events, for: .month, now: now, calendar: calendar).seconds, 90)
        XCTAssertEqual(ListeningAnalytics.summary(events: events, for: .year, now: now, calendar: calendar).seconds, 180)
    }

    func testQualificationUsesThirtySecondsOrHalfOfAShortSong() {
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let examples: [(TimeInterval?, TimeInterval)] = [
            (240, 29.999), (240, 30), (40, 19.999), (40, 20), (nil, 29.999), (nil, 30), (60, 30)
        ]
        let events = examples.enumerated().map { index, item in
            ListeningEvent(
                id: UUID(), track: libraryTestTrack("song-\(index)", duration: item.0),
                startedAt: now.addingTimeInterval(-3600), listenedSeconds: item.1
            )
        }
        let summary = ListeningAnalytics.summary(events: events, for: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.plays, 4)
        XCTAssertEqual(summary.uniqueTracks, 7)
        XCTAssertEqual(summary.seconds, examples.reduce(0) { $0 + $1.1 }, accuracy: 0.0001)
    }

    func testRankingsAggregateActualTimeAndCreditDistinctCollaboratorsWithoutInflatingTotal() {
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let first = Track(id: "a", title: "A", artists: ["Arijit Singh", "Shreya Ghoshal", "arijit singh"], duration: 240)
        let second = libraryTestTrack("b", artist: "Arijit Singh")
        let events = [
            ListeningEvent(id: UUID(), track: first, startedAt: now.addingTimeInterval(-60), listenedSeconds: 60),
            ListeningEvent(id: UUID(), track: first, startedAt: now.addingTimeInterval(-120), listenedSeconds: 15),
            ListeningEvent(id: UUID(), track: second, startedAt: now.addingTimeInterval(-180), listenedSeconds: 45)
        ]
        let summary = ListeningAnalytics.summary(events: events, for: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.seconds, 120)
        XCTAssertEqual(summary.plays, 2)
        XCTAssertEqual(summary.uniqueTracks, 2)
        XCTAssertEqual(summary.uniqueArtists, 2)
        XCTAssertEqual(summary.topTracks.map(\.id), ["a", "b"])
        XCTAssertEqual(summary.topTracks[0].seconds, 75)
        XCTAssertEqual(summary.topTracks[0].plays, 1)
        XCTAssertEqual(summary.topArtists.map(\.name), ["Arijit Singh", "Shreya Ghoshal"])
        XCTAssertEqual(summary.topArtists[0].seconds, 120)
        XCTAssertEqual(summary.topArtists[0].plays, 2)
        XCTAssertEqual(summary.topArtists[1].seconds, 75)
    }

    func testTimeTiesUsePlaysThenRecencyAndStableSongIdentity() {
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let datesAndIDs = [("old", -300.0), ("recent", -60.0), ("a", -10.0), ("b", -10.0)]
        let events = datesAndIDs.map { id, offset in
            ListeningEvent(id: UUID(), track: libraryTestTrack(id), startedAt: now.addingTimeInterval(offset), listenedSeconds: 30)
        }
        let summary = ListeningAnalytics.summary(events: events.reversed(), for: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.topTracks.map(\.id), ["a", "b", "recent", "old"])
    }

    func testCurrentStreakUsesAllHistoryAndAllowsTodayToStillBeEmpty() {
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let events = (1...12).map { day in
            ListeningEvent(
                id: UUID(), track: libraryTestTrack(),
                startedAt: calendar.date(byAdding: .day, value: -day, to: now)!, listenedSeconds: 10
            )
        }
        XCTAssertEqual(ListeningAnalytics.summary(events: events, for: .week, now: now, calendar: calendar).streak, 12)
        XCTAssertEqual(ListeningAnalytics.summary(events: events, for: .year, now: now, calendar: calendar).streak, 12)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertEqual(ListeningAnalytics.summary(events: events, for: .year, now: tomorrow, calendar: calendar).streak, 0)
    }

    func testLocalDayBarsAndStreakHandleDaylightSavingWithoutAssuming24HourDays() {
        let local = libraryTestCalendar(timeZone: "America/New_York")
        let now = libraryTestDate(2026, 3, 9, calendar: local)
        let dates = [7, 8, 9].map { libraryTestDate(2026, 3, $0, hour: 1, calendar: local) }
        let events = dates.map { ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: $0, listenedSeconds: 60) }
        let summary = ListeningAnalytics.summary(events: events, for: .week, now: now, calendar: local)
        XCTAssertEqual(summary.streak, 3)
        XCTAssertEqual(summary.days.filter { $0.seconds > 0 }.count, 3)
        XCTAssertEqual(summary.days.reduce(0) { $0 + $1.seconds }, 180)
        let march8 = local.startOfDay(for: libraryTestDate(2026, 3, 8, calendar: local))
        let march9 = local.startOfDay(for: now)
        XCTAssertEqual(march9.timeIntervalSince(march8), 23 * 3600)
        XCTAssertTrue(summary.days.contains { $0.date == march8 && $0.seconds == 60 })
        XCTAssertTrue(summary.days.contains { $0.date == march9 && $0.seconds == 60 })
    }

    func testInvalidEventsNeverContributeAndUnknownArtistsAreNotInvented() {
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let track = Track(id: "unknown", title: "A recording", artists: [])
        var events = [0.0, -1, .nan, .infinity, 1e300].map {
            ListeningEvent(id: UUID(), track: track, startedAt: now, listenedSeconds: $0)
        }
        events.append(ListeningEvent(id: UUID(), track: track, startedAt: Date(timeIntervalSince1970: .nan), listenedSeconds: 60))
        events.append(ListeningEvent(id: UUID(), track: track, startedAt: Date(timeIntervalSince1970: -1), listenedSeconds: 60))
        events.append(ListeningEvent(id: UUID(), track: track, startedAt: now, listenedSeconds: 5))
        let summary = ListeningAnalytics.summary(events: events, for: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.seconds, 5)
        XCTAssertEqual(summary.plays, 0)
        XCTAssertEqual(summary.uniqueTracks, 1)
        XCTAssertEqual(summary.uniqueArtists, 0)
        XCTAssertTrue(summary.topArtists.isEmpty)
    }

    func testEmptyHistoryProducesZeroFilledDaysWithoutInventedTracksOrPlays() {
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let summary = ListeningAnalytics.summary(events: [], for: .month, now: now, calendar: calendar)
        XCTAssertEqual(summary.seconds, 0)
        XCTAssertEqual(summary.plays, 0)
        XCTAssertEqual(summary.streak, 0)
        XCTAssertEqual(summary.days.count, 31)
        XCTAssertTrue(summary.days.allSatisfy { $0.seconds == 0 })
        XCTAssertTrue(summary.topTracks.isEmpty)
        XCTAssertTrue(summary.topArtists.isEmpty)
    }

    func testDuplicateSessionInputCannotDoubleCountAPlayOrItsTime() {
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: now, listenedSeconds: 60)
        let summary = ListeningAnalytics.summary(events: [event, event], for: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.seconds, 60)
        XCTAssertEqual(summary.plays, 1)
    }
}
