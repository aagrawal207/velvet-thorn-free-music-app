import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySyncPersistenceTests: XCTestCase {
    func testLegacyMigrationSeedsPopulatedRecordsAndOnlyNondefaultPreferences() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let directory = harness.root.appendingPathComponent("legacy")
        var legacy = LibraryDocument()
        legacy.version = 1
        legacy.favorites = [libraryTestTrack("legacy")]
        legacy.preferences.appearance = .light
        legacy.recentSearches = ["Newest", "Older"]
        legacy.playback = PlaybackSnapshot(queue: [libraryTestTrack("local-queue")], position: 19)
        let bytes = try LibrarySyncTestData.legacyDocumentBytes(legacy)
        let url = directory.appendingPathComponent(LibraryPersistence.fileName)
        try LibraryPersistence.write(bytes, to: url, replacing: nil)
        let library = LibraryStore(directory: directory, now: { LibrarySyncTestData.now }, writerID: LibrarySyncTestData.a)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let state = try library.cloudReplica(replicaID: LibrarySyncTestData.a).state
        XCTAssertEqual(state.registers.keys.filter { $0.collection == .preference }.map(\.id), ["appearance"])
        XCTAssertEqual(library.recentSearches, ["Newest", "Older"])
        XCTAssertEqual(library.playback.position, 19)
        XCTAssertEqual(try LibraryPersistence.decode(Data(contentsOf: url), now: LibrarySyncTestData.now).version, LibraryPersistence.currentVersion)

        let empty = harness.device(LibrarySyncTestData.b)
        XCTAssertTrue(try empty.state().registers.isEmpty)
        try library.mergeCloudState(empty.state())
        XCTAssertEqual(library.preferences.appearance, .light)
        XCTAssertEqual(library.favorites.map(\.id), ["legacy"])
        try empty.library.mergeCloudState(state)
        XCTAssertEqual(empty.library.preferences.appearance, .light)
        XCTAssertTrue(empty.library.playback.queue.isEmpty)
    }

    func testEveryCodablePreferenceFieldIncludingAppIconTravelsWithoutAManualAllowlist() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        var preferences = UserPreferences()
        preferences.languages = [.english]
        preferences.appearance = .light
        preferences.accent = try XCTUnwrap(AppAccent.allCases.first { $0 != preferences.accent })
        preferences.hasCompletedWelcome = true
        preferences.saveListeningHistory = false
        preferences.allowRemoteFallback = true
        preferences.useEncryptedDNS = false
        preferences.crossfadeSeconds = 3.25
        preferences.gaplessPlayback = false
        preferences.automix = false
        preferences.autoplay = false
        preferences.normalizeVolume = false
        preferences.newReleaseAlerts = false
        preferences.audioCacheLimit = try XCTUnwrap(AudioCacheLimit.allCases.first { $0 != preferences.audioCacheLimit })
        preferences.homeLayout.setVisible(false, for: .charts)
        preferences.homeLayout.move(from: IndexSet(integer: 0), to: 3)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibrarySyncCodec.encode(preferences)) as? [String: Any])
        json["appIconID"] = "Sonnet"
        preferences = try LibrarySyncCodec.decode(UserPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        a.library.preferences = preferences
        try b.library.mergeCloudState(a.state())
        XCTAssertEqual(b.library.preferences, preferences)
        let fields = try LibrarySyncPreferences.fields(b.library.preferences)
        XCTAssertEqual(fields["appIconID"], Data("\"Sonnet\"".utf8), "The coordinator's Codable appIconID is part of the generic projection")
        XCTAssertEqual(fields, try LibrarySyncPreferences.fields(a.library.preferences))
        XCTAssertEqual(try b.saved().preferences, preferences)
    }

    func testPlayerQualityEqualizerAndSourceFieldsFlattenIntoSlashFreeLeavesAndTravelBetweenDevices() throws {
        let defaults = try LibrarySyncPreferences.fields(UserPreferences())
        let paths = ["trailingTimeStyle", "audioQuality", "equalizer/isEnabled", "equalizer/preset", "equalizer/gains",
                     "equalizer/preamp", "downloadsOverCellular", "autoDownloadLikedSongs", "enabledCatalogSources",
                     "sponsorBlockSkipping"]
        for path in paths { XCTAssertNotNil(defaults[path], path) }
        XCTAssertNil(defaults["equalizer"], "Nested settings flatten into one register per leaf")
        XCTAssertTrue(defaults.keys.allSatisfy { key in
            key.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
        })
        XCTAssertEqual(defaults["trailingTimeStyle"], Data("\"songLength\"".utf8))
        XCTAssertEqual(defaults["audioQuality"], Data("\"best\"".utf8))
        XCTAssertEqual(defaults["equalizer/isEnabled"], Data("false".utf8))
        XCTAssertEqual(defaults["equalizer/preset"], Data("\"flat\"".utf8))
        XCTAssertEqual(defaults["equalizer/gains"], Data("[0,0,0,0,0,0,0,0,0,0]".utf8), "Gains stay one ordered leaf")
        XCTAssertEqual(defaults["equalizer/preamp"], Data("0".utf8))
        XCTAssertEqual(defaults["enabledCatalogSources"], Data(#"["youtube","saavn","gaana"]"#.utf8))

        var preferences = UserPreferences()
        preferences.trailingTimeStyle = .remaining
        preferences.audioQuality = .balanced
        preferences.equalizer = EqualizerSettings(isEnabled: true, preset: .custom,
                                                  gains: [-12, -6, -3, -1.5, 0, 0.5, 1.5, 3, 6, 12], preamp: -4.5)
        preferences.downloadsOverCellular = true
        preferences.autoDownloadLikedSongs = true
        preferences.enabledCatalogSources = [.gaana, .youTubeMusic]
        preferences.sponsorBlockSkipping = true
        let fields = try LibrarySyncPreferences.fields(preferences)
        XCTAssertEqual(fields["equalizer/preset"], Data("\"custom\"".utf8))
        XCTAssertEqual(fields["equalizer/gains"], Data("[-12,-6,-3,-1.5,0,0.5,1.5,3,6,12]".utf8))
        XCTAssertEqual(fields["enabledCatalogSources"], Data(#"["gaana","youtube"]"#.utf8), "Order is part of the register value")
        XCTAssertEqual(fields.filter { defaults[$0.key] != $0.value }.keys.sorted(), paths.sorted())
        XCTAssertEqual(try LibrarySyncPreferences.applying(fields, to: UserPreferences()), preferences)
        let partial = fields.filter { $0.key.hasPrefix("equalizer/") }
        var expected = UserPreferences()
        expected.equalizer = preferences.equalizer
        XCTAssertEqual(try LibrarySyncPreferences.applying(partial, to: UserPreferences()), expected)

        // A remote value the lenient decoder would rewrite is refused like every other clamped preference.
        XCTAssertThrowsError(try LibrarySyncPreferences.applying(["equalizer/gains": Data("[99,0,0,0,0,0,0,0,0,0]".utf8)], to: UserPreferences()))
        XCTAssertThrowsError(try LibrarySyncPreferences.applying(["equalizer/gains": Data("[0,0,0]".utf8)], to: UserPreferences()))
        XCTAssertThrowsError(try LibrarySyncPreferences.applying(["equalizer/preset": Data("\"future-preset\"".utf8)], to: UserPreferences()))
        XCTAssertThrowsError(try LibrarySyncPreferences.applying(["enabledCatalogSources": Data(#"["spotify"]"#.utf8)], to: UserPreferences()))
        XCTAssertThrowsError(try LibrarySyncPreferences.applying(["equalizer/bands": Data("[]".utf8)], to: UserPreferences()))

        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.preferences = preferences
        XCTAssertNil(a.library.errorMessage)
        XCTAssertEqual(Set(try a.state().registers.keys.filter { $0.collection == .preference }.map(\.id)), Set(paths))
        try b.library.mergeCloudState(a.state())
        XCTAssertEqual(b.library.preferences, preferences)
        XCTAssertEqual(try b.saved().preferences, preferences)
        XCTAssertEqual(try LibrarySyncPreferences.fields(b.library.preferences), fields)
    }

    func testConcurrentLikesAndDifferentPreferencesSurviveBothDirections() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.preferences.appearance = .light
        b.library.preferences.useEncryptedDNS = false
        a.library.toggleFavorite(libraryTestTrack("a"))
        b.library.toggleFavorite(libraryTestTrack("b"))
        let aOffline = try a.state()
        let bOffline = try b.state()
        try a.library.mergeCloudState(bOffline)
        try b.library.mergeCloudState(aOffline)
        XCTAssertEqual(Set(a.library.favorites.map(\.id)), ["a", "b"])
        XCTAssertEqual(Set(b.library.favorites.map(\.id)), ["a", "b"])
        XCTAssertEqual(a.library.preferences.appearance, .light)
        XCTAssertFalse(a.library.preferences.useEncryptedDNS)
        XCTAssertEqual(a.library.preferences, b.library.preferences)
        XCTAssertEqual(try a.state(), try b.state())
    }

    func testOnlyTheChangedFieldGetsANewRevisionAndClockRollbackSurvivesRestart() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.toggleFavorite(libraryTestTrack())
        a.library.preferences.appearance = .light
        let before = try a.state()
        harness.clock.advance(by: -3600)
        let clock = harness.clock
        let restarted = LibraryStore(directory: a.directory, now: { clock.now }, writerID: LibrarySyncTestData.c)
        restarted.preferences.appearance = .dark
        let after = try restarted.cloudReplica(replicaID: a.id).state
        XCTAssertEqual(after.registers[LibrarySyncKey(.reaction, "song-a")], before.registers[LibrarySyncKey(.reaction, "song-a")])
        XCTAssertGreaterThan(try XCTUnwrap(after.clock), try XCTUnwrap(before.clock))
        XCTAssertEqual(after.clock?.milliseconds, before.clock?.milliseconds)
        XCTAssertEqual(after.clock?.writer, LibrarySyncTestData.c)
        XCTAssertEqual(try a.saved().syncState, after)
        XCTAssertEqual(restarted.preferences.appearance, .dark, "An explicit reset to the default is a real edit")
    }

    func testPlaylistConcurrentAddRenameAndReorderMergeIndependently() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let id = a.library.createPlaylist(name: "Original")
        a.library.add(libraryTestTrack("first"), to: id)
        a.library.add(libraryTestTrack("second"), to: id)
        try b.library.mergeCloudState(a.state())
        a.library.renamePlaylist(id: id, name: "Renamed")
        a.library.add(libraryTestTrack("from-a"), to: id)
        b.library.moveTracks(in: id, from: IndexSet(integer: 1), to: 0)
        b.library.add(libraryTestTrack("from-b"), to: id)
        let aOffline = try a.state()
        let bOffline = try b.state()
        try a.library.mergeCloudState(bOffline)
        try b.library.mergeCloudState(aOffline)
        let playlist = try XCTUnwrap(a.library.playlists.first)
        XCTAssertEqual(playlist.name, "Renamed")
        XCTAssertEqual(Array(playlist.tracks.prefix(2)).map(\.id), ["second", "first"])
        XCTAssertEqual(Set(playlist.tracks.map(\.id)), ["first", "second", "from-a", "from-b"])
        XCTAssertEqual(a.library.playlists, b.library.playlists)
        XCTAssertEqual(try a.saved().playlists, a.library.playlists)
    }

    func testTrackRemovalSurvivesAStaleReorderAndCanBeExplicitlyReaddedAtTheEnd() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let id = a.library.createPlaylist(name: "Songs")
        for name in ["a", "b", "c"] { a.library.add(libraryTestTrack(name), to: id) }
        let baseline = try a.state()
        try b.library.mergeCloudState(baseline)
        a.library.remove(trackID: "b", from: id)
        harness.clock.advance(by: 60)
        b.library.moveTracks(in: id, from: IndexSet(integer: 1), to: 0)
        b.library.add(libraryTestTrack("d"), to: id)
        let removed = try a.state()
        let reordered = try b.state()
        try a.library.mergeCloudState(reordered)
        try b.library.mergeCloudState(removed)
        XCTAssertEqual(a.library.playlists.first?.tracks.map(\.id), ["a", "c", "d"])
        XCTAssertEqual(a.library.playlists, b.library.playlists)
        try a.library.mergeCloudState(baseline)
        XCTAssertFalse(a.library.playlists[0].tracks.contains { $0.id == "b" })
        a.library.add(libraryTestTrack("b"), to: id)
        try b.library.mergeCloudState(a.state())
        XCTAssertEqual(b.library.playlists.first?.tracks.last?.id, "b")
    }

    func testDeletedPlaylistCannotBeResurrectedByAnOfflineEditWithALaterClock() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let id = a.library.createPlaylist(name: "Delete me")
        a.library.add(libraryTestTrack(), to: id)
        let baseline = try a.state()
        try b.library.mergeCloudState(baseline)
        a.library.deletePlaylist(id: id)
        harness.clock.advance(by: 10_000)
        b.library.renamePlaylist(id: id, name: "Late offline rename")
        b.library.add(libraryTestTrack("late"), to: id)
        let deletion = try a.state()
        try a.library.mergeCloudState(b.state())
        try b.library.mergeCloudState(deletion)
        XCTAssertTrue(a.library.playlists.isEmpty)
        XCTAssertTrue(b.library.playlists.isEmpty)
        try a.library.mergeCloudState(baseline)
        XCTAssertTrue(a.library.playlists.isEmpty)
        XCTAssertNotNil(try a.state().registers[LibrarySyncKey(.playlist, id.uuidString)])
        XCTAssertNil(try a.state().registers[LibrarySyncKey(.playlist, id.uuidString)]?.value)
    }

    func testReactionUndoLanguageUndoLyricsZeroAndUnfollowSurviveStaleReplicas() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let song = libraryTestTrack()
        a.library.toggleFavorite(song)
        a.library.setLyricsOffset(-1.125, for: song.id)
        XCTAssertTrue(a.library.setRecordingLanguageOverride("hi", for: song.id))
        a.library.follow(FollowedArtist(id: "artist", name: "Artist", followedAt: LibrarySyncTestData.now))
        let baseline = try a.state()
        try b.library.mergeCloudState(baseline)
        a.library.toggleDislike(song)
        a.library.setLyricsOffset(0, for: song.id)
        XCTAssertTrue(a.library.setRecordingLanguageOverride(nil, for: song.id))
        a.library.unfollow(artistID: "artist")
        harness.clock.advance(by: 60)
        XCTAssertTrue(b.library.recordReleaseCheck(artistID: "artist", knownReleaseIDs: ["release"], newReleases: [], checkedAt: harness.clock.now))
        let changes = try a.state()
        try a.library.mergeCloudState(b.state())
        try b.library.mergeCloudState(changes)
        for store in [a.library, b.library] {
            XCTAssertFalse(store.isFavorite(song))
            XCTAssertTrue(store.isDisliked(song))
            XCTAssertEqual(store.lyricsOffset(for: song.id), 0)
            XCTAssertNil(store.recordingLanguageOverrides[song.id])
            XCTAssertFalse(store.isFollowing(artistID: "artist"))
            try store.mergeCloudState(baseline)
            XCTAssertFalse(store.isFavorite(song))
            XCTAssertEqual(store.lyricsOffset(for: song.id), 0)
        }
        a.library.toggleDislike(song)
        try b.library.mergeCloudState(a.state())
        XCTAssertFalse(b.library.isDisliked(song))
    }

    func testRemoteMergePreservesDeviceOnlyDataAndNeverEnqueuesRemoteAlerts() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let artist = FollowedArtist(id: "artist", name: "Artist", followedAt: LibrarySyncTestData.now, knownReleaseIDs: ["old"])
        for store in [a.library, b.library] { store.follow(artist) }
        let localRelease = ArtistRelease(id: "local", title: "Local", subtitle: "", artistID: artist.id,
                                        artistName: artist.name, discoveredAt: LibrarySyncTestData.now)
        let remoteRelease = ArtistRelease(id: "remote", title: "Remote", subtitle: "", artistID: artist.id,
                                         artistName: artist.name, discoveredAt: LibrarySyncTestData.now)
        XCTAssertTrue(a.library.recordReleaseCheck(artistID: artist.id, knownReleaseIDs: ["local"], newReleases: [localRelease], checkedAt: LibrarySyncTestData.now))
        XCTAssertTrue(b.library.recordReleaseCheck(artistID: artist.id, knownReleaseIDs: ["remote"], newReleases: [remoteRelease], checkedAt: LibrarySyncTestData.now))
        a.library.updatePlayback(PlaybackSnapshot(queue: [libraryTestTrack("local-queue")], position: 43))
        b.library.updatePlayback(PlaybackSnapshot(queue: [libraryTestTrack("remote-queue")], position: 81))
        XCTAssertTrue(a.library.recordTip(transactionID: 11, credited: true))
        XCTAssertTrue(b.library.recordTip(transactionID: 22, credited: true))
        try a.library.mergeCloudState(b.state())
        XCTAssertEqual(a.library.playback.queue.map(\.id), ["local-queue"])
        XCTAssertEqual(a.library.playback.position, 43)
        XCTAssertEqual(a.library.tipCredit(for: 11), true)
        XCTAssertNil(a.library.tipCredit(for: 22))
        XCTAssertEqual(a.library.pendingReleaseNotifications.map(\.id), ["local"])
        XCTAssertEqual(Set(a.library.releases.map(\.id)), ["local", "remote"])
        let payload = String(decoding: try LibrarySyncCodec.encodeReplica(a.library.cloudReplica(replicaID: a.id)), as: UTF8.self)
        for excluded in ["playback", "tipTransactions", "pendingReleaseNotificationIDs", "boundAccount"] {
            XCTAssertFalse(payload.contains("\"\(excluded)\""))
        }
        b.library.preferences.newReleaseAlerts = false
        try a.library.mergeCloudState(b.state())
        XCTAssertTrue(a.library.pendingReleaseNotifications.isEmpty)
    }

    func testRemoteNoOpDoesNotWriteOrEchoAndCallbackReceivesPreviousPreferencesAfterDurability() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.preferences.appearance = .light
        var localChanges = 0
        var applied: [UserPreferences] = []
        b.library.onSyncChange = { localChanges += 1 }
        b.library.onCloudSyncApplied = { [weak b] previous, _ in
            applied.append(previous)
            XCTAssertEqual(try? b?.saved().preferences.appearance, .light)
        }
        XCTAssertTrue(try b.library.mergeCloudState(a.state()))
        XCTAssertEqual(applied.map(\.appearance), [.dark])
        XCTAssertEqual(localChanges, 0)
        let saved = try Data(contentsOf: b.fileURL)
        XCTAssertFalse(try b.library.mergeCloudState(a.state()))
        XCTAssertEqual(try Data(contentsOf: b.fileURL), saved)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(localChanges, 0)
    }

    func testFailedRemoteWriteDoesNotApplyOrAcknowledgeAndRetryKeepsLocalEdits() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.toggleFavorite(libraryTestTrack("a"))
        b.library.toggleFavorite(libraryTestTrack("b"))
        b.library.preferences.appearance = .light
        let backup = a.directory.appendingPathComponent("backup.json")
        let original = try Data(contentsOf: a.fileURL)
        try FileManager.default.moveItem(at: a.fileURL, to: backup)
        try FileManager.default.createDirectory(at: a.fileURL, withIntermediateDirectories: false)
        var callbacks = 0
        a.library.onCloudSyncApplied = { _, _ in callbacks += 1 }
        XCTAssertThrowsError(try a.library.mergeCloudState(b.state()))
        XCTAssertEqual(a.library.favorites.map(\.id), ["a"])
        XCTAssertEqual(a.library.preferences.appearance, .dark)
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        try FileManager.default.removeItem(at: a.fileURL)
        try FileManager.default.moveItem(at: backup, to: a.fileURL)
        XCTAssertTrue(try a.library.mergeCloudState(b.state()))
        XCTAssertEqual(Set(a.library.favorites.map(\.id)), ["a", "b"])
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(try a.saved().preferences.appearance, .light)
    }

    func testCorruptFutureAndRepairedPlaceholdersCannotBeOverwrittenBySync() throws {
        let invalids = [Data("{broken".utf8), Data("{\"version\":9999,\"keep\":true}".utf8)]
        for invalid in invalids {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let directory = harness.root.appendingPathComponent("broken")
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(invalid, to: url, replacing: nil)
            let broken = LibraryStore(directory: directory)
            let remote = harness.device()
            remote.library.toggleFavorite(libraryTestTrack("remote"))
            XCTAssertThrowsError(try broken.mergeCloudState(remote.state()))
            XCTAssertEqual(try Data(contentsOf: url), invalid)
            var repaired = LibraryDocument()
            repaired.playback = PlaybackSnapshot(queue: [libraryTestTrack("recovered")], position: 55)
            let repairedBytes = try LibraryPersistence.encode(repaired)
            try repairedBytes.write(to: url, options: .atomic)
            XCTAssertThrowsError(try broken.cloudReplica(replicaID: LibrarySyncTestData.b))
            XCTAssertThrowsError(try broken.mergeCloudState(remote.state()))
            XCTAssertTrue(broken.requiresReload)
            XCTAssertEqual(try Data(contentsOf: url), repairedBytes)
        }
    }

    func testExternallyChangedAndInconsistentJournalsRemainBlockedUntilExplicitRecovery() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.toggleFavorite(libraryTestTrack("saved"))
        let external = LibraryStore(directory: a.directory, now: { LibrarySyncTestData.now })
        external.preferences.appearance = .light
        let changed = try Data(contentsOf: a.fileURL)
        XCTAssertThrowsError(try a.library.mergeCloudState(LibrarySyncState()))
        XCTAssertTrue(a.library.requiresReload)
        XCTAssertEqual(try Data(contentsOf: a.fileURL), changed)
        XCTAssertEqual(a.library.reloadFromDisk(), .reloaded)
        XCTAssertNoThrow(try a.library.cloudReplica(replicaID: a.id))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: changed) as? [String: Any])
        json["favorites"] = []
        let inconsistent = try JSONSerialization.data(withJSONObject: json)
        try inconsistent.write(to: a.fileURL, options: .atomic)
        let reopened = LibraryStore(directory: a.directory)
        XCTAssertTrue(reopened.requiresReload)
        XCTAssertThrowsError(try reopened.cloudReplica(replicaID: a.id))
        XCTAssertEqual(try Data(contentsOf: a.fileURL), inconsistent)
    }

    func testPreparedMergeRejectsNewSharedEditsButRebasesNewPlaybackAndTipCheckpoints() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.toggleFavorite(libraryTestTrack("a"))
        b.library.preferences.appearance = .light
        XCTAssertTrue(b.library.recordListening(track: libraryTestTrack("remote-listen"), sessionID: UUID(),
                                               startedAt: LibrarySyncTestData.now, seconds: 15))
        let prepared = try await a.library.prepareCloudMerge(b.state())
        XCTAssertTrue(prepared.lifetimeChanged)
        XCTAssertEqual(prepared.lifetimePublication?.summary.seconds, 15)
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 0)
        a.library.updatePlayback(PlaybackSnapshot(queue: [libraryTestTrack("live")], position: 7))
        XCTAssertTrue(a.library.recordTip(transactionID: 123, credited: true))
        XCTAssertTrue(try a.library.applyCloudMerge(prepared))
        XCTAssertEqual(a.library.playback.position, 7)
        XCTAssertEqual(a.library.tipCredit(for: 123), true)
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 15)
        b.library.preferences.useEncryptedDNS = false
        let stale = try await a.library.prepareCloudMerge(b.state())
        a.library.toggleFavorite(libraryTestTrack("new-edit"))
        let saved = try Data(contentsOf: a.fileURL)
        XCTAssertThrowsError(try a.library.applyCloudMerge(stale)) {
            XCTAssertEqual($0 as? LibrarySyncError, .localChangedDuringSync)
        }
        XCTAssertEqual(try Data(contentsOf: a.fileURL), saved)
        XCTAssertTrue(a.library.preferences.useEncryptedDNS)
    }

    func testUndoingAnOfflineDislikeKeepsTheDerivedMixAndJournalConsistentOnRestart() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let song = libraryTestTrack("disliked-offline")
        a.library.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [song, libraryTestTrack("other")],
                                            generatedAt: LibrarySyncTestData.now, periodKey: "day", seedArtists: []))
        b.library.toggleDislike(song)
        try a.library.mergeCloudState(b.state())
        XCTAssertEqual(a.library.mix(.dailyMix)?.tracks.map(\.id), ["other"])
        a.library.toggleDislike(song)
        XCTAssertNil(a.library.errorMessage)
        let restarted = LibraryStore(directory: a.directory, now: { LibrarySyncTestData.now })
        XCTAssertNil(restarted.errorMessage)
        XCTAssertEqual(restarted.mixes, a.library.mixes)
        XCTAssertFalse(restarted.isDisliked(song))
    }

    func testMergedReleaseRetentionStaysBoundedThroughSubsequentLocalChecks() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let artist = FollowedArtist(id: "artist", name: "Artist", followedAt: LibrarySyncTestData.now, knownReleaseIDs: ["baseline"])
        for device in [a, b] {
            device.library.follow(artist)
            let releases = (0..<60).map { index in
                ArtistRelease(id: "\(device.id)-\(index)", title: "Release \(index)", subtitle: "", artistID: artist.id,
                              artistName: artist.name, discoveredAt: LibrarySyncTestData.now)
            }
            XCTAssertTrue(device.library.recordReleaseCheck(artistID: artist.id, knownReleaseIDs: releases.map(\.id),
                                                            newReleases: releases, checkedAt: LibrarySyncTestData.now))
        }
        try a.library.mergeCloudState(b.state())
        XCTAssertEqual(a.library.releases.count, 60)
        XCTAssertEqual(try a.state().registers.filter { $0.key.collection == .release && $0.value.value != nil }.count, 60)
        let new = ArtistRelease(id: "new", title: "Newest", subtitle: "", artistID: artist.id, artistName: artist.name,
                                discoveredAt: LibrarySyncTestData.now.addingTimeInterval(1))
        XCTAssertTrue(a.library.recordReleaseCheck(artistID: artist.id, knownReleaseIDs: [new.id], newReleases: [new], checkedAt: new.discoveredAt))
        let restarted = LibraryStore(directory: a.directory, now: { LibrarySyncTestData.now })
        XCTAssertNil(restarted.errorMessage)
        XCTAssertEqual(restarted.releases.count, 60)
        XCTAssertTrue(restarted.releases.contains { $0.id == new.id })
    }

    func testInvalidLocalPreferenceDoesNotCreateAnUnopenableJournal() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.toggleFavorite(libraryTestTrack())
        let data = try Data(contentsOf: a.fileURL)
        a.library.preferences.crossfadeSeconds = 999
        XCTAssertNotNil(a.library.errorMessage)
        XCTAssertEqual(a.library.preferences.crossfadeSeconds, 0)
        XCTAssertEqual(try Data(contentsOf: a.fileURL), data)
        XCTAssertNoThrow(try a.saved())
    }
}
