import XCTest
@testable import GanaBajana

@MainActor
final class WidgetPublisherTests: XCTestCase {
    func testInitializationAndSavedChangesPublishCurrentMembershipAndPreserveOtherCallbacks() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory.appendingPathComponent("library"))
            library.toggleFavorite(libraryTestTrack("liked"))
            library.recordRecent(track: libraryTestTrack("recent"), position: 5)
            let mix = GeneratedPlaylist(kind: .dailyMix, tracks: [libraryTestTrack("mixed")],
                                        generatedAt: RecommendationFixtures.now, periodKey: "day", seedArtists: ["Private seed"])
            library.saveMix(mix)
            let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets"))
            var reloads = 0
            var syncChanges = 0
            var historyClears = 0
            library.onSyncChange = { syncChanges += 1 }
            library.onHistoryCleared = { historyClears += 1 }
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) {
                reloads += 1
                XCTAssertEqual(store.read().availability, .ready)
            }
            XCTAssertEqual(reloads, 1)
            XCTAssertEqual(store.read().recentlyPlayed.map(\.id), ["recent"])
            XCTAssertEqual(store.read().likedSongs.map(\.id), ["liked"])
            XCTAssertEqual(store.read().mixes.first?.tracks.map(\.id), ["mixed"])
            library.toggleFavorite(libraryTestTrack("new-like"))
            XCTAssertEqual(store.read().likedSongs.map(\.id), ["new-like", "liked"])
            library.toggleDislike(libraryTestTrack("liked"))
            XCTAssertEqual(store.read().likedSongs.map(\.id), ["new-like"])
            library.preferences.accent = .ocean
            XCTAssertEqual(store.read().accent, .ocean)
            library.clearHistory()
            XCTAssertTrue(store.read().recentlyPlayed.isEmpty)
            XCTAssertTrue(store.read().mixes.isEmpty)
            XCTAssertTrue(store.read().mixSongCounts.isEmpty)
            XCTAssertEqual(store.read().likedSongs.map(\.id), ["new-like"])
            XCTAssertEqual(historyClears, 1)
            XCTAssertEqual(syncChanges, 4)
            XCTAssertEqual(reloads, 5)
            withExtendedLifetime(publisher) { }
        }
    }

    func testUnchangedListeningRecentAndPlaybackCheckpointsNeverRewriteOrReloadProjection() throws {
        try withLibraryTestDirectory { directory in
            let time = RecommendationFixtures.now
            let library = LibraryStore(directory: directory.appendingPathComponent("library"), now: { time })
            let track = libraryTestTrack()
            library.toggleFavorite(track)
            library.recordRecent(track: track, position: 0)
            let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets"))
            var reloads = 0
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
            let url = try XCTUnwrap(store.fileURL)
            let original = try Data(contentsOf: url)
            let session = UUID()
            for tick in 1...20 {
                XCTAssertTrue(library.recordListening(track: track, sessionID: session, startedAt: time, seconds: 1))
                library.recordRecent(track: track, position: Double(tick))
                library.updatePlayback(PlaybackSnapshot(queue: [track], position: Double(tick)))
            }
            XCTAssertEqual(library.events.first?.listenedSeconds, 20)
            XCTAssertEqual(library.playback.position, 20)
            XCTAssertEqual(reloads, 1)
            XCTAssertEqual(try Data(contentsOf: url), original)
            publisher.refresh()
            XCTAssertEqual(reloads, 1)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testFailedPreferenceCandidateLeavesDurableHistoryAndWidgetBytesUnchanged() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory.appendingPathComponent("library"))
            library.recordRecent(track: libraryTestTrack("saved-recent"), position: 12)
            let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets"))
            var reloads = 0
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
            let original = try Data(contentsOf: XCTUnwrap(store.fileURL))
            var rejected = library.preferences
            rejected.saveListeningHistory = false
            rejected.crossfadeSeconds = 999
            library.preferences = rejected
            XCTAssertNotNil(library.errorMessage)
            XCTAssertTrue(library.preferences.saveListeningHistory)
            XCTAssertEqual(store.read().recentlyPlayed.map(\.id), ["saved-recent"])
            XCTAssertTrue(store.read().historyEnabled)
            XCTAssertEqual(reloads, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL)), original)
            publisher.refresh()
            XCTAssertEqual(reloads, 1)
        }
    }

    func testFailedSaveWithUnavailableFileRedactsOldProjectionInsteadOfPublishingTheCandidate() throws {
        try withLibraryTestDirectory { directory in
            let libraryDirectory = directory.appendingPathComponent("library")
            let library = LibraryStore(directory: libraryDirectory)
            library.toggleFavorite(libraryTestTrack("saved"))
            let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets"))
            var reloads = 0
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
            let file = libraryDirectory.appendingPathComponent(LibraryPersistence.fileName)
            let backup = libraryDirectory.appendingPathComponent("backup.json")
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

            library.toggleFavorite(libraryTestTrack("failed-candidate"))

            XCTAssertEqual(library.favorites.map(\.id), ["saved"])
            XCTAssertNotNil(library.errorMessage)
            XCTAssertEqual(store.read().availability, .unavailable)
            XCTAssertTrue(store.read().displayedTracks.isEmpty)
            XCTAssertTrue(store.read().artwork.isEmpty)
            XCTAssertEqual(reloads, 2)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: backup, to: file)
            XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            XCTAssertEqual(store.read().likedSongs.map(\.id), ["saved"])
            XCTAssertEqual(reloads, 3)
            withExtendedLifetime(publisher) { }
        }
    }

    func testActivationRedactsAnExternalChangeAndValidatedReloadPublishesItWithoutRewritingLibrary() throws {
        try withLibraryTestDirectory { directory in
            let libraryDirectory = directory.appendingPathComponent("library")
            let library = LibraryStore(directory: libraryDirectory)
            library.toggleFavorite(libraryTestTrack("old"))
            let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets"))
            var reloads = 0
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
            let external = LibraryStore(directory: libraryDirectory)
            external.toggleFavorite(libraryTestTrack("old"))
            external.toggleFavorite(libraryTestTrack("new"))
            external.preferences.accent = .teal
            let file = libraryDirectory.appendingPathComponent(LibraryPersistence.fileName)
            let externalBytes = try Data(contentsOf: file)
            publisher.refresh()
            XCTAssertEqual(store.read().availability, .unavailable)
            XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            XCTAssertEqual(store.read().availability, .ready)
            XCTAssertEqual(store.read().likedSongs.map(\.id), ["new"])
            XCTAssertEqual(store.read().accent, .teal)
            XCTAssertEqual(try Data(contentsOf: file), externalBytes)
            XCTAssertEqual(reloads, 3)
            XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            XCTAssertEqual(reloads, 3)
        }
    }

    func testDirectValidationImmediatelyRedactsExternalClearOrDisableWithoutLifecycleRefresh() async throws {
        for clearHistory in [true, false] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let device = harness.device()
            let library = device.library
            let recent = WidgetSnapshotTestData.artworkTrack("private-recent")
            library.recordRecent(track: recent, position: 9)
            library.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [WidgetSnapshotTestData.artworkTrack("private-mix")],
                                              generatedAt: LibrarySyncTestData.now, periodKey: "day", seedArtists: []))
            let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
            let image = WidgetSnapshotTestData.jpeg()
            var reloads = 0
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in image }) { reloads += 1 }
            try await PlaybackTestSupport.eventually { store.read().artwork.count == 2 }
            let baselineReloads = reloads
            var notifications = 0
            let publicationCallback = library.onWidgetLibraryChange
            library.onWidgetLibraryChange = {
                notifications += 1
                publicationCallback?()
            }
            let external = LibraryStore(directory: device.directory, now: { LibrarySyncTestData.now })
            if clearHistory { external.clearHistory() }
            else { external.preferences.saveListeningHistory = false }
            XCTAssertNil(external.errorMessage)
            let externalBytes = try Data(contentsOf: device.fileURL)
            XCTAssertEqual(store.read().artwork.count, 2)

            XCTAssertFalse(library.validateWidgetLibrarySource())

            let redacted = store.read()
            XCTAssertEqual(redacted.availability, .unavailable)
            XCTAssertTrue(redacted.displayedTracks.isEmpty)
            XCTAssertTrue(redacted.artwork.isEmpty)
            XCTAssertEqual(notifications, 1)
            XCTAssertEqual(reloads, baselineReloads + 1)
            let redactedBytes = try Data(contentsOf: XCTUnwrap(store.fileURL))
            for index in 1...3 {
                XCTAssertFalse(library.validateWidgetLibrarySource())
                library.recordRecent(track: recent, position: Double(index))
                XCTAssertFalse(library.recordTip(transactionID: UInt64(index), credited: true))
            }
            XCTAssertEqual(notifications, 1)
            XCTAssertEqual(reloads, baselineReloads + 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL)), redactedBytes)
            XCTAssertEqual(try Data(contentsOf: device.fileURL), externalBytes)
            withExtendedLifetime(publisher) { }
        }
    }

    func testRefreshCoalescesTransitionNotificationAndReentrantRefreshIntoOnePublication() throws {
        try withLibraryTestDirectory { directory in
            let libraryDirectory = directory.appendingPathComponent("library")
            let library = LibraryStore(directory: libraryDirectory, now: { RecommendationFixtures.now })
            library.recordRecent(track: libraryTestTrack("private-recent"), position: 9)
            let observedFiles = CatalogTestRecorder<WidgetLibrarySnapshot>()
            let fileSystem = WidgetSnapshotStore.FileSystem(excludeFromBackup: { url in
                if url.lastPathComponent == WidgetSnapshotStore.fileName {
                    observedFiles.record(try WidgetSnapshotStore.decode(Data(contentsOf: url)))
                }
                try WidgetSnapshotStore.FileSystem.live.excludeFromBackup(url)
            })
            let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets"), fileSystem: fileSystem)
            var reloads = 0
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
            XCTAssertEqual(observedFiles.values.count, 1)
            var notifications = 0
            let publicationCallback = library.onWidgetLibraryChange
            library.onWidgetLibraryChange = { [weak publisher] in
                notifications += 1
                publicationCallback?()
                publisher?.refresh()
            }
            let external = LibraryStore(directory: libraryDirectory, now: { RecommendationFixtures.now })
            external.clearHistory()
            XCTAssertNil(external.errorMessage)

            publisher.refresh()

            XCTAssertEqual(notifications, 1)
            XCTAssertEqual(observedFiles.values.count, 2, "The outer refresh owns the transition's publication")
            XCTAssertEqual(store.read().availability, .unavailable)
            XCTAssertTrue(store.read().displayedTracks.isEmpty)
            XCTAssertEqual(reloads, 2)
            publisher.refresh()
            XCTAssertEqual(notifications, 1)
            XCTAssertEqual(reloads, 2)
        }
    }

    func testRemoteMergePublishesAfterDurabilityPreservesCloudCallbackAndDoesNotEchoNoOpMerges() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let local = harness.device()
        let remote = harness.device(LibrarySyncTestData.b)
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        var reloads = 0
        var applied = 0
        var localSyncChanges = 0
        var clears = 0
        local.library.onSyncChange = { localSyncChanges += 1 }
        local.library.onHistoryCleared = { clears += 1 }
        local.library.onCloudSyncApplied = { [weak local] _, _ in
            guard let local else { return }
            applied += 1
            XCTAssertEqual(store.read().likedSongs.map(\.id), local.library.favorites.prefix(6).map(\.id))
            XCTAssertEqual(try? local.saved().preferences, local.library.preferences)
        }
        let publisher = WidgetSnapshotPublisher(library: local.library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
        remote.library.toggleFavorite(libraryTestTrack("remote-liked"))
        remote.library.recordRecent(track: libraryTestTrack("remote-recent"), position: 7)
        remote.library.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [libraryTestTrack("remote-mixed")],
                                                 generatedAt: LibrarySyncTestData.now, periodKey: "day", seedArtists: []))
        remote.library.preferences.accent = .mint
        XCTAssertTrue(try local.library.mergeCloudState(remote.state()))
        XCTAssertEqual(store.read().likedSongs.map(\.id), ["remote-liked"])
        XCTAssertEqual(store.read().recentlyPlayed.map(\.id), ["remote-recent"])
        XCTAssertEqual(store.read().mixes.first?.tracks.map(\.id), ["remote-mixed"])
        XCTAssertEqual(store.read().accent, .mint)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(localSyncChanges, 0)
        XCTAssertEqual(reloads, 2)
        XCTAssertFalse(try local.library.mergeCloudState(remote.state()))
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(reloads, 2)
        remote.library.clearHistory()
        XCTAssertTrue(try local.library.mergeCloudState(remote.state()))
        XCTAssertTrue(store.read().recentlyPlayed.isEmpty)
        XCTAssertTrue(store.read().mixes.isEmpty)
        XCTAssertEqual(store.read().likedSongs.map(\.id), ["remote-liked"])
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(applied, 2)
        XCTAssertEqual(reloads, 3)
        withExtendedLifetime(publisher) { }
    }

    func testFailedRemoteMergeCannotPublishIncomingCandidateAndRetryUsesDurableMergedState() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let local = harness.device()
        let remote = harness.device(LibrarySyncTestData.b)
        local.library.toggleFavorite(libraryTestTrack("local"))
        remote.library.toggleFavorite(libraryTestTrack("remote"))
        let incoming = try remote.state()
        let store = WidgetSnapshotStore(directory: harness.root.appendingPathComponent("widgets"))
        var reloads = 0
        var applied = 0
        local.library.onCloudSyncApplied = { _, _ in applied += 1 }
        let publisher = WidgetSnapshotPublisher(library: local.library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
        let backup = local.directory.appendingPathComponent("backup.json")
        try FileManager.default.moveItem(at: local.fileURL, to: backup)
        try FileManager.default.createDirectory(at: local.fileURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try local.library.mergeCloudState(incoming))

        XCTAssertEqual(local.library.favorites.map(\.id), ["local"])
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(store.read().availability, .unavailable)
        XCTAssertTrue(store.read().displayedTracks.isEmpty)
        XCTAssertEqual(reloads, 2)
        try FileManager.default.removeItem(at: local.fileURL)
        try FileManager.default.moveItem(at: backup, to: local.fileURL)
        XCTAssertTrue(try local.library.mergeCloudState(incoming))
        XCTAssertEqual(Set(store.read().likedSongs.map(\.id)), ["local", "remote"])
        XCTAssertEqual(store.read().availability, .ready)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(reloads, 3)
        withExtendedLifetime(publisher) { }
    }

    func testRemovingAnOffscreenLikeStillPublishesItsFullCountChange() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory.appendingPathComponent("library"))
            for index in (0..<8).reversed() { library.toggleFavorite(libraryTestTrack("song-\(index)")) }
            let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets"))
            var reloads = 0
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
            let displayed = store.read().likedSongs
            XCTAssertEqual(displayed.count, 6)
            XCTAssertEqual(store.read().likedSongCount, 8)
            library.toggleFavorite(libraryTestTrack("song-7"))
            XCTAssertEqual(store.read().likedSongs, displayed)
            XCTAssertEqual(store.read().likedSongCount, 7)
            XCTAssertEqual(reloads, 2)
            withExtendedLifetime(publisher) { }
        }
    }

    func testUnavailableStartupRedactsOldProjectionAndRepairRequiresValidatedReload() throws {
        try withLibraryTestDirectory { directory in
            let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets"))
            XCTAssertTrue(try store.write(WidgetSnapshotTestData.snapshot().withArtwork(["song-a": WidgetSnapshotTestData.jpeg()])))
            let libraryDirectory = directory.appendingPathComponent("library")
            let file = libraryDirectory.appendingPathComponent(LibraryPersistence.fileName)
            let future = Data("{\"version\":9999,\"keep\":true}".utf8)
            try LibraryPersistence.write(future, to: file, replacing: nil)
            let library = LibraryStore(directory: libraryDirectory)
            var reloads = 0
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
            XCTAssertEqual(store.read().availability, .unavailable)
            XCTAssertTrue(store.read().displayedTracks.isEmpty)
            XCTAssertTrue(store.read().artwork.isEmpty)
            XCTAssertEqual(try Data(contentsOf: file), future)
            var repaired = LibraryDocument()
            repaired.favorites = [libraryTestTrack("repaired")]
            let repairedBytes = try LibraryPersistence.encode(repaired)
            try repairedBytes.write(to: file, options: .atomic)
            publisher.refresh()
            XCTAssertEqual(store.read().availability, .unavailable)
            XCTAssertEqual(reloads, 1)
            XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            XCTAssertEqual(store.read().likedSongs.map(\.id), ["repaired"])
            XCTAssertEqual(try Data(contentsOf: file), repairedBytes)
            XCTAssertEqual(reloads, 2)
        }
    }

    func testMissingGroupNeverClaimsPublicationOrRequestsReload() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.toggleFavorite(WidgetSnapshotTestData.artworkTrack("saved"))
            var reloads = 0
            let store = WidgetSnapshotStore(directory: nil)
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in
                XCTFail("A failed metadata publication must not start thumbnail work")
                return nil
            }) { reloads += 1 }
            library.toggleFavorite(libraryTestTrack("other"))
            publisher.refresh()
            XCTAssertEqual(reloads, 0)
            XCTAssertEqual(store.read().availability, .unavailable)
            XCTAssertNil(store.fileURL)
        }
    }

    func testFutureWidgetFileIsPreservedAndOnlyAnExplicitFixtureResetPermitsRetry() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory.appendingPathComponent("library"))
            library.toggleFavorite(libraryTestTrack("saved"))
            let cacheDirectory = directory.appendingPathComponent("widgets")
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let store = WidgetSnapshotStore(directory: cacheDirectory)
            let url = try XCTUnwrap(store.fileURL)
            let future = Data("{\"version\":2,\"keep\":true}".utf8)
            try future.write(to: url, options: .atomic)
            var reloads = 0
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
            publisher.refresh()
            library.toggleFavorite(libraryTestTrack("also-saved"))
            XCTAssertEqual(reloads, 0)
            XCTAssertEqual(try Data(contentsOf: url), future)
            XCTAssertEqual(store.read().availability, .unavailable)
            try FileManager.default.removeItem(at: url)
            publisher.refresh()
            XCTAssertEqual(store.read().likedSongs.map(\.id), ["also-saved", "saved"])
            XCTAssertEqual(reloads, 1)
            publisher.refresh()
            XCTAssertEqual(reloads, 1)
        }
    }

    func testFailedSnapshotWriteDoesNotClaimReloadAndRetriesLatestDurableSource() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory.appendingPathComponent("library"))
            library.toggleFavorite(libraryTestTrack("first"))
            let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets"))
            var reloads = 0
            let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
            let url = try XCTUnwrap(store.fileURL)
            let backup = directory.appendingPathComponent("widget-backup.json")
            try FileManager.default.moveItem(at: url, to: backup)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            library.toggleFavorite(libraryTestTrack("second"))
            XCTAssertEqual(library.favorites.map(\.id), ["second", "first"])
            XCTAssertEqual(reloads, 1)
            XCTAssertEqual(store.read().availability, .unavailable)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: backup, to: url)
            publisher.refresh()
            XCTAssertEqual(store.read().likedSongs.map(\.id), ["second", "first"])
            XCTAssertEqual(reloads, 2)
            publisher.refresh()
            XCTAssertEqual(reloads, 2)
        }
    }

    func testPostWriteFailuresOweExactlyOneReloadAfterAnIdenticalSuccessfulRetry() throws {
        for alreadyPublished in [false, true] {
            try withLibraryTestDirectory { directory in
                let library = LibraryStore(directory: directory.appendingPathComponent("library"))
                library.toggleFavorite(libraryTestTrack("saved"))
                let attempts = CatalogTestCounter()
                let observedFiles = CatalogTestRecorder<WidgetLibrarySnapshot>()
                let firstFailure = alreadyPublished ? 2 : 1
                let fileSystem = WidgetSnapshotStore.FileSystem(excludeFromBackup: { url in
                    if url.lastPathComponent == WidgetSnapshotStore.fileName {
                        observedFiles.record(try WidgetSnapshotStore.decode(Data(contentsOf: url)))
                        let attempt = attempts.increment()
                        if (firstFailure...firstFailure + 1).contains(attempt) { throw CocoaError(.fileWriteNoPermission) }
                    }
                    try WidgetSnapshotStore.FileSystem.live.excludeFromBackup(url)
                })
                let store = WidgetSnapshotStore(directory: directory.appendingPathComponent("widgets"), fileSystem: fileSystem)
                var reloads = 0
                var afterReload: (@MainActor () -> Void)?
                let publisher = WidgetSnapshotPublisher(library: library, store: store, thumbnail: { _ in nil }) {
                    reloads += 1
                    afterReload?()
                }
                let baselineReloads = alreadyPublished ? 1 : 0
                if alreadyPublished { library.toggleFavorite(libraryTestTrack("new-saved")) }
                XCTAssertEqual(reloads, baselineReloads)
                let expectedIDs = alreadyPublished ? ["new-saved", "saved"] : ["saved"]
                XCTAssertEqual(observedFiles.values.last?.likedSongs.map(\.id), expectedIDs)
                XCTAssertEqual(store.read().likedSongs.map(\.id), expectedIDs)
                let url = try XCTUnwrap(store.fileURL)
                let bytesAfterFailedPublication = try Data(contentsOf: url)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

                publisher.refresh()
                XCTAssertEqual(reloads, baselineReloads)
                XCTAssertEqual(try Data(contentsOf: url), bytesAfterFailedPublication)
                afterReload = { [weak publisher] in
                    if reloads == baselineReloads + 1 { publisher?.refresh() }
                }
                publisher.refresh()

                XCTAssertEqual(reloads, baselineReloads + 1)
                XCTAssertEqual(store.read().likedSongs.map(\.id), expectedIDs)
                XCTAssertEqual(try Data(contentsOf: url), bytesAfterFailedPublication)
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber,
                               attributes[.systemFileNumber] as? NSNumber)
                for _ in 1...3 { publisher.refresh() }
                library.updatePlayback(PlaybackSnapshot(queue: library.favorites, position: 9))
                XCTAssertEqual(reloads, baselineReloads + 1)
                XCTAssertEqual(try Data(contentsOf: url), bytesAfterFailedPublication)
            }
        }
    }
}
