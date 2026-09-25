import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelWidgetPlaybackTests: XCTestCase {
    func testColdAndWarmLikedSelectionUsesExactCaseSensitiveIDAndSavedOrderWithoutRecentResume() async throws {
        let oldMedia = try makeWidgetAudioFile()
        let selectedMedia = try makeWidgetAudioFile()
        let selected = AppModelFixtures.track("Widget-Ab%雪")
        let otherCase = AppModelFixtures.track("widget-ab%雪")
        let current = WidgetRouteFixtures.current
        let next = WidgetRouteFixtures.next
        let expected = [otherCase, selected, next]
        for warm in [false, true] {
            let resolver = PlaybackFixtureResolver([
                current.id: .init(url: oldMedia, duration: 30),
                selected.id: .init(url: selectedMedia, duration: 30),
                otherCase.id: .init(url: oldMedia, duration: 30),
                next.id: .init(url: oldMedia, duration: 30),
            ])
            let snapshot = warm ? PlaybackSnapshot(queue: [current, next], position: 3.25) : PlaybackSnapshot()
            let context = try makeWidgetRouteContext(snapshot: snapshot, resolver: resolver) {
                for track in expected.reversed() { $0.library.toggleFavorite(track) }
                $0.library.recordRecent(track: selected, position: 18)
            }
            XCTAssertEqual(context.library.favorites, expected)
            if warm {
                context.player.resumePlayback()
                try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
            }
            context.model.isSettingsPresented = true

            XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.playTrack(source: .likedSongs, id: selected.id).url))

            XCTAssertEqual(context.player.queue, expected)
            XCTAssertEqual(context.player.currentTrack, selected)
            XCTAssertEqual(context.player.currentIndex, 1)
            XCTAssertEqual(context.player.position, 0)
            XCTAssertTrue(context.model.isPlayerPresented)
            XCTAssertFalse(context.model.isSettingsPresented)
            try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.2 }
            XCTAssertEqual(context.player.currentStreamURL, selectedMedia)
            XCTAssertLessThan(context.player.position, 18, "A liked-song tap must not apply the recent-list resume position")
            XCTAssertNil(context.player.errorMessage)
            XCTAssertEqual(context.library.playback.queue, expected)
            await context.assertNoCatalogRequests()
            context.player.pause()
        }
    }

    func testColdAndWarmRecentSelectionResumesTheSelectedRecordingInLiveRecentOrder() async throws {
        let oldMedia = try makeWidgetAudioFile()
        let selectedMedia = try makeWidgetAudioFile()
        let current = WidgetRouteFixtures.current
        let selected = WidgetRouteFixtures.selected
        let next = WidgetRouteFixtures.next
        let expected = [next, selected, current]
        for warm in [false, true] {
            let resolver = PlaybackFixtureResolver([
                current.id: .init(url: oldMedia, duration: 30),
                selected.id: .init(url: selectedMedia, duration: 30),
                next.id: .init(url: oldMedia, duration: 30),
            ])
            let snapshot = warm ? PlaybackSnapshot(queue: [current, next], position: 3.25) : PlaybackSnapshot()
            let context = try makeWidgetRouteContext(snapshot: snapshot, resolver: resolver) {
                $0.library.recordRecent(track: current, position: 3.25)
                $0.library.recordRecent(track: selected, position: 11.25)
                $0.library.recordRecent(track: next, position: 2)
            }
            if warm {
                context.player.resumePlayback()
                try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
                context.library.recordRecent(track: selected, position: 11.25)
                context.library.recordRecent(track: next, position: 2)
            }
            XCTAssertEqual(context.library.recentlyPlayed.map(\.track), expected)

            XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.playTrack(source: .recentlyPlayed, id: selected.id).url))

            XCTAssertEqual(context.player.queue, expected)
            XCTAssertEqual(context.player.currentTrack, selected)
            XCTAssertEqual(context.player.currentIndex, 1)
            XCTAssertEqual(context.player.position, 11.25)
            XCTAssertTrue(context.model.isPlayerPresented)
            try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 11.5 }
            XCTAssertEqual(context.player.currentStreamURL, selectedMedia)
            XCTAssertNil(context.player.errorMessage)
            XCTAssertEqual(context.library.playback.queue, expected)
            await context.assertNoCatalogRequests()
            context.player.pause()
        }
    }

    func testUnknownWrongCaseAndWrongSourceSelectionsAreHandledAsStaleWithoutCatalogLookup() async throws {
        let upper = AppModelFixtures.track("Widget-ID")
        let lower = AppModelFixtures.track("widget-id")
        let cases: [(MusicWidgetKind, String, LibrarySavedSongsView.Kind)] = [
            (.likedSongs, lower.id, .likes), (.recentlyPlayed, upper.id, .recents),
            (.likedSongs, "missing", .likes), (.recentlyPlayed, "missing", .recents),
        ]
        for (source, id, destination) in cases {
            let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback) {
                $0.library.toggleFavorite(upper)
                $0.library.recordRecent(track: lower, position: 11)
            }

            XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.playTrack(source: source, id: id).url))

            XCTAssertEqual(context.model.selectedTab, .library)
            XCTAssertEqual(context.model.widgetLibraryDestination, destination)
            XCTAssertTrue(context.model.toast?.contains("no longer") == true)
            XCTAssertFalse(context.model.isPlayerPresented)
            context.assertPausedPlayback(WidgetRouteFixtures.playback)
            let streams = await context.base.streams.streams.requests
            XCTAssertTrue(streams.isEmpty)
            await context.assertNoCatalogRequests()
        }
    }

    func testEmptySourceCannotPlayEvenWhenTheRequestedRecordingIsAlreadyCurrent() async throws {
        for source in [MusicWidgetKind.recentlyPlayed, .likedSongs] {
            let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback)
            XCTAssertTrue(context.library.favorites.isEmpty)
            XCTAssertTrue(context.library.recentlyPlayed.isEmpty)

            XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.playTrack(source: source, id: WidgetRouteFixtures.current.id).url))

            context.assertPausedPlayback(WidgetRouteFixtures.playback)
            XCTAssertNil(context.player.currentStreamURL)
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertEqual(context.model.widgetLibraryDestination, source == .likedSongs ? .likes : .recents)
            XCTAssertTrue(context.model.toast?.contains("no longer") == true)
            let streams = await context.base.streams.streams.requests
            XCTAssertTrue(streams.isEmpty)
        }
    }

    func testUnlikeAfterURLCaptureRefusesSelectionEvenIfTheSongRemainsInRecents() async throws {
        let selected = WidgetRouteFixtures.selected
        let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback) {
            $0.library.toggleFavorite(selected)
            $0.library.recordRecent(track: selected, position: 11)
        }
        let captured = MusicWidgetRoute.playTrack(source: .likedSongs, id: selected.id).url
        context.library.toggleFavorite(selected)
        XCTAssertTrue(context.library.favorites.isEmpty)
        XCTAssertEqual(context.library.recentlyPlayed.first?.track, selected)

        XCTAssertTrue(context.model.handleOpenURL(captured))

        context.assertPausedPlayback(WidgetRouteFixtures.playback)
        XCTAssertEqual(context.model.widgetLibraryDestination, .likes)
        XCTAssertTrue(context.model.toast?.contains("no longer") == true)
        XCTAssertFalse(context.model.isPlayerPresented)
        await context.assertNoCatalogRequests()
    }

    func testHistoryOffRefusesRetainedRecentAndSameCurrentRecentRoutes() async throws {
        let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback) {
            $0.library.recordRecent(track: WidgetRouteFixtures.current, position: 18)
            $0.library.recordRecent(track: WidgetRouteFixtures.selected, position: 11)
        }
        context.model.updatePreferences { $0.saveListeningHistory = false }
        XCTAssertEqual(context.library.recentlyPlayed.count, 2, "Disabling history retains the old rows")
        for track in [WidgetRouteFixtures.current, WidgetRouteFixtures.selected] {
            XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.playTrack(source: .recentlyPlayed, id: track.id).url))
            context.assertPausedPlayback(WidgetRouteFixtures.playback)
            XCTAssertEqual(context.model.widgetLibraryDestination, .recents)
            XCTAssertTrue(context.model.toast?.contains("history is off") == true)
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertFalse(context.library.preferences.saveListeningHistory)
        }
        let streams = await context.base.streams.streams.requests
        XCTAssertTrue(streams.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testHistoryOffStillAllowsExplicitLikedPlaybackWithoutRecordingANewRecent() async throws {
        let media = try makeWidgetAudioFile()
        let selected = WidgetRouteFixtures.selected
        let context = try makeWidgetRouteContext(resolver: PlaybackFileResolver(url: media, duration: 30)) {
            $0.library.toggleFavorite(selected)
            $0.library.recordRecent(track: WidgetRouteFixtures.current, position: 18)
        }
        context.model.updatePreferences { $0.saveListeningHistory = false }

        XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.playTrack(source: .likedSongs, id: selected.id).url))

        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.2 }
        XCTAssertEqual(context.player.currentTrack, selected)
        XCTAssertEqual(context.player.queue, [selected])
        XCTAssertEqual(context.player.currentStreamURL, media)
        XCTAssertTrue(context.model.isPlayerPresented)
        XCTAssertEqual(context.library.recentlyPlayed.map(\.id), [WidgetRouteFixtures.current.id])
        XCTAssertEqual(context.library.recentlyPlayed.first?.position, 18)
        await context.assertNoCatalogRequests()
    }

    func testSameCurrentRecentPreservesDuplicateQueueOccurrencePositionAndNativeStream() async throws {
        let media = try makeWidgetAudioFile()
        for paused in [false, true] {
            let resolver = PlaybackFileResolver(url: media, duration: 30)
            let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback, resolver: resolver)
            context.player.resumePlayback()
            try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
            if paused { context.player.pause() }
            context.library.recordRecent(track: WidgetRouteFixtures.current, position: 1)
            context.model.isSettingsPresented = true
            let resolutions = await resolver.refreshes
            let position = context.player.position

            XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.playTrack(source: .recentlyPlayed, id: WidgetRouteFixtures.current.id).url))

            XCTAssertEqual(context.player.queue, WidgetRouteFixtures.playback.queue)
            XCTAssertEqual(context.player.currentIndex, 2)
            XCTAssertEqual(context.player.position, position)
            XCTAssertEqual(context.player.currentStreamURL, media)
            XCTAssertEqual(context.library.playback.originalQueueIndices, [0, 2, 1])
            XCTAssertTrue(context.player.shuffleEnabled)
            XCTAssertEqual(context.player.repeatMode, .all)
            XCTAssertTrue(context.model.isPlayerPresented)
            XCTAssertFalse(context.model.isSettingsPresented)
            try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > position + 0.2 }
            let laterResolutions = await resolver.refreshes
            XCTAssertEqual(laterResolutions, resolutions)
            XCTAssertEqual(context.player.currentIndex, 2)
            await context.assertNoCatalogRequests()
            context.player.pause()
        }
    }

    func testSameCurrentRecentRetiresSuspendedRadioStartupEvenWhenItsReplyArrivesLater() async throws {
        let media = try makeWidgetAudioFile()
        let resolver = PlaybackFixtureResolver([
            WidgetRouteFixtures.current.id: .init(url: media, duration: 30),
            WidgetRouteFixtures.next.id: .init(url: media, duration: 30),
        ])
        let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback, resolver: resolver)
        context.player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
        let pending = context.model.startRadio(ExperienceRadioFixtures.melancholy)
        try await ExperienceRadioFixtures.answerSearches(context.base, from: 0, with: ExperienceRadioFixtures.melancholySearches)
        _ = try await context.base.catalog.autoplayRadios.request(at: 1)
        XCTAssertTrue(context.model.isLoadingRadio)
        context.library.recordRecent(track: WidgetRouteFixtures.current, position: 1)
        let position = context.player.position

        XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.playTrack(source: .recentlyPlayed, id: WidgetRouteFixtures.current.id).url))

        XCTAssertFalse(context.model.isLoadingRadio)
        XCTAssertTrue(context.model.isPlayerPresented)
        XCTAssertEqual(context.player.position, position)
        try await ExperienceRadioFixtures.answerRadios(context.base, from: 0, with: ExperienceRadioFixtures.melancholyRadios)
        await pending.value
        XCTAssertEqual(context.player.queue, WidgetRouteFixtures.playback.queue)
        XCTAssertEqual(context.player.currentIndex, 2)
        XCTAssertEqual(context.player.currentTrack, WidgetRouteFixtures.current)
        XCTAssertEqual(context.player.currentStreamURL, media)
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertGreaterThanOrEqual(context.player.position, position)
        XCTAssertFalse(context.player.isRadioSession)
        XCTAssertNil(context.model.activeRadioExperience)
        XCTAssertNil(context.model.selectedRadioExperience)
        XCTAssertNil(context.model.radioError)
        let resolutions = await resolver.requests
        XCTAssertEqual(resolutions.map(\.trackID), [WidgetRouteFixtures.current.id])
    }
}
