import XCTest
@testable import GanaBajana

@MainActor
final class RecapLifetimeTests: XCTestCase {
    func testLifetimeCardUsesDurableTotalButRetainedRankingsAndCoverage() {
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: LibrarySyncTestData.now, listenedSeconds: 60)
        let detail = ListeningAnalytics.allAvailableSummary(events: [event], now: LibrarySyncTestData.now)
        let lifetime = LifetimeListeningSummary(seconds: 600, plays: 8,
            coverageStartedAt: LibrarySyncTestData.now.addingTimeInterval(-700 * 86_400))
        let content = RecapShareCardContent(summary: detail, window: .week, now: LibrarySyncTestData.now,
            genres: ListeningGenreSummary(), languages: ListeningLanguageSummary(), allTime: true, lifetime: lifetime)
        XCTAssertEqual(content.totalValue, "10")
        XCTAssertEqual(content.periodTitle, "Lifetime Listening")
        XCTAssertEqual(content.songs.map(\.id), [event.track.id])
        XCTAssertEqual(content.coverageNote, RecapText.lifetimeDetailNote)
        XCTAssertTrue(RecapText.lifetimeCoverage(lifetime).contains("400 days"))
        let text = RecapText.share(summary: detail, window: .week, now: LibrarySyncTestData.now, allTime: true, lifetime: lifetime)
        XCTAssertTrue(text.contains("10 min listened"))
        XCTAssertTrue(text.contains("Retained-history details"))
    }

    func testExpiredDetailStillSharesLifetimeTotalWithoutInventingSongs() {
        let lifetime = LifetimeListeningSummary(seconds: 120, plays: 1, coverageStartedAt: LibrarySyncTestData.now)
        let content = RecapShareCardContent(summary: ListeningSummary(), window: .year, now: LibrarySyncTestData.now,
            genres: ListeningGenreSummary(), languages: ListeningLanguageSummary(), allTime: true, lifetime: lifetime)
        XCTAssertEqual(content.totalValue, "2")
        XCTAssertTrue(content.songs.isEmpty)
        XCTAssertTrue(content.artists.isEmpty)
        XCTAssertFalse(content.dateRange.contains("No saved listening"))
    }
}
