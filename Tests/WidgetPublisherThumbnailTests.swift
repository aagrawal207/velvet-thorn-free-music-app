import XCTest
@testable import GanaBajana

@MainActor
final class WidgetPublisherThumbnailTests: XCTestCase {
    func testMetadataPublishesBeforeThumbnailsAndRequestsAreBoundedToUniqueDisplayedIDs() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = harness.device().library
        for index in (0..<9).reversed() {
            library.recordRecent(track: WidgetSnapshotTestData.artworkTrack("r\(index)"), position: 0)
            library.toggleFavorite(WidgetSnapshotTestData.artworkTrack("l\(index)"))
        }
        library.toggleFavorite(WidgetSnapshotTestData.artworkTrack("r0"))
        for (index, kind) in [GeneratedPlaylistKind.dailyMix, .discoverWeekly].enumerated() {
            library.saveMix(GeneratedPlaylist(kind: kind, tracks: (0..<10).map { WidgetSnapshotTestData.artworkTrack("m\(index)-\($0)") },
                                              generatedAt: LibrarySyncTestData.now, periodKey: "period", seedArtists: ["Private seed"]))
        }
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        let image = WidgetSnapshotTestData.jpeg()
        var requests: [Track] = []
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { track in
            requests.append(track)
            if requests.count == 1 { await gate.wait() }
            return image
        }) { reloads += 1 }

        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(store.read().availability, .ready)
        XCTAssertEqual(store.read().recentlyPlayed.map(\.id), ["r0", "r1", "r2", "r3", "r4", "r5"])
        XCTAssertEqual(store.read().likedSongCount, 10)
        XCTAssertEqual(store.read().mixSongCounts, ["dailyMix": 10, "discoverWeekly": 10])
        XCTAssertTrue(store.read().artwork.isEmpty)
        try await PlaybackTestSupport.eventually { gate.entered }
        let displayed = store.read().displayedTracks
        XCTAssertEqual(displayed.count, 23)
        let metadataBytes = try Data(contentsOf: XCTUnwrap(store.fileURL))
        for tick in 1...10 { library.recordRecent(track: WidgetSnapshotTestData.artworkTrack("r0"), position: Double(tick)) }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL)), metadataBytes)
        gate.open()
        try await PlaybackTestSupport.eventually { store.read().artwork.count == 23 }
        XCTAssertEqual(requests.map(\.id), displayed.map(\.id))
        XCTAssertTrue(requests.allSatisfy { $0.albumID == nil && $0.duration == nil && $0.credits.allSatisfy { $0.id == nil } })
        XCTAssertEqual(Set(store.read().artwork.keys), Set(displayed.map(\.id)))
        XCTAssertEqual(reloads, 2, "A bounded thumbnail batch causes one additional durable publication")
        publisher.refresh()
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(requests.count, 23)
    }

    func testHistoryOffImmediatelyRemovesRecentsAndRejectsTheirLateArtwork() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = harness.device().library
        library.recordRecent(track: WidgetSnapshotTestData.artworkTrack("private-recent"), position: 4)
        library.toggleFavorite(libraryTestTrack("explicit-like"))
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        let image = WidgetSnapshotTestData.jpeg()
        var returned = false
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in
            await gate.wait()
            returned = true
            return image
        }) { reloads += 1 }
        try await PlaybackTestSupport.eventually { gate.entered }

        library.preferences.saveListeningHistory = false

        XCTAssertFalse(store.read().historyEnabled)
        XCTAssertTrue(store.read().recentlyPlayed.isEmpty)
        XCTAssertEqual(store.read().likedSongs.map(\.id), ["explicit-like"])
        XCTAssertEqual(reloads, 2)
        let clearedBytes = try Data(contentsOf: XCTUnwrap(store.fileURL))
        gate.open()
        try await PlaybackTestSupport.eventually { returned }
        await Task.yield()
        XCTAssertTrue(store.read().artwork.isEmpty)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL)), clearedBytes)
        XCTAssertEqual(reloads, 2)
        withExtendedLifetime(publisher) { }
    }

    func testClearRemovesPreviouslyPublishedPrivateImagesAndRejectsAnOutstandingMixThumbnail() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = harness.device().library
        library.toggleFavorite(WidgetSnapshotTestData.artworkTrack("explicit-like"))
        library.recordRecent(track: WidgetSnapshotTestData.artworkTrack("private-recent"), position: 4)
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        let image = WidgetSnapshotTestData.jpeg()
        var returned = false
        var historyClears = 0
        library.onHistoryCleared = { historyClears += 1 }
        let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { track in
            if track.id == "private-mix" {
                await gate.wait()
                returned = true
            }
            return image
        }, reload: { })
        try await PlaybackTestSupport.eventually { store.read().artwork.count == 2 }
        library.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [WidgetSnapshotTestData.artworkTrack("private-mix")],
                                          generatedAt: LibrarySyncTestData.now, periodKey: "day", seedArtists: []))
        try await PlaybackTestSupport.eventually { gate.entered }

        library.clearHistory()

        XCTAssertEqual(historyClears, 1)
        XCTAssertTrue(store.read().recentlyPlayed.isEmpty)
        XCTAssertTrue(store.read().mixes.isEmpty)
        XCTAssertTrue(store.read().mixSongCounts.isEmpty)
        XCTAssertEqual(Set(store.read().artwork.keys), ["explicit-like"])
        let clearedBytes = try Data(contentsOf: XCTUnwrap(store.fileURL))
        gate.open()
        try await PlaybackTestSupport.eventually { returned }
        await Task.yield()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL)), clearedBytes)
        XCTAssertEqual(Set(store.read().artwork.keys), ["explicit-like"])
        withExtendedLifetime(publisher) { }
    }

    func testHistoryOffOnWithTheSameSongRejectsAnOldGenerationEvenWhenContentMatchesAgain() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = harness.device().library
        library.recordRecent(track: WidgetSnapshotTestData.artworkTrack("same-song"), position: 4)
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        let oldImage = WidgetSnapshotTestData.jpeg(width: 32)
        let freshImage = WidgetSnapshotTestData.jpeg(width: 64)
        var requests = 0
        var oldReturned = false
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in
            requests += 1
            if requests == 1 {
                await gate.wait()
                oldReturned = true
                return oldImage
            }
            return freshImage
        }) { reloads += 1 }
        try await PlaybackTestSupport.eventually { gate.entered }
        library.preferences.saveListeningHistory = false
        library.preferences.saveListeningHistory = true
        try await PlaybackTestSupport.eventually { store.read().artwork["same-song"] == freshImage }
        let beforeLateResult = reloads
        gate.open()
        try await PlaybackTestSupport.eventually { oldReturned }
        await Task.yield()
        XCTAssertEqual(store.read().artwork["same-song"], freshImage)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(reloads, beforeLateResult)
        withExtendedLifetime(publisher) { }
    }

    func testReplacingSavedMixPeriodPreventsOldThumbnailFromRestoringOldSongs() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = harness.device().library
        library.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [WidgetSnapshotTestData.artworkTrack("old-mix-song")],
                                          generatedAt: LibrarySyncTestData.now, periodKey: "old-day", seedArtists: []))
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        let image = WidgetSnapshotTestData.jpeg()
        var oldReturned = false
        let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { track in
            if track.id == "old-mix-song" { await gate.wait(); oldReturned = true }
            return image
        }, reload: { })
        try await PlaybackTestSupport.eventually { gate.entered }
        library.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [WidgetSnapshotTestData.artworkTrack("fresh-mix-song")],
                                          generatedAt: LibrarySyncTestData.now, periodKey: "new-day", seedArtists: []))
        XCTAssertEqual(store.read().mixes.first?.periodKey, "new-day")
        try await PlaybackTestSupport.eventually { store.read().artwork["fresh-mix-song"] != nil }
        gate.open()
        try await PlaybackTestSupport.eventually { oldReturned }
        await Task.yield()
        XCTAssertEqual(store.read().mixes.first?.tracks.map(\.id), ["fresh-mix-song"])
        XCTAssertEqual(Set(store.read().artwork.keys), ["fresh-mix-song"])
        withExtendedLifetime(publisher) { }
    }

    func testLateCompletionRechecksDiskAndRedactsAnUnobservedExternalCorruption() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let device = harness.device()
        device.library.recordRecent(track: WidgetSnapshotTestData.artworkTrack("private-recent"), position: 9)
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        let image = WidgetSnapshotTestData.jpeg()
        let publisher = WidgetSnapshotPublisher(library: device.library, store: store, thumbnail: { _ in
            await gate.wait()
            return image
        }, reload: { })
        try await PlaybackTestSupport.eventually { gate.entered }
        let corrupt = Data("{broken external library".utf8)
        try corrupt.write(to: device.fileURL, options: .atomic)
        gate.open()
        try await PlaybackTestSupport.eventually { store.read().availability == .unavailable }
        XCTAssertTrue(store.read().displayedTracks.isEmpty)
        XCTAssertTrue(store.read().artwork.isEmpty)
        XCTAssertEqual(try Data(contentsOf: device.fileURL), corrupt)
        withExtendedLifetime(publisher) { }
    }

    func testActivationRetriesCacheMissesButUnchangedCheckpointsAndPopulatedRelaunchDoNotReload() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = harness.device().library
        let song = WidgetSnapshotTestData.artworkTrack("cached-later")
        library.recordRecent(track: song, position: 0)
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        let image = WidgetSnapshotTestData.jpeg()
        var available = false
        var requests = 0
        var reloads = 0
        var publisher: WidgetSnapshotPublisher? = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in
            requests += 1
            return available ? image : nil
        }) { reloads += 1 }
        try await PlaybackTestSupport.eventually { requests == 1 }
        await Task.yield()
        for tick in 1...10 { library.recordRecent(track: song, position: Double(tick)) }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(reloads, 1)
        available = true
        publisher?.refresh()
        try await PlaybackTestSupport.eventually { store.read().artwork["cached-later"] != nil }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(reloads, 2)
        let bytes = try Data(contentsOf: XCTUnwrap(store.fileURL))
        publisher?.refresh()
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL)), bytes)
        publisher = nil
        let relaunched = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in
            XCTFail("Matching durable thumbnails survive publisher relaunch")
            return nil
        }) { reloads += 1 }
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL)), bytes)
        withExtendedLifetime(relaunched) { }
    }

    func testThumbnailInjectionStillEnforcesJPEGByteAndPixelBounds() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = harness.device().library
        for id in ["valid", "bad-format", "too-large", "too-many-pixels"] { library.toggleFavorite(WidgetSnapshotTestData.artworkTrack(id)) }
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        let valid = WidgetSnapshotTestData.jpeg()
        let tooManyPixels = WidgetSnapshotTestData.jpeg(width: 241)
        var requests = 0
        let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { track in
            requests += 1
            switch track.id {
            case "bad-format": return Data("bad image".utf8)
            case "too-large": return Data(count: 24 * 1024 + 1)
            case "too-many-pixels": return tooManyPixels
            default: return valid
            }
        }, reload: { })
        try await PlaybackTestSupport.eventually { store.read().artwork["valid"] != nil }
        XCTAssertEqual(requests, 4)
        XCTAssertEqual(Set(store.read().artwork.keys), ["valid"])
        XCTAssertNoThrow(try store.read().validate())
        withExtendedLifetime(publisher) { }
    }

    func testThumbnailBatchEnforcesTheTotalImageByteBudget() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = harness.device().library
        for index in 0..<6 {
            library.toggleFavorite(WidgetSnapshotTestData.artworkTrack("liked-\(index)"))
            library.recordRecent(track: WidgetSnapshotTestData.artworkTrack("recent-\(index)"), position: 0)
        }
        for (index, kind) in [GeneratedPlaylistKind.dailyMix, .discoverWeekly].enumerated() {
            library.saveMix(GeneratedPlaylist(kind: kind, tracks: (0..<6).map { WidgetSnapshotTestData.artworkTrack("mix-\(index)-\($0)") },
                                              generatedAt: LibrarySyncTestData.now, periodKey: "period", seedArtists: []))
        }
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        let image = WidgetSnapshotTestData.jpeg(paddedTo: 24 * 1024)
        var requests = 0
        let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in requests += 1; return image }, reload: { })
        try await PlaybackTestSupport.eventually { !store.read().artwork.isEmpty }
        let saved = store.read()
        XCTAssertEqual(requests, 24)
        XCTAssertEqual(saved.artwork.count, 21)
        XCTAssertLessThanOrEqual(saved.artwork.values.reduce(0) { $0 + $1.count }, 512 * 1024)
        XCTAssertLessThanOrEqual(try Data(contentsOf: XCTUnwrap(store.fileURL)).count, 1024 * 1024)
        withExtendedLifetime(publisher) { }
    }
}
