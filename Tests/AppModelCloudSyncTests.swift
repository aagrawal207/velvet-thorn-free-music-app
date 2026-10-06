import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelCloudSyncTests: XCTestCase {
    func testSyncNoticeClearsAfterRecoveryWithoutDismissingAnUnrelatedToastOrNavigating() async throws {
        let context = try AppModelTestContext()
        addTeardownBlock { try await context.close() }
        let model = context.model
        model.selectedTab = .search
        let notify = try XCTUnwrap(model.cloudSync.onFailureNotification)
        notify("Retry sync in Settings.")
        XCTAssertEqual(model.toast, "Retry sync in Settings.")
        XCTAssertEqual(model.selectedTab, .search)
        XCTAssertFalse(model.isPlayerPresented)
        notify(nil)
        XCTAssertNil(model.toast)
        notify("Retry sync in Settings.")
        model.showToast("Unrelated message")
        notify(nil)
        XCTAssertEqual(model.toast, "Unrelated message")
    }

    func testFreshAndLegacyMissingTransitionPreferencesUseNoOverlap() throws {
        let fresh = UserPreferences()
        let legacy = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
        for preferences in [fresh, legacy] {
            XCTAssertFalse(preferences.automix)
            XCTAssertEqual(preferences.crossfadeSeconds, 0)
            XCTAssertTrue(preferences.gaplessPlayback)
            XCTAssertTrue(preferences.autoplay)
        }
        XCTAssertFalse(PlaybackTransitionSettings().automix)
    }

    func testExistingAutomixAndPreciseCrossfadeChoicesSurviveDecodeAndSync() throws {
        let saved = try JSONDecoder().decode(UserPreferences.self, from: Data(#"{"automix":true,"crossfadeSeconds":2.25}"#.utf8))
        XCTAssertTrue(saved.automix)
        XCTAssertEqual(saved.crossfadeSeconds, 2.25)
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.preferences = saved
        try b.library.mergeCloudState(a.state())
        XCTAssertEqual(b.library.preferences, saved)
        XCTAssertEqual(try b.saved().preferences, saved)
    }

    func testRemotePreferencesApplyToThePlayerWithoutReplacingQueueOrNavigation() async throws {
        let song = AppModelFixtures.track("local-queue")
        let context = try AppModelTestContext(snapshot: PlaybackSnapshot(queue: [song], position: 27))
        addTeardownBlock { try await context.close() }
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let remote = harness.device(LibrarySyncTestData.b)
        let destination = MusicCollection(id: "open-album", title: "Open album", subtitle: "", kind: .album)
        context.model.selectedTab = .search
        context.model.searchQuery = "Keep this query"
        context.model.navigationPaths[.search] = [destination]
        context.model.isPlayerPresented = true
        remote.library.preferences.crossfadeSeconds = 2.25
        remote.library.preferences.automix = true
        remote.library.preferences.autoplay = false
        remote.library.preferences.normalizeVolume = false
        remote.library.preferences.appearance = .light
        remote.library.preferences.appIconID = "Sonnet"
        remote.library.updatePlayback(PlaybackSnapshot(queue: [libraryTestTrack("remote-queue")], position: 80))
        try context.library.mergeCloudState(remote.state())

        XCTAssertEqual(context.player.settings.crossfadeSeconds, 2.25)
        XCTAssertTrue(context.player.settings.automix)
        XCTAssertFalse(context.player.settings.autoplay)
        XCTAssertFalse(context.player.settings.normalizeVolume)
        XCTAssertEqual(context.library.preferences.appearance, .light)
        XCTAssertEqual(context.library.preferences.appIconID, "Sonnet")
        XCTAssertEqual(context.player.queue, [song])
        XCTAssertEqual(context.player.position, 27)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertEqual(context.model.selectedTab, .search)
        XCTAssertEqual(context.model.searchQuery, "Keep this query")
        XCTAssertEqual(context.model.navigationPaths[.search], [destination])
        XCTAssertTrue(context.model.isPlayerPresented)
        XCTAssertTrue(context.model.cloudSync.isEnabled)
        XCTAssertFalse(context.model.cloudSync.isSyncing)
        XCTAssertNil(context.model.cloudSync.lastSyncDate)
        XCTAssertEqual(context.model.cloudSync.statusText, "Waiting to sync with iCloud")
    }

    func testFailedIconPreferenceSaveDoesNotChangeTheSystemIcon() async throws {
        let context = try AppModelTestContext()
        addTeardownBlock { try await context.close() }
        let original = context.library.preferences.appIconID
        let external = LibraryStore(directory: context.directory)
        XCTAssertTrue(external.recordSearchSelection(.collection(MusicCollection(id: "another-writer", title: "Another writer", kind: .album))))
        context.model.selectAppIcon(AppIcons.option(named: "AppIcon-Sonnet"))
        XCTAssertTrue(context.library.requiresReload)
        XCTAssertEqual(context.library.preferences.appIconID, original)
        XCTAssertFalse(context.model.appIcons.isApplying)
        XCTAssertEqual(context.model.appIcons.current, AppIcons.primary)
    }

    func testRemoteTypedRecentsApplyDurablyWithoutReplacingPendingSearchOrPlayback() async throws {
        let song = AppModelFixtures.track("local-playing")
        let context = try AppModelTestContext(snapshot: PlaybackSnapshot(queue: [song], position: 27))
        addTeardownBlock { @MainActor in try await context.close() }
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let remote = harness.device(LibrarySyncTestData.b)
        let local = SearchSelection.collection(MusicCollection(id: "local-album", title: "Local album", kind: .album))
        XCTAssertTrue(context.library.recordSearchSelection(local))
        context.model.selectTab(.search)
        context.model.searchQuery = "Keep this active query"
        context.model.searchFilter = .albums
        let search = context.start { await $0.search() }
        let request = try await context.catalog.searches.request(at: 0)
        let destination = MusicCollection(id: "open-detail", title: "Open detail", kind: .album)
        context.model.navigationPaths[.search] = [destination]
        context.model.isPlayerPresented = true
        let focus = context.model.searchFocusRequest
        let dismissal = context.model.searchFocusDismissal
        let root = context.model.searchRootGeneration
        let selectedSong = SearchSelection.track(AppModelFixtures.track("remote-selected-song"))
        let selectedArtist = SearchSelection.collection(MusicCollection(id: "UCremote", title: "Remote artist", kind: .artist))
        XCTAssertTrue(remote.library.recordSearchSelection(selectedSong))
        XCTAssertTrue(remote.library.recordSearchSelection(selectedArtist))
        remote.library.updatePlayback(PlaybackSnapshot(queue: [AppModelFixtures.track("remote-queue")], position: 80))
        let incoming = try remote.state()
        XCTAssertTrue(try context.library.mergeCloudState(incoming))

        XCTAssertEqual(Set(context.library.recentSearchSelections), Set([local, selectedSong, selectedArtist]))
        XCTAssertEqual(context.model.searchQuery, "Keep this active query")
        XCTAssertEqual(context.model.searchFilter, .albums)
        XCTAssertTrue(context.model.hasExecutedCurrentSearch)
        XCTAssertTrue(context.model.isSearching)
        XCTAssertEqual(context.model.selectedTab, .search)
        XCTAssertEqual(context.model.navigationPaths[.search], [destination])
        XCTAssertEqual(context.model.searchFocusRequest, focus)
        XCTAssertEqual(context.model.searchFocusDismissal, dismissal)
        XCTAssertEqual(context.model.searchRootGeneration, root)
        XCTAssertTrue(context.model.isPlayerPresented)
        XCTAssertEqual(context.player.queue, [song])
        XCTAssertEqual(context.player.position, 27)
        XCTAssertFalse(context.player.isPlaying)
        let result = MusicCollection(id: "query-result", title: "Query result", kind: .album)
        try await context.catalog.searches.complete(request, with: .success(CatalogPage(collections: [result])))
        await search.value
        XCTAssertEqual(context.model.searchPage.collections, [result], "Remote history application must not retire the active search")
        XCTAssertFalse(context.model.isSearching)

        let file = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let bytes = try Data(contentsOf: file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, LibraryPersistence.currentVersion)
        let journal = try XCTUnwrap(object["syncState"] as? [String: Any])
        XCTAssertEqual(journal["version"] as? Int, LibrarySyncState.currentVersion)
        XCTAssertEqual(LibraryStore(directory: context.directory).recentSearchSelections, context.library.recentSearchSelections)
        let applied = try context.library.cloudReplica(replicaID: LibrarySyncTestData.a).state
        for selection in [selectedSong, selectedArtist] {
            let key = LibrarySyncKey(.searchSelection, selection.id)
            XCTAssertEqual(applied.registers[key]?.revision, incoming.registers[key]?.revision, "A remote selection is adopted, not replayed as a local tap")
        }
        XCTAssertFalse(try context.library.mergeCloudState(incoming))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let searches = await context.catalog.searches.requests
        let streams = await context.streams.streams.requests
        XCTAssertEqual(searches.count, 1)
        XCTAssertTrue(streams.isEmpty)
    }

    func testMalformedOrFutureTypedSyncCannotReplaceLocalHistoryOrUserIntent() async throws {
        let song = AppModelFixtures.track("keep-playing")
        let context = try AppModelTestContext(snapshot: PlaybackSnapshot(queue: [song], position: 35))
        addTeardownBlock { @MainActor in try await context.close() }
        let local = SearchSelection.collection(MusicCollection(id: "keep", title: "Kept album", kind: .album))
        XCTAssertTrue(context.library.recordSearchSelection(local))
        context.model.selectTab(.search)
        context.model.searchQuery = "Keep this draft"
        let selection = SearchSelection.track(AppModelFixtures.track("remote"))
        let valid = try LibrarySyncTestData.single(.searchSelection, selection.id, value: selection,
                                                   revision: LibrarySyncTestData.revision(1))
        var malformed = valid
        malformed.registers = [LibrarySyncKey(.searchSelection, "track:wrong-recording"): try XCTUnwrap(valid.registers.values.first)]
        var future = valid
        future.version = LibrarySyncState.currentVersion + 1
        let file = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let saved = try Data(contentsOf: file)
        for incoming in [malformed, future] {
            XCTAssertThrowsError(try context.library.mergeCloudState(incoming))
            XCTAssertEqual(context.library.recentSearchSelections, [local])
            XCTAssertEqual(context.model.searchQuery, "Keep this draft")
            XCTAssertEqual(context.model.selectedTab, .search)
            XCTAssertTrue(context.model.navigationPaths[.search, default: []].isEmpty)
            XCTAssertEqual(context.player.queue, [song])
            XCTAssertEqual(context.player.position, 35)
            XCTAssertEqual(try Data(contentsOf: file), saved)
        }
        XCTAssertTrue(try context.library.mergeCloudState(valid))
        XCTAssertEqual(Set(context.library.recentSearchSelections), Set([local, selection]))
        XCTAssertEqual(context.player.queue, [song])
        XCTAssertEqual(context.model.searchQuery, "Keep this draft")
    }
}
