import Foundation
import Observation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelWidgetOfflineTests: XCTestCase {
    func testUncachedRecentWaitsForInventoryThenPreservesPausedQueueAndResumeIntentWithoutNetwork() async throws {
        let f = WidgetRouteFixtures.self
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next]) {
            $0.library.recordRecent(track: f.selected, position: 18)
            $0.library.recordRecent(track: f.next, position: 2)
        }
        XCTAssertFalse(context.model.hasLoadedCachedSongs)
        let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)
        context.assertPausedPlayback(f.playback)
        XCTAssertFalse(context.model.isPlayerPresented)
        let captured = try XCTUnwrap(held.request.input)
        XCTAssertEqual(Set(captured.songs.filter(\.isPlayable).map(\.id)), [f.current.id, f.next.id])
        XCTAssertFalse(context.model.hasLoadedCachedSongs)

        try await inventory.snapshots.complete(held.request, with: .success(captured))
        await held.work.value

        XCTAssertTrue(context.model.hasLoadedCachedSongs)
        XCTAssertNil(context.model.widgetOpenTask)
        XCTAssertTrue(context.model.toast?.contains("isn’t cached") == true)
        XCTAssertFalse(context.model.isPlayerPresented)
        context.assertPausedPlayback(f.playback)
        XCTAssertNil(context.player.currentStreamURL)
        XCTAssertEqual(context.library.recentlyPlayed.first { $0.id == f.selected.id }?.position, 18)
        context.player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
        XCTAssertEqual(context.player.currentTrack, f.current)
        XCTAssertEqual(context.player.currentIndex, 2)
        XCTAssertEqual(context.player.currentStreamURL, cache.cache.directory.appendingPathComponent("\(f.current.id).wav"))
        XCTAssertTrue(context.player.isCurrentTrackCached)
        XCTAssertLessThan(context.player.position, 18)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testUncachedSameCurrentRecentPreservesPausedQueueAndPositionWithoutResolvingAudio() async throws {
        let f = WidgetRouteFixtures.self
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.next], snapshot: f.playback) {
            $0.library.recordRecent(track: f.current, position: 18)
        }
        XCTAssertTrue(context.model.isOffline)
        XCTAssertTrue(context.library.preferences.hasCompletedWelcome)
        XCTAssertTrue(context.library.preferences.saveListeningHistory)
        XCTAssertEqual(context.library.recentlyPlayed.map(\.id), [f.current.id])
        XCTAssertEqual(context.library.recentlyPlayed.first?.position, 18)
        XCTAssertEqual(context.player.currentTrack, f.current)
        context.assertPausedPlayback(f.playback)
        XCTAssertNil(context.player.currentStreamURL)

        // A failed offline resolution can return to idle before the assertions see it.
        let loadingChanges = CatalogTestRecorder<Bool>()
        withObservationTracking {
            _ = context.player.isLoading
        } onChange: {
            loadingChanges.record(true)
        }
        let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.current.id), using: inventory)
        let captured = try XCTUnwrap(held.request.input)
        XCTAssertEqual(Set(captured.songs.filter(\.isPlayable).map(\.id)), [f.next.id])
        XCTAssertFalse(context.model.hasLoadedCachedSongs)
        context.assertPausedPlayback(f.playback)
        XCTAssertTrue(loadingChanges.values.isEmpty)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertNil(context.model.toast)

        try await inventory.snapshots.complete(held.request, with: .success(captured))
        await held.work.value
        await context.assertNoCatalogRequests()

        XCTAssertTrue(context.model.hasLoadedCachedSongs)
        XCTAssertEqual(context.model.cachedPlayableTrackIDs, [f.next.id])
        XCTAssertNil(context.model.cachedSongsError)
        context.assertPausedPlayback(f.playback)
        XCTAssertEqual(context.player.currentTrack, f.current)
        XCTAssertNil(context.player.currentStreamURL)
        XCTAssertFalse(context.player.isPreparing)
        XCTAssertNil(context.library.errorMessage)
        XCTAssertEqual(context.library.recentlyPlayed.first?.position, 18)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertTrue(context.model.toast?.contains("isn’t cached") == true)
        XCTAssertNil(context.model.widgetOpenTask)
        XCTAssertTrue(loadingChanges.values.isEmpty, "The same-current shortcut must reject before starting audio resolution")
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
    }

    func testUncachedRecentCannotSeekOrInterruptNativeAudioAlreadyPlayingOffline() async throws {
        let f = WidgetRouteFixtures.self
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next]) {
            $0.library.recordRecent(track: f.selected, position: 18)
        }
        context.player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
        let stream = context.player.currentStreamURL
        let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertEqual(context.player.currentStreamURL, stream)
        let position = context.player.position

        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        XCTAssertEqual(context.player.queue, f.playback.queue)
        XCTAssertEqual(context.player.currentIndex, 2)
        XCTAssertEqual(context.player.currentStreamURL, stream)
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertNil(context.player.errorMessage)
        XCTAssertGreaterThanOrEqual(context.player.position, position)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertTrue(context.model.toast?.contains("isn’t cached") == true)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > position + 0.2 }
        XCTAssertLessThan(context.player.position, 18)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testCachedRecentWaitsForInventoryThenResumesOnlyAfterItsQueueIsAccepted() async throws {
        let f = WidgetRouteFixtures.self
        let snapshot = PlaybackSnapshot(queue: [f.current], position: 3.25, originalQueue: [f.current], originalQueueIndices: [0])
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.selected, f.next], snapshot: snapshot) {
            $0.library.recordRecent(track: f.selected, position: 11.25)
            $0.library.recordRecent(track: f.next, position: 2)
        }
        var published: [PlaybackSnapshot] = []
        let save = context.player.onSnapshotChanged
        context.player.onSnapshotChanged = { snapshot in published.append(snapshot); save?(snapshot) }
        let held = try await context.suspend(.playTrack(source: .recentlyPlayed, id: f.selected.id), using: inventory)
        context.assertPausedPlayback(snapshot)
        XCTAssertTrue(published.isEmpty)
        context.library.recordRecent(track: f.selected, position: 14.25)
        context.library.recordRecent(track: f.next, position: 2)

        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        let expected = [f.next, f.selected]
        XCTAssertEqual(context.player.queue, expected)
        XCTAssertEqual(context.player.currentTrack, f.selected)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertTrue(published.contains { $0.queue == expected && $0.currentIndex == 1 && $0.position == 14.25 })
        XCTAssertFalse(published.contains { $0.queue == snapshot.queue && $0.position == 14.25 })
        XCTAssertTrue(context.model.isPlayerPresented)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 14.5 }
        XCTAssertEqual(context.player.currentStreamURL, cache.cache.directory.appendingPathComponent("\(f.selected.id).wav"))
        XCTAssertTrue(context.player.isCurrentTrackCached)
        XCTAssertNil(context.player.errorMessage)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testOfflineMixWaitsForInventoryAndSkipsUncachedFirstSongForRealLocalAudio() async throws {
        let f = WidgetRouteFixtures.self
        let mix = f.mix(tracks: [f.selected, f.next, f.newer])
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next]) {
            $0.library.saveMix(mix)
        }
        let held = try await context.suspend(.mix(kind: mix.kind, periodKey: mix.periodKey, play: true), using: inventory)
        context.assertPausedPlayback(f.playback)
        XCTAssertFalse(context.model.hasLoadedCachedSongs)
        XCTAssertFalse(context.model.isPlayerPresented)

        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        XCTAssertEqual(context.player.queue, [f.next])
        XCTAssertEqual(context.player.currentTrack, f.next)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertFalse(context.player.shuffleEnabled)
        XCTAssertEqual(context.model.cachedPlayableTrackIDs, [f.current.id, f.next.id])
        XCTAssertTrue(context.model.isPlayerPresented)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.2 }
        XCTAssertEqual(context.player.currentStreamURL, cache.cache.directory.appendingPathComponent("\(f.next.id).wav"))
        XCTAssertTrue(context.player.isCurrentTrackCached)
        XCTAssertNil(context.player.errorMessage)
        XCTAssertEqual(context.library.mix(mix.kind), mix)
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testOfflineMixWithoutACachedMemberPreservesExistingQueueAndPosition() async throws {
        let f = WidgetRouteFixtures.self
        let mix = f.mix(.discoverWeekly, period: "saved-week", tracks: [f.selected, f.newer])
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next]) {
            $0.library.saveMix(mix)
        }
        let held = try await context.suspend(.mix(kind: mix.kind, periodKey: mix.periodKey, play: true), using: inventory)

        try await inventory.snapshots.complete(held.request, with: .success(held.request.input))
        await held.work.value

        context.assertPausedPlayback(f.playback)
        XCTAssertNil(context.player.currentStreamURL)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertTrue(context.model.toast?.contains("no cached songs") == true)
        XCTAssertEqual(context.library.mix(mix.kind), mix)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testFailedOrUnavailableInventoryRefusesRecentAndMixPlaybackIncludingWithPreviouslyLoadedInventory() async throws {
        let f = WidgetRouteFixtures.self
        let mix = f.mix()
        let routes: [MusicWidgetRoute] = [.playTrack(source: .recentlyPlayed, id: f.selected.id),
                                         .mix(kind: mix.kind, periodKey: mix.periodKey, play: true)]
        for route in routes {
            for previouslyLoaded in [false, true] {
                for failure in [false, true] {
                    let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [f.current, f.next, f.selected]) {
                        $0.library.recordRecent(track: f.selected, position: 18)
                        $0.library.saveMix(mix)
                    }
                    if previouslyLoaded {
                        await context.model.refreshCachedSongs()
                        XCTAssertTrue(context.model.cachedPlayableTrackIDs.contains(f.selected.id))
                    }
                    let held = try await context.suspend(route, using: inventory)
                    let result: Result<AudioCacheSnapshot?, any Error> = failure
                        ? .failure(CocoaError(.fileReadNoPermission)) : .success(nil)

                    try await inventory.snapshots.complete(held.request, with: result)
                    await held.work.value

                    context.assertPausedPlayback(f.playback)
                    XCTAssertNil(context.player.currentStreamURL)
                    XCTAssertFalse(context.model.isPlayerPresented)
                    XCTAssertNil(context.model.widgetOpenTask)
                    XCTAssertTrue(context.model.toast?.contains("couldn’t be checked") == true)
                    if failure { XCTAssertNotNil(context.model.cachedSongsError) }
                    else { XCTAssertNil(context.model.cachedSongsUsage) }
                    XCTAssertTrue(calls.values.isEmpty)
                    XCTAssertTrue(cache.mock.state.requests.isEmpty)
                    await context.assertNoCatalogRequests()
                }
            }
        }
    }

    func testOfflineHeadingsBrowseWithoutLoadingModelCacheInventory() async throws {
        let (context, cache, inventory, calls) = try makeWidgetOfflineFixture(cached: [])
        for kind in MusicWidgetKind.allCases {
            XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.open(kind).url))
            XCTAssertNil(context.model.widgetOpenTask)
            XCTAssertFalse(context.model.hasLoadedCachedSongs)
            XCTAssertFalse(context.model.isRefreshingCachedSongs)
            context.assertPausedPlayback(WidgetRouteFixtures.playback)
        }
        let heldReads = await inventory.snapshots.requests
        XCTAssertTrue(heldReads.isEmpty)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(cache.mock.state.requests.isEmpty)
        await context.assertNoCatalogRequests()
    }
}
