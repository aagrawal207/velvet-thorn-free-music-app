import XCTest
@testable import GanaBajana

final class LibraryRetentionTests: XCTestCase {
    func testRetentionKeeps400FullLocalDaysAndPreservesEveryRecapWindowAndSavedLibrary() throws {
        let calendar = libraryTestCalendar(timeZone: "America/New_York")
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let cutoff = calendar.date(byAdding: .day, value: -400, to: calendar.startOfDay(for: now))!
        let yearStart = calendar.date(byAdding: .day, value: -365, to: now)!
        let first = libraryTestTrack("a")
        let second = libraryTestTrack("b", artist: "Another Artist")
        let oldDate = calendar.date(byAdding: .day, value: -700, to: now)!
        var document = LibraryDocument()
        document.favorites = [second, first]
        document.playlists = [UserPlaylist(name: "Keep this old playlist", tracks: [second, first], createdAt: oldDate, updatedAt: oldDate)]
        document.playback = PlaybackSnapshot(queue: [second, first], position: 17.5, shuffleEnabled: true, originalQueue: [first, second])
        document.preferences.useEncryptedDNS = false
        document.lyricsOffsets = [first.id: -1.25, second.id: 0.5]
        let retainedDates = [now.addingTimeInterval(-60), now.addingTimeInterval(-20 * 86_400), yearStart, yearStart.addingTimeInterval(-0.001), cutoff]
        document.events = (retainedDates + [cutoff.addingTimeInterval(-0.001), oldDate]).enumerated().map { index, date in
            ListeningEvent(id: UUID(), track: index.isMultiple(of: 2) ? first : second, startedAt: date, listenedSeconds: Double(20 + index * 10))
        }
        document.recentlyPlayed = [
            RecentListen(track: first, playedAt: cutoff, position: 4.25),
            RecentListen(track: second, playedAt: cutoff.addingTimeInterval(-0.001), position: 12.75)
        ]
        let original = document
        try LibraryValidation.validate(document, now: now)
        XCTAssertTrue(LibraryHistoryRetention.apply(to: &document, now: now, calendar: calendar))
        XCTAssertEqual(document.events.map(\.id), Array(original.events.prefix(5)).map(\.id))
        XCTAssertEqual(document.recentlyPlayed.map(\.id), [first.id])
        XCTAssertEqual(document.recentlyPlayed.first?.position, 4.25)
        XCTAssertEqual(document.favorites, original.favorites)
        XCTAssertEqual(document.playlists, original.playlists)
        XCTAssertEqual(document.playback.queue, original.playback.queue)
        XCTAssertEqual(document.playback.originalQueue, original.playback.originalQueue)
        XCTAssertEqual(document.playback.position, original.playback.position)
        XCTAssertEqual(document.preferences, original.preferences)
        XCTAssertEqual(document.lyricsOffsets, original.lyricsOffsets)

        for window in ListeningWindow.allCases {
            let before = ListeningAnalytics.summary(events: original.events, for: window, now: now, calendar: calendar)
            let after = ListeningAnalytics.summary(events: document.events, for: window, now: now, calendar: calendar)
            XCTAssertEqual(after.seconds, before.seconds)
            XCTAssertEqual(after.plays, before.plays)
            XCTAssertEqual(after.uniqueTracks, before.uniqueTracks)
            XCTAssertEqual(after.uniqueArtists, before.uniqueArtists)
            XCTAssertEqual(after.topTracks.map(\.track), before.topTracks.map(\.track))
            XCTAssertEqual(after.topTracks.map(\.seconds), before.topTracks.map(\.seconds))
            XCTAssertEqual(after.topTracks.map(\.plays), before.topTracks.map(\.plays))
            XCTAssertEqual(after.topArtists.map(\.name), before.topArtists.map(\.name))
            XCTAssertEqual(after.topArtists.map(\.seconds), before.topArtists.map(\.seconds))
            XCTAssertEqual(after.topArtists.map(\.plays), before.topArtists.map(\.plays))
            XCTAssertEqual(after.days.map(\.date), before.days.map(\.date))
            XCTAssertEqual(after.days.map(\.seconds), before.days.map(\.seconds))
            XCTAssertEqual(after.streak, before.streak)
        }
        XCTAssertFalse(LibraryHistoryRetention.apply(to: &document, now: now, calendar: calendar))
    }

