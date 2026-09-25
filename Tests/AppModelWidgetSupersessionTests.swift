import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelWidgetSupersessionTests: XCTestCase {
    func testNewerWidgetSongSupersedesPendingRecentWithoutApplyingItsResumePosition() async throws {
        let f = WidgetRouteFixtures.self
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected, f.newer]) {
            $0.library.recordRecent(track: f.selected, position: 18)
            $0.library.toggleFavorite(f.newer)
        }
        let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)

        XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.playTrack(source: .likedSongs, id: f.newer.id).url))
        let newerWork = try XCTUnwrap(context.model.widgetOpenTask)
        context.assertPausedPlayback(f.playback)
        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value
        await newerWork.value

        XCTAssertEqual(context.player.queue, [f.newer])
        XCTAssertEqual(context.player.currentTrack, f.newer)
        XCTAssertTrue(context.model.isPlayerPresented)
        XCTAssertNil(context.model.widgetOpenTask)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.2 }
        XCTAssertLessThan(context.player.position, 18)
        XCTAssertEqual(context.player.currentStreamURL, cache.cache.directory.appendingPathComponent("\(f.newer.id).wav"))
        XCTAssertTrue(context.player.isCurrentTrackCached)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testPendingRecentCannotReplaceNewerModelOrNativeSongSelection() async throws {
        let f = WidgetRouteFixtures.self
        for throughModel in [false, true] {
            let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected, f.newer]) {
                $0.library.recordRecent(track: f.selected, position: 18)
            }
            let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)

            if throughModel { XCTAssertTrue(context.model.play(f.newer)) }
            else { context.player.play([f.newer]) }
            XCTAssertEqual(context.player.currentTrack, f.newer)
            try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
            await held.work.value

            XCTAssertEqual(context.player.queue, [f.newer])
            XCTAssertEqual(context.player.currentTrack, f.newer)
            XCTAssertFalse(context.model.isPlayerPresented)
            try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.2 }
            XCTAssertEqual(context.player.currentStreamURL, cache.cache.directory.appendingPathComponent("\(f.newer.id).wav"))
            XCTAssertLessThan(context.player.position, 18)
            XCTAssertTrue(calls.values.isEmpty)
            XCTAssertTrue(cache.mock.state.requests.isEmpty)
            await context.assertNoCatalogRequests()
            context.player.pause()
        }
    }

    func testPendingRecentCannotOvertakeNativePlayOfTheRestoredQueue() async throws {
        let f = WidgetRouteFixtures.self
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
            $0.library.recordRecent(track: f.selected, position: 18)
        }
        let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)

        context.player.resumePlayback()
        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        XCTAssertEqual(context.player.queue, f.playback.queue)
        XCTAssertEqual(context.player.currentIndex, 2)
        XCTAssertFalse(context.model.isPlayerPresented)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
        XCTAssertEqual(context.player.currentStreamURL, cache.cache.directory.appendingPathComponent("\(f.current.id).wav"))
        XCTAssertLessThan(context.player.position, 18)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testNewerNativeSeekSupersedesPendingRouteIncludingASeekBackToTheOriginalPosition() async throws {
        let f = WidgetRouteFixtures.self
        for returnToOriginalPosition in [false, true] {
            let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
                $0.library.recordRecent(track: f.selected, position: 18)
            }
            let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)

            context.player.seek(to: 8.25)
            if returnToOriginalPosition { context.player.seek(to: f.playback.position) }
            var expected = f.playback
            expected.position = returnToOriginalPosition ? f.playback.position : 8.25
            context.assertPausedPlayback(expected)
            try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
            await held.work.value

            context.assertPausedPlayback(expected)
            XCTAssertNil(context.player.currentStreamURL)
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertTrue(calls.values.isEmpty)
            XCTAssertTrue(cache.mock.state.requests.isEmpty)
            await context.assertNoCatalogRequests()
        }
    }

    func testNativePlayPauseRoundTripSupersedesPendingRouteWithIdenticalVisiblePlaybackState() async throws {
        let f = WidgetRouteFixtures.self
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
            $0.library.recordRecent(track: f.selected, position: 18)
        }
        let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)
        context.assertPausedPlayback(f.playback)

        // No suspension between controls: the final queue, position and paused intent equal the captured state.
        context.player.resumePlayback()
        context.player.pause()
        context.assertPausedPlayback(f.playback)
        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        context.assertPausedPlayback(f.playback)
        XCTAssertNil(context.player.currentStreamURL)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertTrue(context.model.cachedPlayableTrackIDs.contains(f.selected.id))
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testPlayingPauseResumeRoundTripKeepsNativeAudioInsteadOfTheDeferredRecent() async throws {
        let f = WidgetRouteFixtures.self
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
            $0.library.recordRecent(track: f.selected, position: 18)
        }
        context.player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
        let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)
        let stream = context.player.currentStreamURL

        context.player.pause()
        let position = context.player.position
        context.player.resumePlayback()
        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        XCTAssertEqual(context.player.queue, f.playback.queue)
        XCTAssertEqual(context.player.currentTrack, f.current)
        XCTAssertEqual(context.player.currentIndex, 2)
        XCTAssertEqual(context.player.currentStreamURL, stream)
        XCTAssertFalse(context.model.isPlayerPresented)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > position + 0.2 }
        XCTAssertLessThan(context.player.position, 18)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testNewerTabNativePathSheetAndWidgetHeadingSupersedePendingPlayback() async throws {
        let f = WidgetRouteFixtures.self
        let detail = MusicCollection(id: "newer-album", title: "Newer album", kind: .album)
        for action in ["tab", "path", "settings", "heading"] {
            let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
                $0.library.recordRecent(track: f.selected, position: 18)
            }
            let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)

            switch action {
            case "tab": context.model.selectTab(.search)
            case "path": context.model.navigationPath(for: .home).wrappedValue = [detail]
            case "settings": context.model.isSettingsPresented = true
            default: XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.open(.likedSongs).url))
            }
            let paths = context.model.navigationPaths
            try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
            await held.work.value

            let expectedTab: AppTab = action == "tab" ? .search : action == "heading" ? .library : .home
            XCTAssertEqual(context.model.selectedTab, expectedTab)
            XCTAssertEqual(context.model.navigationPaths, paths)
            if action == "path" { XCTAssertEqual(context.model.navigationPaths[.home], [detail]) }
            XCTAssertEqual(context.model.isSettingsPresented, action == "settings")
            XCTAssertEqual(context.model.widgetLibraryDestination, action == "heading" ? .likes : nil)
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertNil(context.model.widgetOpenTask)
            context.assertPausedPlayback(f.playback)
            XCTAssertTrue(calls.values.isEmpty)
            XCTAssertTrue(cache.mock.state.requests.isEmpty)
            await context.assertNoCatalogRequests()
        }
    }

    func testUnlikeDuringInventoryWaitRechecksLiveSourceMembership() async throws {
        let f = WidgetRouteFixtures.self
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
            $0.library.toggleFavorite(f.selected)
            $0.library.recordRecent(track: f.selected, position: 18)
        }
        let held = try await context.suspend(.playTrack(source: .likedSongs, id: f.selected.id), using: inventory)

        context.library.toggleFavorite(f.selected)
        XCTAssertTrue(context.library.favorites.isEmpty)
        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        context.assertPausedPlayback(f.playback)
        XCTAssertEqual(context.model.widgetLibraryDestination, .likes)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertTrue(context.model.toast?.contains("no longer") == true)
        XCTAssertEqual(context.library.recentlyPlayed.first?.track, f.selected)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testMixPeriodChangedDuringInventoryOpensReplacementWithoutAutoplay() async throws {
        let f = WidgetRouteFixtures.self
        for kind in GeneratedPlaylistKind.allCases {
            let old = f.mix(kind, period: "old-period", tracks: [f.selected])
            let replacement = f.mix(kind, period: "new-period", tracks: [f.newer])
            let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected, f.newer]) {
                $0.library.saveMix(old)
            }
            let held = try await context.suspend(.mix(kind: kind, periodKey: old.periodKey, play: true), using: inventory)

            context.library.saveMix(replacement)
            XCTAssertEqual(context.library.mix(kind), replacement)
            try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
            await held.work.value

            context.assertPausedPlayback(f.playback)
            XCTAssertEqual(context.model.selectedTab, .home)
            XCTAssertEqual(context.model.navigationPaths[.home], [replacement.collection])
            XCTAssertTrue(context.model.toast?.contains("refreshed") == true)
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertFalse(context.model.isGeneratingMixes)
            XCTAssertTrue(calls.values.isEmpty)
            XCTAssertTrue(cache.mock.state.requests.isEmpty)
            await context.assertNoCatalogRequests()
        }
    }

    func testMixRemovedDuringInventoryOpensHomeWithoutReplacingPlayback() async throws {
        let f = WidgetRouteFixtures.self
        let mix = f.mix(tracks: [f.selected])
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
            $0.library.saveMix(mix)
        }
        let held = try await context.suspend(.mix(kind: mix.kind, periodKey: mix.periodKey, play: true), using: inventory)

        context.library.toggleDislike(f.selected)
        XCTAssertNil(context.library.mix(mix.kind))
        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        context.assertPausedPlayback(f.playback)
        XCTAssertEqual(context.model.selectedTab, .home)
        XCTAssertEqual(context.model.navigationPaths[.home], [])
        XCTAssertTrue(context.model.toast?.contains("no longer available") == true)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testHistoryClearSupersedesAllPendingPlaybackRoutesEvenIfMembershipIsRestored() async throws {
        let f = WidgetRouteFixtures.self
        let mix = f.mix(tracks: [f.selected])
        let routes: [MusicWidgetRoute] = [.playTrack(source: .recentlyPlayed, id: f.selected.id),
                                         .playTrack(source: .likedSongs, id: f.selected.id),
                                         .mix(kind: mix.kind, periodKey: mix.periodKey, play: true)]
        for route in routes {
            let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
                $0.library.recordRecent(track: f.selected, position: 18)
                $0.library.toggleFavorite(f.selected)
                $0.library.saveMix(mix)
            }
            let held = try await context.suspend(route, using: inventory)

            context.library.clearHistory()
            context.library.recordRecent(track: f.selected, position: 18)
            context.library.saveMix(mix)
            XCTAssertEqual(context.library.favorites, [f.selected])
            XCTAssertEqual(context.library.recentlyPlayed.first?.track, f.selected)
            XCTAssertEqual(context.library.mix(mix.kind), mix)
            try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
            await held.work.value

            context.assertPausedPlayback(f.playback)
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertNil(context.model.widgetOpenTask)
            XCTAssertNil(context.model.toast)
            XCTAssertTrue(calls.values.isEmpty)
            XCTAssertTrue(cache.mock.state.requests.isEmpty)
            await context.assertNoCatalogRequests()
        }
    }

    func testHistoryDisableEnableRoundTripSupersedesPendingRecentDespiteRetainedMembership() async throws {
        let f = WidgetRouteFixtures.self
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
            $0.library.recordRecent(track: f.selected, position: 18)
        }
        let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)

        context.model.updatePreferences { $0.saveListeningHistory = false }
        context.model.updatePreferences { $0.saveListeningHistory = true }
        XCTAssertTrue(context.library.preferences.saveListeningHistory)
        XCTAssertEqual(context.library.recentlyPlayed.first?.track, f.selected)
        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        context.assertPausedPlayback(f.playback)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertNil(context.model.widgetOpenTask)
        XCTAssertNil(context.model.toast)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testWelcomeMustStillBeCompleteAfterTheInventoryWait() async throws {
        let f = WidgetRouteFixtures.self
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
            $0.library.toggleFavorite(f.selected)
        }
        let held = try await context.suspend(.playTrack(source: .likedSongs, id: f.selected.id), using: inventory)

        context.model.updatePreferences { $0.hasCompletedWelcome = false }
        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        context.assertPausedPlayback(f.playback)
        XCTAssertFalse(context.library.preferences.hasCompletedWelcome)
        XCTAssertTrue(context.library.widgetLibrarySourceIsAvailable)
        XCTAssertEqual(context.model.selectedTab, .home)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertNil(context.model.widgetOpenTask)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testActualLibraryBytesAreRevalidatedAfterInventoryWithoutLifecycleCallbacks() async throws {
        let f = WidgetRouteFixtures.self
        for change in ["clear", "future", "delete"] {
            let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
                $0.library.recordRecent(track: f.selected, position: 18)
            }
            let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)
            var expectedBytes: Data?
            switch change {
            case "clear":
                let external = LibraryStore(directory: context.base.directory)
                external.clearHistory()
                XCTAssertNil(external.errorMessage)
                expectedBytes = try Data(contentsOf: context.libraryURL)
            case "future":
                let bytes = Data("{\"version\":\(LibraryPersistence.currentVersion + 1),\"future\":\"keep\"}".utf8)
                try bytes.write(to: context.libraryURL, options: .atomic)
                expectedBytes = bytes
            default:
                try FileManager.default.removeItem(at: context.libraryURL)
            }
            XCTAssertEqual(context.library.recentlyPlayed.first?.track, f.selected)
            XCTAssertTrue(context.library.widgetLibrarySourceIsAvailable)

            try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
            await held.work.value

            context.assertPausedPlayback(f.playback)
            XCTAssertFalse(context.library.widgetLibrarySourceIsAvailable)
            XCTAssertEqual(context.model.selectedTab, .library)
            XCTAssertNil(context.model.widgetLibraryDestination)
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertTrue(context.model.toast?.contains("Reload") == true)
            if let expectedBytes { XCTAssertEqual(try Data(contentsOf: context.libraryURL), expectedBytes) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: context.libraryURL.path)) }
            XCTAssertTrue(calls.values.isEmpty)
            XCTAssertTrue(cache.mock.state.requests.isEmpty)
            await context.assertNoCatalogRequests()
        }
    }
}
