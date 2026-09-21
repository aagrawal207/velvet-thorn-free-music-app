import XCTest
@testable import GanaBajana

@MainActor
final class TipJarPersistenceTests: XCTestCase {
    func testCreditsAndRefundTombstonesReloadWithTheLibrary() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let track = libraryTestTrack()
            library.toggleFavorite(track)
            let playlist = library.createPlaylist(name: "Keep listening")
            library.add(track, to: playlist)
            library.recordListening(track: track, sessionID: UUID(), startedAt: Date().addingTimeInterval(-60), seconds: 30)
            library.recordSearch("A song")
            library.updatePlayback(PlaybackSnapshot(queue: [track], position: 12))
            library.preferences.appearance = .light

            XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
            XCTAssertTrue(library.recordTip(transactionID: UInt64.max, credited: true))
            XCTAssertTrue(library.recordTip(transactionID: 1, credited: false))
            XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
            XCTAssertEqual(library.tipCount, 1)
            XCTAssertEqual(library.tipCredit(for: 1), false)
            XCTAssertNil(library.tipCredit(for: 2))

            let restored = LibraryStore(directory: directory)
            XCTAssertNil(restored.errorMessage)
            XCTAssertEqual(restored.tipCount, 1)
            XCTAssertEqual(restored.tipCredit(for: 1), false)
            XCTAssertEqual(restored.tipCredit(for: UInt64.max), true)
            XCTAssertEqual(restored.favorites, [track])
            XCTAssertEqual(restored.playlists.first?.tracks, [track])
            XCTAssertEqual(restored.events.first?.listenedSeconds, 30)
            XCTAssertEqual(restored.recentSearches, ["A song"])
            XCTAssertEqual(restored.playback.position, 12)
            XCTAssertEqual(restored.preferences.appearance, .light)
        }
    }

    func testDuplicateCreditDoesNotRewriteAndClearingHistoryKeepsTheLedger() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.recordSearch("A song")
            XCTAssertTrue(library.recordTip(transactionID: 42, credited: true))
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            XCTAssertTrue(library.recordTip(transactionID: 42, credited: true))
            XCTAssertEqual(try Data(contentsOf: url), saved)
            library.clearHistory()
            library.clearRecentSearches()
            library.preferences.saveListeningHistory = false
            XCTAssertEqual(library.tipCount, 1)
            XCTAssertEqual(LibraryStore(directory: directory).tipCredit(for: 42), true)
        }
    }

    func testMissingOrNullLedgerDefaultsToEmptyWithoutReplacingOlderStores() throws {
        for explicitNull in [false, true] {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                let track = libraryTestTrack()
                document.favorites = [track]
                document.preferences.appearance = .light
                document.playback = PlaybackSnapshot(queue: [track], position: 18)
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                if explicitNull { json["tipTransactions"] = NSNull() }
                else { json.removeValue(forKey: "tipTransactions") }
                let old = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(old, to: url, replacing: nil)

                let library = LibraryStore(directory: directory)
                XCTAssertNil(library.errorMessage)
                XCTAssertEqual(library.tipCount, 0)
                XCTAssertEqual(try Data(contentsOf: url), old)
                XCTAssertTrue(library.recordTip(transactionID: 10, credited: true))
                let restored = LibraryStore(directory: directory)
                XCTAssertEqual(restored.tipCount, 1)
                XCTAssertEqual(restored.favorites, [track])
                XCTAssertEqual(restored.preferences.appearance, .light)
                XCTAssertEqual(restored.playback.position, 18)
            }
        }
    }

    func testInvalidLedgerKeysAndValuesBlockLoadingAndPreserveTheWholeFile() throws {
        let invalidLedgers: [Any] = [
            ["": true], [" ": true], ["-1": true], ["+1": true], ["01": true],
            ["1.0": true], ["18446744073709551616": true], ["transaction": true],
            ["1": "true"], ["1": 1], ["1": NSNull()], [true, false],
        ]
        for ledger in invalidLedgers {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                document.favorites = [libraryTestTrack()]
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                json["tipTransactions"] = ledger
                let invalid = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(invalid, to: url, replacing: nil)
                let library = LibraryStore(directory: directory)
                let error = try XCTUnwrap(library.errorMessage)
                XCTAssertFalse(library.recordTip(transactionID: 1, credited: true))
                XCTAssertFalse(library.recordTip(transactionID: 1, credited: false))
                XCTAssertEqual(library.tipCount, 0)
                XCTAssertTrue(library.favorites.isEmpty)
                XCTAssertEqual(library.errorMessage, error)
                XCTAssertEqual(try Data(contentsOf: url), invalid)
            }
        }
    }

    func testCorruptAndFutureStoresRefuseTipWritesWithoutLosingTheirError() throws {
        for bytes in [
            Data("not JSON".utf8),
            Data("{\"version\":9999,\"futurePayload\":{\"keep\":\"everything\"}}".utf8),
        ] {
            try withLibraryTestDirectory { directory in
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: url, replacing: nil)
                let library = LibraryStore(directory: directory)
                let error = try XCTUnwrap(library.errorMessage)
                XCTAssertFalse(library.recordTip(transactionID: 1, credited: true))
                XCTAssertEqual(library.tipCount, 0)
                XCTAssertEqual(library.errorMessage, error)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }

    func testFailedWriteReturnsFalseAndDoesNotPublishCredit() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            XCTAssertFalse(library.recordTip(transactionID: 1, credited: true))
            XCTAssertNotNil(library.errorMessage)
            XCTAssertNil(library.tipCredit(for: 1))
            XCTAssertEqual(library.tipCount, 0)
            try FileManager.default.removeItem(at: url)
            XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(LibraryStore(directory: directory).tipCount, 1)
        }
    }

    func testStaleWriterCannotOverwriteARefundTombstone() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
            let stale = LibraryStore(directory: directory)
            XCTAssertTrue(library.recordTip(transactionID: 1, credited: false))
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            XCTAssertFalse(stale.recordTip(transactionID: 1, credited: true))
            let error = try XCTUnwrap(stale.errorMessage)
            XCTAssertFalse(stale.recordTip(transactionID: 2, credited: true))
            XCTAssertEqual(stale.errorMessage, error)
            XCTAssertEqual(try Data(contentsOf: url), saved)
            XCTAssertEqual(LibraryStore(directory: directory).tipCredit(for: 1), false)
        }
    }

    func testExternalCorruptionIsNotAcknowledgedEvenForAnAlreadyRecordedTip() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let corrupt = Data("{broken library".utf8)
            try corrupt.write(to: url, options: .atomic)
            XCTAssertFalse(library.recordTip(transactionID: 1, credited: true))
            XCTAssertNotNil(library.errorMessage)
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
        }
    }
}
