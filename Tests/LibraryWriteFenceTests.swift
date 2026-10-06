import CryptoKit
import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class LibraryWriteFenceTests: XCTestCase {
    private func libraryURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(LibraryPersistence.fileName)
    }

    func testOwnWritesProveTheBaselineByMetadataWithoutReadingContent() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.toggleFavorite(libraryTestTrack("a"))
            // The first fence has no stamp for an absent file, so it compares content once.
            XCTAssertEqual(library.contentFenceReadCount, 1)
            let reads = library.contentFenceReadCount
            library.toggleFavorite(libraryTestTrack("b"))
            library.setLyricsOffset(0.5, for: "a")
            library.recordSearch("first query")
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(library.contentFenceReadCount, reads)
            XCTAssertEqual(library.lastPersistFence, .metadata)
            XCTAssertEqual(library.durableCommitCount, 4)
            XCTAssertEqual(LibraryStore(directory: directory).favorites.map(\.id), ["b", "a"])
        }
    }

    func testReopenedStoreStartsWithAMetadataFence() throws {
        try withLibraryTestDirectory { directory in
            LibraryStore(directory: directory).toggleFavorite(libraryTestTrack("a"))
            let reopened = LibraryStore(directory: directory)
            reopened.toggleFavorite(libraryTestTrack("b"))
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(reopened.contentFenceReadCount, 0)
            XCTAssertEqual(reopened.lastPersistFence, .metadata)
        }
    }

    func testSameSizeInPlaceEditWithRestoredModificationDateIsDetectedAndPreserved() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.toggleFavorite(libraryTestTrack("song-a"))
            let url = libraryURL(directory)
            let original = try Data(contentsOf: url)
            let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            var foreign = original
            let range = try XCTUnwrap(foreign.range(of: Data("song-a".utf8)))
            foreign.replaceSubrange(range, with: Data("song-z".utf8))
            XCTAssertEqual(foreign.count, original.count)
            let handle = try FileHandle(forUpdating: url)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: foreign)
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            let reads = library.contentFenceReadCount

            library.toggleFavorite(libraryTestTrack("song-b"))

            XCTAssertTrue(library.requiresReload)
            XCTAssertNotNil(library.errorMessage)
            XCTAssertEqual(library.contentFenceReadCount, reads + 1)
            XCTAssertEqual(try Data(contentsOf: url), foreign)
            XCTAssertEqual(library.favorites.map(\.id), ["song-a"])
        }
    }

    func testSameSizeAtomicReplacementIsDetectedAndPreserved() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.toggleFavorite(libraryTestTrack("song-a"))
            let url = libraryURL(directory)
            var foreign = try Data(contentsOf: url)
            let range = try XCTUnwrap(foreign.range(of: Data("song-a".utf8)))
            foreign.replaceSubrange(range, with: Data("song-q".utf8))
            try foreign.write(to: url, options: .atomic)
            let commits = library.durableCommitCount

            XCTAssertFalse(library.removeRecentSearchSelection(id: "track:missing"))
            XCTAssertTrue(library.requiresReload)
            library.toggleFavorite(libraryTestTrack("song-b"))

            XCTAssertEqual(library.durableCommitCount, commits)
            XCTAssertEqual(try Data(contentsOf: url), foreign)
        }
    }

    func testTouchedModificationDateFallsBackToContentAndStillWrites() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.toggleFavorite(libraryTestTrack("a"))
            let url = libraryURL(directory)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                                                  ofItemAtPath: url.path)
            let reads = library.contentFenceReadCount

            library.toggleFavorite(libraryTestTrack("b"))
            XCTAssertNil(library.errorMessage)
            XCTAssertFalse(library.requiresReload)
            XCTAssertEqual(library.contentFenceReadCount, reads + 1)
            XCTAssertEqual(library.lastPersistFence, .content)

            library.toggleFavorite(libraryTestTrack("c"))
            XCTAssertEqual(library.contentFenceReadCount, reads + 1)
            XCTAssertEqual(library.lastPersistFence, .metadata)
            XCTAssertEqual(LibraryStore(directory: directory).favorites.map(\.id), ["c", "b", "a"])
        }
    }

    func testDeletedFileIsDetectedAndNotRecreated() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.toggleFavorite(libraryTestTrack("a"))
            let url = libraryURL(directory)
            try FileManager.default.removeItem(at: url)
            library.toggleFavorite(libraryTestTrack("b"))
            XCTAssertTrue(library.requiresReload)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testNoChangeCheckpointPerformsNoContentReadAndNoWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajana-LibraryWriteFence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = libraryTestTrack("a")
        let library = LibraryStore(directory: directory)
        library.updatePlayback(PlaybackSnapshot(queue: [track], position: 12, originalQueue: [track]))
        let url = libraryURL(directory)
        let bytes = try Data(contentsOf: url)
        let stamp = try XCTUnwrap(LibraryFileStamp(url))
        let reads = library.contentFenceReadCount
        let commits = library.durableCommitCount

        let prepared = try await library.prepareListeningCheckpoint(events: [], snapshot: library.playback)
        XCTAssertFalse(try library.applyListeningCheckpoint(prepared))

        XCTAssertEqual(library.lastListeningCheckpointMetrics?.outcome, "no_change")
        XCTAssertEqual(library.lastPersistFence, .metadata)
        XCTAssertEqual(library.contentFenceReadCount, reads)
        XCTAssertEqual(library.durableCommitCount, commits)
        XCTAssertEqual(LibraryFileStamp(url), stamp)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testNoChangeCheckpointStillRejectsAnExternalChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajana-LibraryWriteFence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = libraryTestTrack("song-a")
        let library = LibraryStore(directory: directory)
        library.updatePlayback(PlaybackSnapshot(queue: [track], position: 12, originalQueue: [track]))
        let url = libraryURL(directory)
        let prepared = try await library.prepareListeningCheckpoint(events: [], snapshot: library.playback)
        var foreign = try Data(contentsOf: url)
        let range = try XCTUnwrap(foreign.range(of: Data("song-a".utf8)))
        foreign.replaceSubrange(range, with: Data("song-x".utf8))
        try foreign.write(to: url)

        XCTAssertThrowsError(try library.applyListeningCheckpoint(prepared)) { error in
            guard case LibraryStorageError.changedOnDisk = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), foreign)
    }

    func testManualCommitDuringCheckpointIsSerializedWithoutLostUpdates() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now },
                                   beforeListeningCheckpointPreparation: { await gate.enter(wasMainThread: false) })
        library.toggleFavorite(libraryTestTrack("before"))
        let reads = library.contentFenceReadCount
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack("async"), startedAt: LibrarySyncTestData.now,
                                   listenedSeconds: 5)
        let work = Task { await library.recordListeningCheckpoint(events: [event]) }
        await gate.waitForEntry()
        library.toggleFavorite(libraryTestTrack("during"))
        await gate.release()
        let acknowledged = await work.value
        XCTAssertTrue(acknowledged)
        library.toggleFavorite(libraryTestTrack("after"))

        XCTAssertNil(library.errorMessage)
        XCTAssertFalse(library.requiresReload)
        XCTAssertEqual(library.contentFenceReadCount, reads)
        XCTAssertEqual(library.durableCommitCount, 4)
        let reopened = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        XCTAssertEqual(reopened.favorites.map(\.id), ["after", "during", "before"])
        XCTAssertEqual(reopened.events.first?.listenedSeconds, 5)
    }

    func testReplaceLeavesNoTemporaryFilesOnSuccessOrFailure() throws {
        try withLibraryTestDirectory { directory in
            let url = libraryURL(directory)
            let stamp = try XCTUnwrap(LibraryPersistence.replace(Data("{}".utf8), at: url))
            XCTAssertEqual(LibraryFileStamp(url), stamp)
            XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
            let blocked = directory.appendingPathComponent("blocked.json", isDirectory: true)
            try FileManager.default.createDirectory(at: blocked.appendingPathComponent("child"), withIntermediateDirectories: true)
            XCTAssertThrowsError(try LibraryPersistence.replace(Data("{}".utf8), at: blocked))
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertEqual(Set(names), [LibraryPersistence.fileName, "blocked.json"])
        }
    }

    func testVerifyUsesMetadataOnlyForAnUnchangedStamp() throws {
        try withLibraryTestDirectory { directory in
            let url = libraryURL(directory)
            let bytes = Data("{\"a\":1}".utf8)
            var stamp = try LibraryPersistence.replace(bytes, at: url)
            XCTAssertNotNil(stamp)
            XCTAssertEqual(try LibraryPersistence.verify(url, expected: bytes, stamp: &stamp), .metadata)
            try Data("{\"a\":2}".utf8).write(to: url)
            XCTAssertThrowsError(try LibraryPersistence.verify(url, expected: bytes, stamp: &stamp))
            XCTAssertNil(stamp)
            try bytes.write(to: url)
            XCTAssertEqual(try LibraryPersistence.verify(url, expected: bytes, stamp: &stamp), .content)
            XCTAssertEqual(stamp, LibraryFileStamp(url))
            XCTAssertEqual(try LibraryPersistence.verify(url, expected: bytes, stamp: &stamp), .metadata)
        }
    }

    func testHexEncoderMatchesFormattedDigests() {
        func formatted<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        for input in ["", "song-a", "dQw4w9WgXcQ", "saavn:abc123", "gaana:कोई गीत", String(repeating: "x", count: 4096)] {
            let digest = SHA256.hash(data: Data(input.utf8))
            XCTAssertEqual(LibraryHex.sha256(input), formatted(digest), input)
        }
        let allBytes = (0...255).map { UInt8($0) }
        XCTAssertEqual(LibraryHex.lowercase(allBytes), formatted(allBytes))
        XCTAssertEqual(LibraryHex.lowercase([UInt8]()), "")
        XCTAssertEqual(LibraryHex.lowercase([UInt8]([0x00, 0x0f, 0xa0, 0xff])), "000fa0ff")
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack("song-a"), startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   listenedSeconds: 60)
        XCTAssertEqual(LifetimeListeningContribution(event).identity, formatted(SHA256.hash(data: Data("song-a".utf8))))
    }

    func testSingleParseDecodeKeepsVersionErrors() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(LibraryDocument())) as? [String: Any])
        object["version"] = LibraryPersistence.currentVersion + 1
        object["favorites"] = "not an array"
        XCTAssertThrowsError(try LibraryPersistence.decode(JSONSerialization.data(withJSONObject: object), now: Date())) {
            guard case LibraryStorageError.newerVersion = $0 else { return XCTFail("\($0)") }
        }
        object["version"] = 0
        XCTAssertThrowsError(try LibraryPersistence.decode(JSONSerialization.data(withJSONObject: object), now: Date())) {
            guard case LibraryStorageError.unsupportedVersion = $0 else { return XCTFail("\($0)") }
        }
        object.removeValue(forKey: "version")
        XCTAssertThrowsError(try LibraryPersistence.decode(JSONSerialization.data(withJSONObject: object), now: Date())) {
            XCTAssertTrue($0 is DecodingError, "\($0)")
        }
    }
}
