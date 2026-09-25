import XCTest
@testable import GanaBajana

@MainActor
final class WidgetSnapshotStoreTests: XCTestCase {
    func testAbsentSnapshotNeedsAppWhileMissingOrInvalidGroupIsUnavailable() throws {
        try withLibraryTestDirectory { directory in
            let store = WidgetSnapshotStore(directory: directory)
            XCTAssertEqual(store.read(), .empty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            for unavailable in [WidgetSnapshotStore(directory: nil), WidgetSnapshotStore(directory: URL(string: "https://group.invalid"))] {
                XCTAssertEqual(unavailable.read().availability, .unavailable)
                XCTAssertTrue(unavailable.read().displayedTracks.isEmpty)
                XCTAssertThrowsError(try unavailable.write(WidgetSnapshotTestData.snapshot()))
            }
        }
    }

    func testAtomicRoundTripAndUnchangedContentPreserveBytesTimestampAndOpenReader() throws {
        try withLibraryTestDirectory { directory in
            let store = WidgetSnapshotStore(directory: directory)
            let first = WidgetSnapshotTestData.snapshot("first")
            XCTAssertTrue(try store.write(first))
            XCTAssertEqual(store.read(), first)
            let url = try XCTUnwrap(store.fileURL)
            let bytes = try Data(contentsOf: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            var unchanged = first
            unchanged.updatedAt = first.updatedAt.addingTimeInterval(600)

            XCTAssertFalse(try store.write(unchanged))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(store.read().updatedAt, first.updatedAt)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
                           attributes[.modificationDate] as? Date)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber,
                           attributes[.systemFileNumber] as? NSNumber)

            let oldReader = try FileHandle(forReadingFrom: url)
            defer { try? oldReader.close() }
            let second = WidgetSnapshotTestData.snapshot("second")
            XCTAssertTrue(try store.write(second))
            XCTAssertEqual(try oldReader.readToEnd(), bytes, "Publication replaces the file rather than editing an open reader's bytes")
            XCTAssertEqual(WidgetSnapshotStore(directory: directory).read(), second)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [WidgetSnapshotStore.fileName])
        }
    }

    func testDerivedDirectoryAndFileAreExcludedFromBackupWithoutMigratingTheLibrary() throws {
        try withLibraryTestDirectory { directory in
            var legacy = LibraryDocument()
            legacy.version = 1
            legacy.favorites = [libraryTestTrack("installed")]
            let libraryURL = directory.appendingPathComponent(LibraryPersistence.fileName)
            let libraryBytes = try LibraryPersistence.encode(legacy)
            try LibraryPersistence.write(libraryBytes, to: libraryURL, replacing: nil)
            let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets", isDirectory: true))
            XCTAssertTrue(try store.write(WidgetSnapshotTestData.snapshot()))
            let widgetURL = try XCTUnwrap(store.fileURL)
            let folder = try XCTUnwrap(store.directory)
            XCTAssertEqual(try widgetURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            XCTAssertEqual(try Data(contentsOf: libraryURL), libraryBytes)
        }
    }

    func testSubsecondMixDatesDoNotCauseDuplicateWritesAfterSerialization() throws {
        try withLibraryTestDirectory { directory in
            let store = WidgetSnapshotStore(directory: directory)
            let generated = Date(timeIntervalSinceReferenceDate: 811_512_345.1234567)
            let mix = GeneratedPlaylist(kind: .dailyMix, tracks: [Track(id: "song", title: "Song")],
                                        generatedAt: generated, periodKey: "day", seedArtists: [])
            var snapshot = WidgetLibrarySnapshot(mixes: [mix])
            XCTAssertTrue(try store.write(snapshot))
            let bytes = try Data(contentsOf: XCTUnwrap(store.fileURL))
            snapshot.updatedAt.addTimeInterval(1_000)
            XCTAssertFalse(try store.write(snapshot))
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL)), bytes)
        }
    }

    func testPostWriteBackupMetadataFailureThrowsAndIdenticalRetryPreservesTheAtomicFile() throws {
        try withLibraryTestDirectory { directory in
            let attempts = CatalogTestCounter()
            let observedFiles = CatalogTestRecorder<WidgetLibrarySnapshot>()
            let fileSystem = WidgetSnapshotStore.FileSystem(excludeFromBackup: { url in
                if url.lastPathComponent == WidgetSnapshotStore.fileName {
                    observedFiles.record(try WidgetSnapshotStore.decode(Data(contentsOf: url)))
                    if attempts.increment() == 1 { throw CocoaError(.fileWriteNoPermission) }
                }
                try WidgetSnapshotStore.FileSystem.live.excludeFromBackup(url)
            })
            let store = WidgetSnapshotStore(directory: directory, fileSystem: fileSystem)
            var snapshot = WidgetSnapshotTestData.snapshot()

            XCTAssertThrowsError(try store.write(snapshot)) {
                XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission)
            }

            XCTAssertEqual(observedFiles.values, [snapshot], "The real atomic bytes must exist before the metadata failure")
            XCTAssertEqual(store.read(), snapshot)
            let url = try XCTUnwrap(store.fileURL)
            let bytes = try Data(contentsOf: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            snapshot.updatedAt.addTimeInterval(10)
            XCTAssertFalse(try store.write(snapshot))
            XCTAssertEqual(observedFiles.values.count, 2)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber,
                           attributes[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
                           attributes[.modificationDate] as? Date)
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
    }

    func testCorruptUnsupportedFutureAndUnknownFieldsAreUnavailableAndPreservedOnWrite() throws {
        let baseline = WidgetSnapshotTestData.snapshot()
        let valid = try WidgetSnapshotStore.encode(baseline)
        var payloads = [Data("{broken".utf8), Data("{\"version\":0}".utf8), Data("{\"version\":2,\"future\":true}".utf8)]
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["unknown"] = "private metadata" },
            { $0["availability"] = "futureState" },
            { $0["accent"] = "futureAccent" },
            { object in
                var tracks = object["recentlyPlayed"] as! [[String: Any]]
                tracks[0]["signedMediaURL"] = "https://private.invalid/audio?secret=true"
                object["recentlyPlayed"] = tracks
            },
            { object in
                var tracks = object["recentlyPlayed"] as! [[String: Any]]
                var credits = tracks[0]["credits"] as! [[String: Any]]
                credits[0]["unknown"] = "private credit"
                tracks[0]["credits"] = credits
                object["recentlyPlayed"] = tracks
            },
        ]
        for change in changes {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            change(&object)
            payloads.append(try JSONSerialization.data(withJSONObject: object))
        }
        for bytes in payloads {
            try withLibraryTestDirectory { directory in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let store = WidgetSnapshotStore(directory: directory)
                let url = try XCTUnwrap(store.fileURL)
                try bytes.write(to: url, options: .atomic)
                XCTAssertEqual(store.read().availability, .unavailable)
                XCTAssertTrue(store.read().displayedTracks.isEmpty)
                XCTAssertThrowsError(try store.write(baseline))
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                XCTAssertThrowsError(try WidgetSnapshotStore(directory: directory).write(.empty))
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }

    func testMissingRequiredFieldsWrongShapesAndInvalidPrivacyOrCountCombinationsFailClosed() throws {
        let valid = try WidgetSnapshotStore.encode(WidgetSnapshotTestData.snapshot())
        let changes: [(inout [String: Any]) -> Void] = [
            { $0.removeValue(forKey: "availability") },
            { $0["historyEnabled"] = NSNull() },
            { $0["historyEnabled"] = false },
            { $0["availability"] = "needsApp" },
            { $0["likedSongCount"] = 0 },
            { $0["likedSongCount"] = -1 },
            { $0["mixSongCounts"] = ["dailyMix": 900] },
            { $0["artwork"] = [] },
            { $0["updatedAt"] = -1 },
            { $0["recentlyPlayed"] = Array(repeating: ($0["recentlyPlayed"] as! [Any])[0], count: 7) },
            { object in
                var tracks = object["recentlyPlayed"] as! [[String: Any]]
                tracks[0].removeValue(forKey: "credits")
                tracks[0]["artists"] = ["Legacy fallback must not enter this wire format"]
                object["recentlyPlayed"] = tracks
            },
        ]
        for change in changes {
            try withLibraryTestDirectory { directory in
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
                change(&object)
                let bytes = try JSONSerialization.data(withJSONObject: object)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let store = WidgetSnapshotStore(directory: directory)
                try bytes.write(to: XCTUnwrap(store.fileURL), options: .atomic)
                XCTAssertEqual(store.read().availability, .unavailable)
                XCTAssertThrowsError(try store.write(WidgetSnapshotTestData.snapshot()))
            }
        }
    }

    func testUnknownMixKindsPeriodsAndOversizedRowsAreUnavailableAndPreserved() throws {
        let mix = GeneratedPlaylist(kind: .dailyMix, tracks: [Track(id: "mix-song", title: "Song")],
                                    generatedAt: RecommendationFixtures.now, periodKey: "day", seedArtists: [])
        let valid = try WidgetSnapshotStore.encode(WidgetLibrarySnapshot(mixes: [mix]))
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["kind"] = "futureMix" },
            { $0["periodKey"] = String(repeating: "x", count: 257) },
            { $0["periodKey"] = "" },
            { $0["seedArtists"] = ["Private seed"] },
            { $0["generatedAt"] = -1 },
            { $0["tracks"] = Array(repeating: ($0["tracks"] as! [Any])[0], count: 7) },
        ]
        for change in changes {
            try withLibraryTestDirectory { directory in
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
                var mixes = object["mixes"] as! [[String: Any]]
                change(&mixes[0])
                object["mixes"] = mixes
                let bytes = try JSONSerialization.data(withJSONObject: object)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let store = WidgetSnapshotStore(directory: directory)
                let url = try XCTUnwrap(store.fileURL)
                try bytes.write(to: url, options: .atomic)
                XCTAssertEqual(store.read().availability, .unavailable)
                XCTAssertThrowsError(try store.write(.empty))
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }

    func testOversizedSparseFileIsRejectedWithoutReadingOrReplacingItsBody() throws {
        try withLibraryTestDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = WidgetSnapshotStore(directory: directory)
            let url = try XCTUnwrap(store.fileURL)
            let prefix = try WidgetSnapshotStore.encode(WidgetSnapshotTestData.snapshot())
            try prefix.write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let size = UInt64(WidgetSnapshotStore.maximumFileBytes) * 1024
            try handle.truncate(atOffset: size)

            XCTAssertEqual(store.read().availability, .unavailable)
            XCTAssertThrowsError(try store.write(.empty)) { XCTAssertEqual($0 as? WidgetSnapshotError, .tooLarge) }
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value, size)
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            XCTAssertEqual(try reader.read(upToCount: prefix.count), prefix)
        }
    }

    func testDirectoriesAndSymlinksAreNotValidSnapshotFilesOrCacheDirectories() throws {
        try withLibraryTestDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = WidgetSnapshotStore(directory: directory)
            let url = try XCTUnwrap(store.fileURL)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertEqual(store.read().availability, .unavailable)
            XCTAssertThrowsError(try store.write(.empty))
            try FileManager.default.removeItem(at: url)
            let target = directory.appendingPathComponent("preserve.json")
            let bytes = try WidgetSnapshotStore.encode(WidgetSnapshotTestData.snapshot())
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            XCTAssertEqual(store.read().availability, .unavailable)
            XCTAssertThrowsError(try store.write(.empty))
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            let link = directory.appendingPathComponent("linked-directory", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
            XCTAssertEqual(WidgetSnapshotStore(directory: link).read().availability, .unavailable)
            XCTAssertThrowsError(try WidgetSnapshotStore(directory: link).write(.empty))
        }
    }

    func testInvalidCandidateLeavesTheLastDurableSnapshotUnchanged() throws {
        try withLibraryTestDirectory { directory in
            let store = WidgetSnapshotStore(directory: directory)
            let valid = WidgetSnapshotTestData.snapshot()
            XCTAssertTrue(try store.write(valid))
            let url = try XCTUnwrap(store.fileURL)
            let bytes = try Data(contentsOf: url)
            var candidate = valid
            candidate.artwork["private-undisplayed"] = WidgetSnapshotTestData.jpeg()
            XCTAssertThrowsError(try store.write(candidate))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(store.read(), valid)
        }
    }
}
