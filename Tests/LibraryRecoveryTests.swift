import XCTest
@testable import GanaBajana

@MainActor
final class LibraryRecoveryTests: XCTestCase {
    func testSameStoreReloadPreservesExternalFavoritesAndRetriesTheOriginalBufferedFifteenSeconds() throws {
        try withLibraryTestDirectory { directory in
            let time = RecommendationFixtures.now
            let library = LibraryStore(directory: directory, now: { time })
            let song = libraryTestTrack()
            let favorite = libraryTestTrack("external-favorite")
            let session = UUID()
            XCTAssertTrue(library.recordListening(track: song, sessionID: session, startedAt: time, seconds: 20))
            library.updatePlayback(PlaybackSnapshot(queue: [song], position: 20))
            let external = LibraryStore(directory: directory, now: { time })
            external.toggleFavorite(favorite)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let externalBytes = try Data(contentsOf: url)
            var buffer = PlaybackListeningBuffer()
            let checkpoint = ListeningEvent(id: session, track: song, startedAt: time, listenedSeconds: 15)
            XCTAssertTrue(buffer.append(checkpoint))
            var privacyResets = 0
            library.onHistoryCleared = { privacyResets += 1; buffer.discard() }

            XCTAssertFalse(library.recordListening(track: song, sessionID: session, startedAt: time, seconds: 15))
            XCTAssertTrue(library.requiresReload)
            XCTAssertEqual(library.events.first?.listenedSeconds, 20)
            XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            XCTAssertFalse(library.requiresReload)
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(privacyResets, 0)
            XCTAssertEqual(try Data(contentsOf: url), externalBytes, "Recovery itself only adopts validated bytes")
            XCTAssertEqual(library.favorites, [favorite])
            XCTAssertEqual(library.playback.queue, [song])
            XCTAssertEqual(library.playback.position, 20)
            let retry = try XCTUnwrap(buffer.checkpoints.first)
            XCTAssertEqual(retry.id, session)
            XCTAssertEqual(retry.startedAt, time)
            XCTAssertEqual(retry.track, song)
            XCTAssertEqual(retry.listenedSeconds, 15)
            XCTAssertTrue(library.recordListening(track: retry.track, sessionID: retry.id,
                                                  startedAt: retry.startedAt, seconds: retry.listenedSeconds))
            buffer.acknowledge(retry)
            XCTAssertTrue(buffer.checkpoints.isEmpty)
            let restored = LibraryStore(directory: directory, now: { time })
            XCTAssertEqual(restored.events.count, 1)
            XCTAssertEqual(restored.events.first?.id, session)
            XCTAssertEqual(restored.events.first?.startedAt, time)
            XCTAssertEqual(restored.events.first?.listenedSeconds, 35)
            XCTAssertEqual(restored.favorites, [favorite])
        }
    }

    func testCorruptFutureAndUnsupportedRecoveryPreserveTheFileStateAndBacklogUntilRepair() throws {
        let invalidFiles = [
            Data("{broken library".utf8),
            Data("{\"version\":9999,\"future\":\"keep\"}".utf8),
            Data("{\"version\":0}".utf8),
        ]
        for invalid in invalidFiles {
            try withLibraryTestDirectory { directory in
                let time = RecommendationFixtures.now
                let library = LibraryStore(directory: directory, now: { time })
                let song = libraryTestTrack()
                let session = UUID()
                library.toggleFavorite(song)
                XCTAssertTrue(library.recordListening(track: song, sessionID: session, startedAt: time, seconds: 20))
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                let original = try Data(contentsOf: url)
                var buffer = PlaybackListeningBuffer()
                XCTAssertTrue(buffer.append(ListeningEvent(id: session, track: song, startedAt: time, listenedSeconds: 15)))
                var privacyResets = 0
                library.onHistoryCleared = { privacyResets += 1; buffer.discard() }
                try invalid.write(to: url, options: .atomic)

                XCTAssertFalse(library.recordListening(track: song, sessionID: session, startedAt: time, seconds: 15))
                XCTAssertEqual(library.reloadFromDisk(), .failed)
                XCTAssertTrue(library.requiresReload)
                XCTAssertNotNil(library.errorMessage)
                XCTAssertEqual(library.favorites, [song])
                XCTAssertEqual(library.events.first?.listenedSeconds, 20)
                XCTAssertEqual(buffer.checkpoints.first?.id, session)
                XCTAssertEqual(buffer.checkpoints.first?.listenedSeconds, 15)
                XCTAssertEqual(privacyResets, 0)
                library.preferences.appearance = .light
                XCTAssertFalse(library.recordTip(transactionID: 1, credited: true))
                XCTAssertEqual(try Data(contentsOf: url), invalid)

                try original.write(to: url, options: .atomic)
                XCTAssertEqual(library.reloadFromDisk(), .reloaded)
                let retry = try XCTUnwrap(buffer.checkpoints.first)
                XCTAssertTrue(library.recordListening(track: retry.track, sessionID: retry.id,
                                                      startedAt: retry.startedAt, seconds: retry.listenedSeconds))
                buffer.acknowledge(retry)
                XCTAssertTrue(buffer.checkpoints.isEmpty)
                XCTAssertEqual(LibraryStore(directory: directory, now: { time }).events.first?.listenedSeconds, 35)
            }
        }
    }

