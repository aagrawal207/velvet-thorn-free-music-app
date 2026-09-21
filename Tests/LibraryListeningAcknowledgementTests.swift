import XCTest
@testable import GanaBajana

@MainActor
final class LibraryListeningAcknowledgementTests: XCTestCase {
    func testFailedNewSessionWriteReturnsFalseAndRetryPersistsTheDeltaOnce() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let song = libraryTestTrack()
            let session = UUID()
            let start = Date().addingTimeInterval(-60)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            XCTAssertFalse(store.recordListening(track: song, sessionID: session, startedAt: start, seconds: 12.5))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.events.isEmpty)

            try FileManager.default.removeItem(at: url)
            XCTAssertTrue(store.recordListening(track: song, sessionID: session, startedAt: start, seconds: 12.5))
            XCTAssertNil(store.errorMessage)
            let reopened = LibraryStore(directory: directory)
            XCTAssertEqual(reopened.events.count, 1)
            XCTAssertEqual(reopened.events.first?.id, session)
            XCTAssertEqual(reopened.events.first?.listenedSeconds, 12.5)
        }
    }

    func testFailedExistingCheckpointKeepsTheSavedTotalAndCanRetryWithoutLosingTime() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let song = libraryTestTrack()
            let session = UUID()
            let start = Date().addingTimeInterval(-60)
            XCTAssertTrue(store.recordListening(track: song, sessionID: session, startedAt: start, seconds: 20))
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            let backup = directory.appendingPathComponent("saved-library.json")
            try FileManager.default.moveItem(at: url, to: backup)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertFalse(store.recordListening(track: song, sessionID: session, startedAt: start, seconds: 15))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.events.first?.listenedSeconds, 20)
            XCTAssertEqual(try Data(contentsOf: backup), saved)

            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: backup, to: url)
            XCTAssertTrue(store.recordListening(track: song, sessionID: session, startedAt: start, seconds: 15))
            XCTAssertNil(store.errorMessage)
            let reopened = LibraryStore(directory: directory)
            XCTAssertEqual(reopened.events.count, 1)
            XCTAssertEqual(reopened.events.first?.id, session)
            XCTAssertEqual(reopened.events.first?.listenedSeconds, 35)
        }
    }

    func testExternalConflictRefusesAcknowledgementUntilReopenAndKeepsOtherSessionChanges() throws {
        try withLibraryTestDirectory { directory in
            let stale = LibraryStore(directory: directory)
            let song = libraryTestTrack()
            let other = libraryTestTrack("external-favorite")
            let session = UUID()
            let start = Date().addingTimeInterval(-60)
            XCTAssertTrue(stale.recordListening(track: song, sessionID: session, startedAt: start, seconds: 20))
            let current = LibraryStore(directory: directory)
            current.toggleFavorite(other)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)

            XCTAssertFalse(stale.recordListening(track: song, sessionID: session, startedAt: start, seconds: 15))
            let error = try XCTUnwrap(stale.errorMessage)
            XCTAssertFalse(stale.recordListening(track: song, sessionID: session, startedAt: start, seconds: 15))
            XCTAssertEqual(stale.errorMessage, error)
            XCTAssertEqual(stale.events.first?.listenedSeconds, 20)
            XCTAssertEqual(try Data(contentsOf: url), saved)

            let reopened = LibraryStore(directory: directory)
            XCTAssertTrue(reopened.recordListening(track: song, sessionID: session, startedAt: start, seconds: 15))
            let restored = LibraryStore(directory: directory)
            XCTAssertEqual(restored.events.first?.listenedSeconds, 35)
            XCTAssertEqual(restored.events.count, 1)
            XCTAssertEqual(restored.favorites, [other])
        }
    }

    func testZeroAndHistoryDisabledUpdatesAcknowledgeNoOpWithoutWritingOrClearingErrors() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let song = libraryTestTrack()
            let start = Date().addingTimeInterval(-60)
            store.toggleFavorite(song)
            store.setLyricsOffset(.nan, for: song.id)
            let error = try XCTUnwrap(store.errorMessage)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            XCTAssertTrue(store.recordListening(track: song, sessionID: UUID(), startedAt: start, seconds: 0))
            XCTAssertEqual(store.errorMessage, error)
            XCTAssertTrue(store.events.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), saved)

            store.preferences.saveListeningHistory = false
            let disabled = try Data(contentsOf: url)
            store.setLyricsOffset(.nan, for: song.id)
            let disabledError = try XCTUnwrap(store.errorMessage)
            XCTAssertTrue(store.recordListening(track: song, sessionID: UUID(), startedAt: start, seconds: 30))
            XCTAssertEqual(store.errorMessage, disabledError)
            XCTAssertTrue(store.events.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), disabled)
            XCTAssertFalse(LibraryStore(directory: directory).preferences.saveListeningHistory)
        }
    }
}
