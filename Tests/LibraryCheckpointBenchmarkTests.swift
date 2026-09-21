import XCTest
@testable import GanaBajana

final class LibraryCheckpointBenchmarkTests: XCTestCase {
    @MainActor
    func testCheckpointsWithFiveYearsOfListeningPreserveTheRollingYear() async throws {
        try withLibraryTestDirectory { directory in
            let now = Date()
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let track = Track(
                id: "benchmark-song", title: "A song in a long-lived library", artists: ["An Artist"],
                albumTitle: "An Album", duration: 240,
                artworkURL: URL(string: "https://example.com/artwork.jpg")
            )
            var document = LibraryDocument()
            document.favorites = [track]
            document.playback = PlaybackSnapshot(queue: [track], originalQueue: [track])
            for age in 1...1825 where age % 7 != 0 {
                let morning = calendar.date(byAdding: .day, value: -age, to: today)!.addingTimeInterval(8 * 3600)
                for index in 0..<20 {
                    document.events.append(ListeningEvent(
                        id: UUID(), track: track, startedAt: morning.addingTimeInterval(Double(index * 300)),
                        listenedSeconds: 180
                    ))
                }
            }
            let expected = ListeningAnalytics.summary(events: document.events, for: .year, now: now)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(LibraryPersistence.encode(document), to: url, replacing: nil)
            let originalBytes = try Data(contentsOf: url).count
            let store = LibraryStore(directory: directory)
            XCTAssertNil(store.errorMessage)

            let start = ContinuousClock.now
            for position in 1...5 {
                store.updatePlayback(PlaybackSnapshot(queue: [track], position: Double(position), originalQueue: [track]))
                XCTAssertNil(store.errorMessage)
            }
            let elapsed = start.duration(to: .now).components
            let milliseconds = (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) / 5
            let savedBytes = try Data(contentsOf: url).count
            let actual = store.summary(for: .year, now: now)
            XCTAssertEqual(actual.seconds, expected.seconds)
            XCTAssertEqual(actual.plays, expected.plays)
            XCTAssertEqual(actual.streak, expected.streak)
            XCTAssertEqual(store.playback.position, 5)
            XCTAssertEqual(store.favorites, [track])
            print("Library checkpoint benchmark: \(document.events.count) → \(store.events.count) sessions; \(originalBytes) → \(savedBytes) bytes; \(milliseconds.formatted(.number.precision(.fractionLength(2)))) ms/checkpoint (5 writes).")
        }
    }
}