    func testMissingFileCannotBeRecoveredAsAnEmptyLibraryOrOverwritten() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let song = libraryTestTrack()
            library.toggleFavorite(song)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let bytes = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(library.reloadFromDisk(), .failed)
            XCTAssertTrue(library.requiresReload)
            XCTAssertEqual(library.favorites, [song])
            XCTAssertFalse(library.recordTip(transactionID: 1, credited: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            try bytes.write(to: url, options: .atomic)
            XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
        }
    }

    func testExternalClearRetiresPendingListeningEvenWhenTheSavedHistoryWasEmpty() throws {
        for hadSavedHistory in [false, true] {
            try withLibraryTestDirectory { directory in
                let time = RecommendationFixtures.now
                let library = LibraryStore(directory: directory, now: { time })
                let song = libraryTestTrack()
                let session = UUID()
                library.toggleFavorite(song)
                if hadSavedHistory {
                    XCTAssertTrue(library.recordListening(track: song, sessionID: session, startedAt: time, seconds: 20))
                }
                var buffer = PlaybackListeningBuffer()
                XCTAssertTrue(buffer.append(ListeningEvent(id: session, track: song, startedAt: time, listenedSeconds: 15)))
                var resets = 0
                library.onHistoryCleared = { resets += 1; buffer.discard() }
                let external = LibraryStore(directory: directory, now: { time })
                external.clearHistory()
                XCTAssertNil(external.errorMessage)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                let clearedBytes = try Data(contentsOf: url)

                XCTAssertFalse(library.recordListening(track: song, sessionID: session, startedAt: time, seconds: 15))
                XCTAssertEqual(library.reloadFromDisk(), .historyBoundary)
                XCTAssertEqual(resets, 1)
                XCTAssertTrue(buffer.checkpoints.isEmpty)
                XCTAssertTrue(library.events.isEmpty)
                XCTAssertEqual(library.favorites, [song])
                XCTAssertEqual(try Data(contentsOf: url), clearedBytes)
                XCTAssertEqual(library.reloadFromDisk(), .reloaded)
                XCTAssertEqual(resets, 1)
                let fresh = UUID()
                XCTAssertTrue(library.recordListening(track: song, sessionID: fresh, startedAt: time, seconds: 3))
                let restored = LibraryStore(directory: directory, now: { time })
                XCTAssertEqual(restored.events.map(\.id), [fresh])
                XCTAssertEqual(restored.events.first?.listenedSeconds, 3)
            }
        }
    }

    func testExternalDisableAndReenableIsAPrivacyBoundaryDespiteAnUnchangedHistoryAndClockRollback() throws {
        for reenable in [false, true] {
            try withLibraryTestDirectory { directory in
                let clock = RecommendationTestClock()
                let time = clock.now
                let library = LibraryStore(directory: directory, now: { clock.now })
                let song = libraryTestTrack()
                let session = UUID()
                XCTAssertTrue(library.recordListening(track: song, sessionID: session, startedAt: time, seconds: 20))
                var buffer = PlaybackListeningBuffer()
                XCTAssertTrue(buffer.append(ListeningEvent(id: session, track: song, startedAt: time, listenedSeconds: 15)))
                var resets = 0
                library.onHistoryCleared = { resets += 1; buffer.discard() }
                clock.advance(by: -60)
                let external = LibraryStore(directory: directory, now: { clock.now })
                external.preferences.saveListeningHistory = false
                if reenable { external.preferences.saveListeningHistory = true }
                XCTAssertNil(external.errorMessage)

                XCTAssertFalse(library.recordListening(track: song, sessionID: session, startedAt: time, seconds: 15))
                XCTAssertEqual(library.reloadFromDisk(), .historyBoundary)
                XCTAssertEqual(resets, 1)
                XCTAssertTrue(buffer.checkpoints.isEmpty)
                XCTAssertEqual(library.preferences.saveListeningHistory, reenable)
                XCTAssertEqual(library.events.first?.listenedSeconds, 20)
                library.preferences.saveListeningHistory = true
                let fresh = UUID()
                XCTAssertTrue(library.recordListening(track: song, sessionID: fresh, startedAt: clock.now, seconds: 3))
                let restored = LibraryStore(directory: directory, now: { clock.now })
                XCTAssertEqual(restored.events.first { $0.id == session }?.listenedSeconds, 20)
                XCTAssertEqual(restored.events.first { $0.id == fresh }?.listenedSeconds, 3)
                XCTAssertEqual(restored.events.count, 2)
            }
        }
    }

