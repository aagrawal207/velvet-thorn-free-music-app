import Foundation
import Observation
import XCTest
@testable import GanaBajana

@MainActor
final class LibraryObservationTests: XCTestCase {
    func testPlaybackOnlyInvalidatesPlayback() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let track = libraryTestTrack("observed")
            XCTAssertTrue(library.recordListening(track: track, sessionID: UUID(), startedAt: Date(), seconds: 5))
            let history = library.historyRevision
            let overrides = library.recordingLanguageOverridesRevision
            assertChanges(library, ["playback"]) {
                library.updatePlayback(PlaybackSnapshot(queue: [track], position: 12, originalQueue: [track]))
            }
            XCTAssertEqual(library.historyRevision, history)
            XCTAssertEqual(library.recordingLanguageOverridesRevision, overrides)
        }
    }

    func testListeningInvalidatesHistoryAndApplicableRecentOnly() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let track = libraryTestTrack("observed")
            let session = UUID()
            let started = Date()
            assertChanges(library, ["events", "historyRevision", "summary", "languageSummary"]) {
                XCTAssertTrue(library.recordListening(track: track, sessionID: session, startedAt: started, seconds: 5))
            }
            assertChanges(library, ["events", "historyRevision", "summary", "languageSummary", "recents"]) {
                XCTAssertTrue(library.recordListening(track: track, sessionID: session, startedAt: started,
                                                      seconds: 5, recentPosition: 10))
            }
            XCTAssertEqual(library.historyRevision, 2)
            assertChanges(library, ["recents"]) { library.recordRecent(track: track, position: 20) }
            XCTAssertEqual(library.historyRevision, 2)
        }
    }

    func testFavoriteAndPreferenceObserversReadDurableData() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let track = libraryTestTrack("observed")
            let favorite = ChangeProbe(read: { _ = library.isFavorite(track) }) {
                XCTAssertTrue(library.isFavorite(track))
                XCTAssertTrue(LibraryStore(directory: directory).isFavorite(track), "Notification must follow the disk write")
            }
            assertChanges(library, ["favorites", "isFavorite"]) { library.toggleFavorite(track) }
            XCTAssertEqual(favorite.count, 1)
            let preference = ChangeProbe(read: { _ = library.preferences }) {
                XCTAssertEqual(library.preferences.appearance, .light)
                XCTAssertEqual(LibraryStore(directory: directory).preferences.appearance, .light)
            }
            assertChanges(library, ["preferences", "pendingNotifications"]) { library.preferences.appearance = .light }
            XCTAssertEqual(preference.count, 1)
            assertChanges(library, []) { library.preferences.appearance = .light }
        }
    }

    func testRejectedWritesPublishNoDataOrRevisions() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let other = LibraryStore(directory: directory)
            other.toggleFavorite(libraryTestTrack("foreign"))
            assertChanges(library, []) { library.toggleFavorite(libraryTestTrack("observed")) }
            XCTAssertTrue(library.requiresReload)
            assertChanges(library, []) {
                library.preferences.appearance = .light
                XCTAssertFalse(library.recordListening(track: libraryTestTrack("observed"), sessionID: UUID(),
                                                       startedAt: Date(), seconds: 5, recentPosition: 5))
            }
            XCTAssertEqual(library.historyRevision, 0)
            XCTAssertEqual(library.durableCommitCount, 0)
            XCTAssertTrue(library.favorites.isEmpty)
        }
    }

    func testReloadPublishesEqualCountEqualSecondsHistoryAndOverrideReplacements() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            var document = LibraryDocument()
            document.events = [ListeningEvent(id: UUID(), track: libraryTestTrack("observed"), startedAt: now, listenedSeconds: 30)]
            document.recordingLanguageOverrides = ["observed": "hi"]
            let file = directory.appendingPathComponent(LibraryPersistence.fileName)
            var bytes = try LibraryPersistence.encode(document)
            try LibraryPersistence.write(bytes, to: file, replacing: nil)
            let library = LibraryStore(directory: directory, now: { now })
            let history = library.historyRevision
            let overrides = library.recordingLanguageOverridesRevision
            document.events[0].track.title = "Corrected title"
            document.recordingLanguageOverrides["observed"] = "en"
            let replacement = try LibraryPersistence.encode(document)
            try LibraryPersistence.write(replacement, to: file, replacing: bytes)
            bytes = replacement
            assertChanges(library, ["events", "historyRevision", "summary", "languageSummary", "overrides", "overridesRevision"]) {
                XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            }
            XCTAssertEqual(library.historyRevision, history + 1)
            XCTAssertEqual(library.recordingLanguageOverridesRevision, overrides + 1)
            document.events[0].id = UUID()
            try LibraryPersistence.write(LibraryPersistence.encode(document), to: file, replacing: bytes)
            assertChanges(library, ["events", "historyRevision", "summary", "languageSummary"]) {
                XCTAssertEqual(library.reloadFromDisk(), .historyBoundary)
            }
            XCTAssertEqual(library.historyRevision, history + 2)
            assertChanges(library, []) { XCTAssertEqual(library.reloadFromDisk(), .reloaded) }
        }
    }

    func testReloadPublishesFavoriteAndPreferenceChanges() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let other = LibraryStore(directory: directory)
            other.toggleFavorite(libraryTestTrack("observed"))
            other.preferences.appearance = .light
            assertChanges(library, ["favorites", "isFavorite", "preferences", "pendingNotifications"]) {
                XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            }
            XCTAssertTrue(library.isFavorite(libraryTestTrack("observed")))
            XCTAssertEqual(library.preferences.appearance, .light)
        }
    }

    func testCloudApplyPublishesSharedSlicesAfterDurabilityAndKeepsPlayback() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        let track = libraryTestTrack("observed")
        library.updatePlayback(PlaybackSnapshot(queue: [track], position: 18, originalQueue: [track]))
        var remote = LibraryDocument()
        remote.favorites = [track]
        remote.preferences.appearance = .light
        remote.events = [ListeningEvent(id: UUID(), track: track, startedAt: LibrarySyncTestData.now, listenedSeconds: 30)]
        remote.recordingLanguageOverrides = [track.id: "hi"]
        let state = try LibrarySyncJournal.seed(remote, now: LibrarySyncTestData.now, writer: LibrarySyncTestData.b)
        let durable = ChangeProbe(read: { _ = library.events }) {
            let reopened = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
            XCTAssertEqual(reopened.events.count, 1)
            XCTAssertEqual(reopened.favorites, [track])
            XCTAssertEqual(reopened.playback.position, 18)
        }
        try assertChanges(library, ["favorites", "isFavorite", "preferences", "events", "historyRevision", "summary",
                                    "languageSummary", "overrides", "overridesRevision", "pendingNotifications"]) {
            XCTAssertTrue(try library.mergeCloudState(state))
        }
        XCTAssertEqual(durable.count, 1)
        XCTAssertEqual(library.playback.position, 18)
        let history = library.historyRevision
        let overrides = library.recordingLanguageOverridesRevision
        remote.events[0].track.language = .english
        remote.recordingLanguageOverrides[track.id] = "en"
        let replacement = try LibrarySyncJournal.seed(remote, now: LibrarySyncTestData.now.addingTimeInterval(1),
                                                     writer: LibrarySyncTestData.b)
        try assertChanges(library, ["events", "historyRevision", "summary", "languageSummary", "overrides", "overridesRevision"]) {
            XCTAssertTrue(try library.mergeCloudState(replacement))
        }
        XCTAssertEqual(library.events.count, 1)
        XCTAssertEqual(library.events.first?.listenedSeconds, 30)
        XCTAssertEqual(library.historyRevision, history + 1)
        XCTAssertEqual(library.recordingLanguageOverridesRevision, overrides + 1)
    }

    func testStartupRetentionPublishesRetainedDocumentAndKeepsRevisionsLocal() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let now = LibrarySyncTestData.now
        var document = LibraryDocument()
        document.events = [ListeningEvent(id: UUID(), track: libraryTestTrack("observed"),
                                          startedAt: now.addingTimeInterval(-800 * 86_400), listenedSeconds: 30)]
        document.recordingLanguageOverrides = ["observed": "hi"]
        let file = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        try LibraryPersistence.write(LibraryPersistence.encode(document), to: file, replacing: nil)
        let library = LibraryStore(directory: harness.root, now: { now })
        XCTAssertNil(library.errorMessage)
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertEqual(library.historyRevision, 2)
        XCTAssertEqual(library.recordingLanguageOverridesRevision, 1)
        XCTAssertEqual(library.durableCommitCount, 1)
        let reopened = LibraryStore(directory: harness.root, now: { now })
        XCTAssertTrue(reopened.events.isEmpty)
        XCTAssertEqual(reopened.historyRevision, 0)
        XCTAssertEqual(reopened.recordingLanguageOverridesRevision, 1)
        XCTAssertEqual(reopened.durableCommitCount, 0)
    }

    func testInitialLoadBuildsIndexesAndRetentionInvalidatesHistory() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let clock = harness.clock
        let track = libraryTestTrack("observed")
        var document = LibraryDocument()
        document.favorites = [track]
        document.disliked = [DislikedSong(id: "disliked", title: "Disliked", artists: [], dislikedAt: clock.now)]
        document.events = [ListeningEvent(id: UUID(), track: track, startedAt: clock.now, listenedSeconds: 30)]
        document.recordingLanguageOverrides = [track.id: "hi"]
        try LibraryPersistence.write(LibraryPersistence.encode(document),
                                     to: harness.root.appendingPathComponent(LibraryPersistence.fileName), replacing: nil)
        let library = LibraryStore(directory: harness.root, now: { clock.now })
        XCTAssertTrue(library.isFavorite(track))
        XCTAssertTrue(library.isDisliked(libraryTestTrack("disliked")))
        XCTAssertEqual(library.dislikedTrackIDs, ["disliked"])
        XCTAssertEqual(library.historyRevision, 1)
        XCTAssertEqual(library.recordingLanguageOverridesRevision, 1)
        clock.advance(by: 410 * 86_400)
        assertChanges(library, ["playback", "events", "historyRevision", "summary", "languageSummary"]) {
            library.updatePlayback(PlaybackSnapshot(queue: [track], position: 2, originalQueue: [track]))
        }
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertEqual(library.historyRevision, 2)
        XCTAssertTrue(LibraryStore(directory: harness.root, now: { clock.now }).events.isEmpty)
    }

    func testDerivedHelpersAndOtherSlicesRemainObservable() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let track = libraryTestTrack("observed")
            assertChanges(library, ["playlists"]) { _ = library.createPlaylist(name: "Playlist", tracks: [track]) }
            let mix = GeneratedPlaylist(kind: .dailyMix, tracks: [track], generatedAt: Date(), periodKey: "observation", seedArtists: [])
            assertChanges(library, ["mixes", "mix"]) { library.saveMix(mix) }
            assertChanges(library, ["disliked", "isDisliked", "dislikedIDs", "mixes", "mix"]) { library.toggleDislike(track) }
            assertChanges(library, ["favorites", "isFavorite", "disliked", "isDisliked", "dislikedIDs"]) { library.toggleFavorite(track) }
            XCTAssertFalse(library.isDisliked(track))
            assertChanges(library, ["searches"]) { library.recordSearch("Search") }
            assertChanges(library, ["searchSelections"]) { XCTAssertTrue(library.recordSearchSelection(.track(track))) }
            assertChanges(library, ["searches", "searchSelections", "searchReset"]) { XCTAssertTrue(library.clearRecentSearches()) }
            assertChanges(library, ["searchReset"]) { XCTAssertTrue(library.clearRecentSearches()) }
            assertChanges(library, ["tipCount", "tipCredit"]) { XCTAssertTrue(library.recordTip(transactionID: 1, credited: true)) }
            assertChanges(library, ["lyricsOffset"]) { library.setLyricsOffset(1, for: track.id) }
            assertChanges(library, ["overrides", "overridesRevision", "languageSummary"]) {
                XCTAssertTrue(library.setRecordingLanguageOverride("hi", for: track.id))
            }
            let overrides = library.recordingLanguageOverridesRevision
            assertChanges(library, []) { XCTAssertTrue(library.setRecordingLanguageOverride("hi", for: track.id)) }
            XCTAssertEqual(library.recordingLanguageOverridesRevision, overrides)
            assertChanges(library, ["overrides", "overridesRevision", "languageSummary"]) {
                XCTAssertTrue(library.setRecordingLanguageOverride(nil, for: track.id))
            }
            XCTAssertEqual(library.recordingLanguageOverridesRevision, overrides + 1)
            assertChanges(library, ["follows", "isFollowing"]) { library.follow(FollowedArtist(id: "artist", name: "Artist")) }
            let release = ArtistRelease(id: "release", title: "Release", subtitle: "", artistID: "artist",
                                        artistName: "Artist", discoveredAt: Date())
            assertChanges(library, ["follows", "isFollowing", "releases", "unseenReleases", "pendingNotifications"]) {
                XCTAssertTrue(library.recordReleaseCheck(artistID: "artist", knownReleaseIDs: [release.id], newReleases: [release]))
            }
            assertChanges(library, ["pendingNotifications"]) { XCTAssertTrue(library.acknowledgeReleaseNotification(id: release.id)) }
            assertChanges(library, ["releases", "unseenReleases", "pendingNotifications"]) { library.markReleasesSeen() }
            assertChanges(library, ["follows", "isFollowing", "releases", "unseenReleases", "pendingNotifications"]) {
                library.unfollow(artistID: "artist")
            }
        }
    }

    private func assertChanges(_ library: LibraryStore, _ expected: Set<String>, file: StaticString = #filePath,
                               line: UInt = #line, _ change: () throws -> Void) rethrows {
        let track = libraryTestTrack("observed")
        let readers: [String: @MainActor () -> Void] = [
            "favorites": { _ = library.favorites }, "isFavorite": { _ = library.isFavorite(track) },
            "playlists": { _ = library.playlists }, "preferences": { _ = library.preferences },
            "events": { _ = library.events }, "historyRevision": { _ = library.historyRevision },
            "summary": { _ = library.summary(for: .week) }, "languageSummary": { _ = library.languageSummary(for: .week) },
            "recents": { _ = library.recentlyPlayed }, "playback": { _ = library.playback },
            "searches": { _ = library.recentSearches }, "searchSelections": { _ = library.recentSearchSelections },
            "searchReset": { _ = library.searchHistoryResetRevision }, "follows": { _ = library.followedArtists },
            "isFollowing": { _ = library.isFollowing(artistID: "artist") }, "releases": { _ = library.releases },
            "unseenReleases": { _ = library.unseenReleaseCount }, "pendingNotifications": { _ = library.pendingReleaseNotifications },
            "mixes": { _ = library.mixes }, "mix": { _ = library.mix(.dailyMix) },
            "disliked": { _ = library.disliked }, "isDisliked": { _ = library.isDisliked(track) },
            "dislikedIDs": { _ = library.dislikedTrackIDs }, "tipCount": { _ = library.tipCount },
            "tipCredit": { _ = library.tipCredit(for: 1) }, "lyricsOffset": { _ = library.lyricsOffset(for: track.id) },
            "overrides": { _ = library.recordingLanguageOverrides },
            "overridesRevision": { _ = library.recordingLanguageOverridesRevision }
        ]
        let probes = readers.mapValues { ChangeProbe(read: $0) }
        try change()
        XCTAssertEqual(Set(probes.filter { $0.value.count > 0 }.keys), expected, file: file, line: line)
    }
}

@MainActor
private final class ChangeProbe {
    var count = 0

    init(read: () -> Void, changed: @escaping @MainActor () -> Void = {}) {
        withObservationTracking(read) {
            MainActor.assumeIsolated {
                self.count += 1
                changed()
            }
        }
    }
}