    func testLongCurrentStreakKeepsOneActualOlderSessionPerDayAndExpiresAfterABreak() {
        let calendar = libraryTestCalendar()
        let now = libraryTestDate(2026, 9, 19, calendar: calendar)
        let track = libraryTestTrack()
        var document = LibraryDocument()
        for age in 1...450 {
            let date = calendar.date(byAdding: .day, value: -age, to: now)!
            for seconds in [30.0, 45.0] {
                document.events.append(ListeningEvent(id: UUID(), track: track, startedAt: date, listenedSeconds: seconds))
            }
        }
        let originalIDs = Set(document.events.map(\.id))
        XCTAssertEqual(ListeningAnalytics.summary(events: document.events, for: .week, now: now, calendar: calendar).streak, 450)
        LibraryHistoryRetention.apply(to: &document, now: now, calendar: calendar)
        XCTAssertEqual(document.events.count, 850)
        XCTAssertTrue(document.events.allSatisfy { originalIDs.contains($0.id) })
        XCTAssertEqual(ListeningAnalytics.summary(events: document.events, for: .week, now: now, calendar: calendar).streak, 450)
        let cutoff = calendar.date(byAdding: .day, value: -400, to: calendar.startOfDay(for: now))!
        let older = document.events.filter { $0.startedAt < cutoff }
        XCTAssertEqual(older.count, 50)
        XCTAssertEqual(Set(older.map { calendar.startOfDay(for: $0.startedAt) }).count, 50)
        let later = calendar.date(byAdding: .day, value: 2, to: now)!
        LibraryHistoryRetention.apply(to: &document, now: later, calendar: calendar)
        let laterCutoff = calendar.date(byAdding: .day, value: -400, to: calendar.startOfDay(for: later))!
        XCTAssertTrue(document.events.allSatisfy { $0.startedAt >= laterCutoff })
        XCTAssertEqual(ListeningAnalytics.summary(events: document.events, for: .week, now: later, calendar: calendar).streak, 0)
    }

    @MainActor
    func testValidatedLoadAndSubsequentCommitsCompactExpiredHistoryWithoutDroppingSavedSongs() async throws {
        try withLibraryTestDirectory { directory in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let track = libraryTestTrack()
            let old = Calendar.current.date(byAdding: .day, value: -700, to: now)!
            var document = LibraryDocument()
            document.favorites = [track]
            document.playlists = [UserPlaylist(name: "An old favorite", tracks: [track], createdAt: old, updatedAt: old)]
            document.lyricsOffsets = [track.id: -0.125]
            document.preferences.saveListeningHistory = false
            document.preferences.useEncryptedDNS = false
            document.playback = PlaybackSnapshot(queue: [track, track], position: 12.75, shuffleEnabled: true, originalQueue: [track, track])
            document.events = [
                ListeningEvent(id: UUID(), track: track, startedAt: now.addingTimeInterval(-60), listenedSeconds: 45),
                ListeningEvent(id: UUID(), track: track, startedAt: old, listenedSeconds: 60)
            ]
            document.recentlyPlayed = [RecentListen(track: track, playedAt: old, position: 12.75)]
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let originalData = try LibraryPersistence.encode(document)
            try LibraryPersistence.write(originalData, to: url, replacing: nil)

            let store = LibraryStore(directory: directory)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.events.count, 1)
            XCTAssertTrue(store.recentlyPlayed.isEmpty)
            XCTAssertEqual(store.favorites, document.favorites)
            XCTAssertEqual(store.playlists, document.playlists)
            XCTAssertEqual(store.preferences, document.preferences)
            XCTAssertEqual(store.lyricsOffset(for: track.id), -0.125)
            XCTAssertEqual(store.playback.originalQueue, document.playback.originalQueue)
            XCTAssertEqual(store.playback.position, 12.75)
            XCTAssertLessThan(try Data(contentsOf: url).count, originalData.count)
            XCTAssertEqual(LibraryStore(directory: directory).events.count, 1)

            store.preferences.saveListeningHistory = true
            store.recordListening(track: track, sessionID: UUID(), startedAt: old, seconds: 30)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.events.count, 1)
            XCTAssertEqual(LibraryStore(directory: directory).events.count, 1)
        }
    }

    @MainActor
    func testInvalidExpiredRecordsAreNotSilentlyRemovedDuringLoad() async throws {
        try withLibraryTestDirectory { directory in
            var document = LibraryDocument()
            document.favorites = [libraryTestTrack()]
            document.events = [ListeningEvent(
                id: UUID(), track: libraryTestTrack(),
                startedAt: Date().addingTimeInterval(-700 * 86_400), listenedSeconds: -1
            )]
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let original = try LibraryPersistence.encode(document)
            try LibraryPersistence.write(original, to: url, replacing: nil)
            let store = LibraryStore(directory: directory)
            XCTAssertNotNil(store.errorMessage)
            store.clearHistory()
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    @MainActor
    func testFailedCompactionPreservesLoadedStateAndExposesErrorUntilASaveSucceeds() async throws {
        try withLibraryTestDirectory { directory in
            let track = libraryTestTrack()
            var document = LibraryDocument()
            document.favorites = [track]
            document.events = [ListeningEvent(
                id: UUID(), track: track, startedAt: Date().addingTimeInterval(-700 * 86_400), listenedSeconds: 45
            )]
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let original = try LibraryPersistence.encode(document)
            try LibraryPersistence.write(original, to: url, replacing: nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
            guard !FileManager.default.isWritableFile(atPath: directory.path) else {
                throw XCTSkip("This test requires a user whose directory write permissions can be restricted.")
            }

            let store = LibraryStore(directory: directory)
            XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("couldn’t save"))
            XCTAssertEqual(store.events.count, 1)
            XCTAssertEqual(store.favorites, [track])
            XCTAssertEqual(try Data(contentsOf: url), original)
            store.updatePlayback(store.playback)
            XCTAssertNotNil(store.errorMessage)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            store.updatePlayback(PlaybackSnapshot(queue: [track], position: 1, originalQueue: [track]))
            XCTAssertNil(store.errorMessage)
            XCTAssertTrue(store.events.isEmpty)
            XCTAssertEqual(LibraryStore(directory: directory).favorites, [track])
        }
    }
}