    func testExternalEnableDoesNotReplayTimeAccumulatedWhileHistoryWasDisabled() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.preferences.saveListeningHistory = false
            var buffer = PlaybackListeningBuffer()
            XCTAssertTrue(buffer.append(ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: Date(), listenedSeconds: 15)))
            var resets = 0
            library.onHistoryCleared = { resets += 1; buffer.discard() }
            let external = LibraryStore(directory: directory)
            external.preferences.saveListeningHistory = true
            XCTAssertNil(external.errorMessage)

            XCTAssertEqual(library.reloadFromDisk(), .historyBoundary)
            XCTAssertEqual(resets, 1)
            XCTAssertTrue(buffer.checkpoints.isEmpty)
            XCTAssertTrue(library.preferences.saveListeningHistory)
            XCTAssertTrue(library.events.isEmpty)
        }
    }

    func testLegacyHistoryRemovalWithoutAnEpochStillRetiresBufferedTime() throws {
        try withLibraryTestDirectory { directory in
            let time = RecommendationFixtures.now
            let library = LibraryStore(directory: directory, now: { time })
            let song = libraryTestTrack()
            XCTAssertTrue(library.recordListening(track: song, sessionID: UUID(), startedAt: time, seconds: 20))
            library.recordRecent(track: song, position: 20)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["version"] = 1
            json.removeValue(forKey: "lifetimeListening")
            json.removeValue(forKey: "superLikedIDs")
            json.removeValue(forKey: "syncState")
            json.removeValue(forKey: "listeningHistoryEpoch")
            json["events"] = []
            json["recentlyPlayed"] = []
            let cleared = try JSONSerialization.data(withJSONObject: json)
            try cleared.write(to: url, options: .atomic)
            var reset = false
            library.onHistoryCleared = { reset = true }
            XCTAssertEqual(library.reloadFromDisk(), .historyBoundary)
            XCTAssertTrue(reset)
            XCTAssertTrue(library.events.isEmpty)
            XCTAssertTrue(library.recentlyPlayed.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), cleared)
        }
    }

    func testExternalRetentionDoesNotRetireUnrelatedCurrentBufferedListening() throws {
        try withLibraryTestDirectory { directory in
            let clock = RecommendationTestClock()
            let library = LibraryStore(directory: directory, now: { clock.now })
            let song = libraryTestTrack()
            XCTAssertTrue(library.recordListening(track: song, sessionID: UUID(), startedAt: clock.now, seconds: 20))
            clock.advance(by: Double(LibraryHistoryRetention.days + 1) * 86_400)
            let external = LibraryStore(directory: directory, now: { clock.now })
            XCTAssertNil(external.errorMessage)
            XCTAssertTrue(external.events.isEmpty)
            var buffer = PlaybackListeningBuffer()
            let checkpoint = ListeningEvent(id: UUID(), track: song, startedAt: clock.now, listenedSeconds: 15)
            XCTAssertTrue(buffer.append(checkpoint))
            var resets = 0
            library.onHistoryCleared = { resets += 1; buffer.discard() }

            XCTAssertFalse(library.recordListening(track: song, sessionID: checkpoint.id, startedAt: checkpoint.startedAt, seconds: 15))
            XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            XCTAssertEqual(resets, 0)
            XCTAssertEqual(buffer.checkpoints.first?.id, checkpoint.id)
            XCTAssertTrue(library.recordListening(track: song, sessionID: checkpoint.id, startedAt: checkpoint.startedAt, seconds: 15))
            buffer.acknowledge(checkpoint)
            XCTAssertTrue(buffer.checkpoints.isEmpty)
            XCTAssertEqual(LibraryStore(directory: directory, now: { clock.now }).events.map(\.id), [checkpoint.id])
        }
    }

    func testMalformedPrivacyEpochRefusesRecoveryAndKeepsTheLastValidSnapshot() throws {
        for value in ["not-a-uuid", 1, ["epoch": "bad"]] as [Any] {
            try withLibraryTestDirectory { directory in
                let library = LibraryStore(directory: directory)
                let song = libraryTestTrack()
                library.toggleFavorite(song)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                json["listeningHistoryEpoch"] = value
                let malformed = try JSONSerialization.data(withJSONObject: json)
                try malformed.write(to: url, options: .atomic)
                XCTAssertEqual(library.reloadFromDisk(), .failed)
                XCTAssertTrue(library.requiresReload)
                XCTAssertEqual(library.favorites, [song])
                XCTAssertFalse(library.recordTip(transactionID: 1, credited: true))
                XCTAssertEqual(try Data(contentsOf: url), malformed)
            }
        }
    }
}
