import XCTest
@testable import GanaBajana

@MainActor
final class LiveRadioFavoritesTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LiveRadioFavoritesTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("stations.json")
    }

    func testFavoritesPersistSeparatelyWithPublicURLsAndCanBeRemoved() throws {
        let url = try temporaryURL()
        let store = LiveRadioFavorites(url: url)
        XCTAssertFalse(store.requiresReload)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.toggle(LiveRadioTestSupport.station))
        let restored = LiveRadioFavorites(url: url)
        XCTAssertEqual(restored.stations, [LiveRadioTestSupport.station])
        XCTAssertTrue(restored.toggle(LiveRadioTestSupport.station))
        XCTAssertTrue(LiveRadioFavorites(url: url).stations.isEmpty)
        XCTAssertNil(restored.errorMessage)
    }

    func testCorruptAndFutureDocumentsAreKeptByteForByteUntilExplicitReload() throws {
        let url = try temporaryURL()
        for text in ["corrupt", "{\"version\":999,\"stations\":[]}", "{\"stations\":[]}"] {
            let data = Data(text.utf8)
            try data.write(to: url, options: .atomic)
            let store = LiveRadioFavorites(url: url)
            XCTAssertTrue(store.requiresReload)
            XCTAssertFalse(store.toggle(LiveRadioTestSupport.station))
            XCTAssertEqual(try Data(contentsOf: url), data)
            try Data("{\"version\":1,\"stations\":[]}".utf8).write(to: url, options: .atomic)
            XCTAssertFalse(store.toggle(LiveRadioTestSupport.station))
            store.reload()
            XCTAssertTrue(store.toggle(LiveRadioTestSupport.station))
        }
    }

    func testExternalChangeRejectsWriteAndPublishesNoOptimisticFavorites() throws {
        let url = try temporaryURL()
        let first = LiveRadioFavorites(url: url)
        let other = LiveRadioFavorites(url: url)
        XCTAssertTrue(other.toggle(LiveRadioTestSupport.station))
        let durable = try Data(contentsOf: url)
        XCTAssertFalse(first.toggle(LiveRadioTestSupport.station))
        XCTAssertTrue(first.stations.isEmpty)
        XCTAssertTrue(first.requiresReload)
        XCTAssertEqual(try Data(contentsOf: url), durable)
        first.reload()
        XCTAssertEqual(first.stations, other.stations)
    }

    func testCapacityRejectsNewFavoriteWithoutEvictingOldOnes() {
        let store = LiveRadioFavorites(url: nil)
        for _ in 0..<LiveRadioFavorites.capacity {
            let station = LiveRadioStation(id: UUID(), name: "Station", streamingURL: LiveRadioTestSupport.station.streamingURL,
                homepageURL: nil, artworkURL: nil, countryCode: "", languages: [], tags: [], codec: "MP3", isHLS: false)
            XCTAssertTrue(store.toggle(station))
        }
        let saved = store.stations
        XCTAssertFalse(store.toggle(LiveRadioTestSupport.station))
        XCTAssertEqual(store.stations, saved)
        XCTAssertTrue(store.toggle(saved[0]))
        XCTAssertTrue(store.toggle(LiveRadioTestSupport.station))
    }

    func testInvalidStoredURLAndOversizedFileFailClosed() throws {
        let url = try temporaryURL()
        let station = LiveRadioStation(id: UUID(), name: "Station", streamingURL: URL(fileURLWithPath: "/private/audio.mp3"),
            homepageURL: nil, artworkURL: nil, countryCode: "", languages: [], tags: [], codec: "MP3", isHLS: false)
        let object = ["version": 1, "stations": try JSONSerialization.jsonObject(with: JSONEncoder().encode([station]))] as [String: Any]
        let invalid = try JSONSerialization.data(withJSONObject: object)
        for data in [invalid, Data(repeating: 32, count: LiveRadioFavorites.maximumBytes + 1)] {
            try data.write(to: url, options: .atomic)
            let store = LiveRadioFavorites(url: url)
            XCTAssertTrue(store.requiresReload)
            XCTAssertFalse(store.toggle(LiveRadioTestSupport.station))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testStationFavoritesDoNotChangeSavedMusicPreferences() throws {
        let url = try temporaryURL()
        let directory = url.deletingLastPathComponent().appendingPathComponent("music")
        let library = LibraryStore(directory: directory)
        var savedPreferences = library.preferences
        savedPreferences.shuffleStyle = .random
        savedPreferences.audioQuality = .dataSaver
        library.preferences = savedPreferences
        let preferences = library.preferences
        let favorites = LiveRadioFavorites(url: url)
        XCTAssertTrue(favorites.toggle(LiveRadioTestSupport.station))
        favorites.reload()
        XCTAssertEqual(LibraryStore(directory: directory).preferences, preferences)
        XCTAssertTrue(library.favorites.isEmpty)
        XCTAssertTrue(library.events.isEmpty)
    }

    func testMissingParentStartsEmptyAndFirstWriteCreatesDurableStore() throws {
        let root = try temporaryURL().deletingLastPathComponent()
        let directory = root.appendingPathComponent("missing/nested", isDirectory: true)
        let url = directory.appendingPathComponent("stations.json")
        let store = LiveRadioFavorites(url: url)
        XCTAssertFalse(store.requiresReload)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.stations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(store.toggle(LiveRadioTestSupport.station))
        XCTAssertEqual(LiveRadioFavorites(url: url).stations, [LiveRadioTestSupport.station])
    }

    func testExternalDeletionRequiresReloadRatherThanRecreatingSavedFile() throws {
        let url = try temporaryURL()
        let store = LiveRadioFavorites(url: url)
        XCTAssertTrue(store.toggle(LiveRadioTestSupport.station))
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(store.toggle(LiveRadioTestSupport.station))
        XCTAssertTrue(store.requiresReload)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.stations, [LiveRadioTestSupport.station])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.reload()
        XCTAssertFalse(store.requiresReload)
        XCTAssertTrue(store.stations.isEmpty)
        XCTAssertTrue(store.toggle(LiveRadioTestSupport.station))
        XCTAssertEqual(LiveRadioFavorites(url: url).stations, [LiveRadioTestSupport.station])
    }

    func testNonDirectoryParentIsNotTreatedAsMissingAndIsPreserved() throws {
        let parent = try temporaryURL()
        let original = Data("existing parent file".utf8)
        try original.write(to: parent, options: .atomic)
        let store = LiveRadioFavorites(url: parent.appendingPathComponent("stations.json"))
        XCTAssertTrue(store.requiresReload)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.toggle(LiveRadioTestSupport.station))
        XCTAssertTrue(store.stations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: parent), original)
    }
}
