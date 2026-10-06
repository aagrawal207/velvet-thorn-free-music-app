import XCTest
@testable import GanaBajana

/// The compact recap chart groups the summary's per-day totals; every bucket set must add up to the same seconds.
final class RecapListeningBucketsTests: XCTestCase {
    private let calendar = libraryTestCalendar()

    func testWeekKeepsOneBucketPerLocalDayAndMarksToday() {
        let now = libraryTestDate(2026, 9, 26, calendar: calendar)
        let days = summaryDays(secondsByAge: [0: 120, 1: 60, 6: 30, 7: 15], window: .week, now: now)
        let buckets = RecapListeningBuckets.buckets(days: days, window: .week, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 8, "A rolling week spans eight partial or whole local days")
        XCTAssertEqual(buckets.map(\.seconds).reduce(0, +), 225)
        XCTAssertEqual(buckets.filter(\.isCurrent).count, 1)
        XCTAssertEqual(buckets.last?.isCurrent, true)
        XCTAssertEqual(buckets.last?.seconds, 120)
        XCTAssertEqual(buckets.first?.seconds, 15)
        XCTAssertEqual(buckets.map(\.start), buckets.map(\.start).sorted())
        XCTAssertEqual(buckets.last?.title, "Saturday, Sep 26")
        XCTAssertEqual(buckets.first?.title, "Saturday, Sep 19", "Both ends share a weekday, so the date disambiguates")
    }

    func testMonthUsesSevenDaySpansCountedBackFromTodaySoTheNewestIsWhole() {
        let now = libraryTestDate(2026, 9, 26, calendar: calendar)
        let days = summaryDays(secondsByAge: [0: 10, 6: 20, 7: 30, 13: 40, 14: 50, 29: 60, 30: 70], window: .month, now: now)
        let buckets = RecapListeningBuckets.buckets(days: days, window: .month, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 5, "31 local days fall into five spans: four whole weeks and a partial oldest one")
        // Oldest partial span (ages 28 to 30), then whole spans ending today: ages 21 to 27 hold no listening.
        XCTAssertEqual(buckets.map(\.seconds), [130, 0, 50, 70, 30])
        XCTAssertEqual(buckets.filter(\.isCurrent).count, 1)
        XCTAssertEqual(buckets.last?.isCurrent, true)
        XCTAssertEqual(buckets.last?.start, calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)))
        XCTAssertEqual(buckets.last?.title, "the week of Sep 20")
    }

    func testYearGroupsByCalendarMonthWithThePartialFirstMonthKept() {
        let now = libraryTestDate(2026, 9, 26, calendar: calendar)
        let days = summaryDays(secondsByAge: [0: 5, 30: 7, 364: 9, 365: 11], window: .year, now: now)
        let buckets = RecapListeningBuckets.buckets(days: days, window: .year, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 13, "366 local days touch thirteen calendar months")
        XCTAssertEqual(buckets.map(\.seconds).reduce(0, +), 32)
        XCTAssertEqual(buckets.first?.seconds, 20, "Both oldest days sit in September 2025")
        XCTAssertEqual(buckets.last?.seconds, 5)
        XCTAssertEqual(buckets.last?.isCurrent, true)
        XCTAssertEqual(buckets.last?.title, "September")
        XCTAssertEqual(buckets.filter(\.isCurrent).count, 1)
    }

    func testSummaryNamesThePeakSpanAndCountsActiveSpans() {
        let now = libraryTestDate(2026, 9, 26, calendar: calendar)
        let days = summaryDays(secondsByAge: [0: 120, 2: 600, 5: 45], window: .week, now: now)
        let buckets = RecapListeningBuckets.buckets(days: days, window: .week, now: now, calendar: calendar)
        XCTAssertEqual(RecapListeningBuckets.summary(of: buckets, window: .week),
                       "3 of 8 days with listening. Most on Thursday, Sep 24: 10 min")
        XCTAssertEqual(RecapListeningBuckets.summary(of: [], window: .month), "No listening in this period")
        XCTAssertEqual(RecapListeningBuckets.title(for: .month), "Listening by week, last 30 days")
    }

    func testComparisonCopyCoversUpDownSameMultiplesAndNoPreviousListening() {
        XCTAssertEqual(RecapText.comparison(current: 100, previous: 0, days: 7), "No listening in the previous 7 days")
        XCTAssertEqual(RecapText.comparison(current: 100, previous: 100, days: 7), "About the same as the previous 7 days")
        XCTAssertEqual(RecapText.comparison(current: 112, previous: 100, days: 7), "Up 12% from the previous 7 days")
        XCTAssertEqual(RecapText.comparison(current: 92, previous: 100, days: 30), "Down 8% from the previous 30 days")
        XCTAssertEqual(RecapText.comparison(current: 5359, previous: 1862, days: 7), "2.9 times as much as the previous 7 days")
        XCTAssertEqual(RecapText.comparison(current: 300, previous: 100, days: 7), "3 times as much as the previous 7 days")
    }

    private func summaryDays(secondsByAge: [Int: TimeInterval], window: ListeningWindow, now: Date) -> [ListeningDay] {
        let events = secondsByAge.map { age, seconds in
            ListeningEvent(id: UUID(), track: libraryTestTrack(),
                           startedAt: calendar.date(byAdding: .day, value: -age, to: now)!, listenedSeconds: seconds)
        }
        return ListeningAnalytics.summary(events: events, for: window, now: now, calendar: calendar).days
    }
}
