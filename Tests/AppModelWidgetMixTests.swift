import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelWidgetMixTests: XCTestCase {
    func testSavedMixBrowsingUsesHomeProjectionWithoutRegeneratingAnOldPeriod() async throws {
        for kind in GeneratedPlaylistKind.allCases {
            let mix = WidgetRouteFixtures.mix(kind, period: "saved-old-period")
            let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback, generatesMixes: true) {
                _ = $0.seedListener(primary: WidgetRouteFixtures.selected)
                $0.library.saveMix(mix)
            }
            context.model.selectedTab = .search
            context.model.isPlayerPresented = true
            for capturedPeriod in [mix.periodKey, "stale-widget-period"] {
                XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.mix(kind: kind, periodKey: capturedPeriod, play: false).url))

                XCTAssertEqual(context.model.selectedTab, .home)
                XCTAssertEqual(context.model.navigationPaths[.home], [mix.collection])
                XCTAssertEqual(context.model.navigationPaths[.home]?.last?.tracks, mix.tracks)
                XCTAssertEqual(context.model.navigationPaths[.home]?.last?.id, "mix.\(kind.rawValue)")
                XCTAssertNil(context.model.widgetLibraryDestination)
                XCTAssertFalse(context.model.isPlayerPresented)
                XCTAssertFalse(context.model.isGeneratingMixes)
                XCTAssertEqual(context.library.mix(kind), mix)
                context.assertPausedPlayback(WidgetRouteFixtures.playback)
                await context.assertNoCatalogRequests()
            }
        }
    }

    func testSavedMixPlaybackUsesRequestedKindAndFullSavedQueueRatherThanWidgetPreview() async throws {
        let media = try makeWidgetAudioFile()
        for kind in GeneratedPlaylistKind.allCases {
            let tracks = (0..<8).map { AppModelFixtures.track("saved-\(kind.rawValue)-\($0)") }
            let mix = WidgetRouteFixtures.mix(kind, period: "captured-saved-period", tracks: tracks)
            let otherKind: GeneratedPlaylistKind = kind == .dailyMix ? .discoverWeekly : .dailyMix
            let other = WidgetRouteFixtures.mix(otherKind, period: "other-period", tracks: [WidgetRouteFixtures.newer])
            let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback,
                resolver: PlaybackFileResolver(url: media, duration: 30), generatesMixes: true) {
                _ = $0.seedListener(primary: WidgetRouteFixtures.selected)
                $0.library.saveMix(mix)
                $0.library.saveMix(other)
            }
            let preview = WidgetLibrarySnapshot.projection(recentlyPlayed: [], likedSongs: [], mixes: [mix])
            XCTAssertEqual(preview.mixes.first?.tracks.count, 6)

            XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.mix(kind: kind, periodKey: mix.periodKey, play: true).url))

            XCTAssertEqual(context.player.queue, tracks)
            XCTAssertEqual(context.player.currentTrack, tracks.first)
            XCTAssertEqual(context.player.currentIndex, 0)
            XCTAssertEqual(context.player.position, 0)
            XCTAssertFalse(context.player.shuffleEnabled)
            XCTAssertTrue(context.model.isPlayerPresented)
            XCTAssertFalse(context.model.isGeneratingMixes)
            try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.2 }
            XCTAssertEqual(context.player.currentStreamURL, media)
            XCTAssertEqual(context.library.mix(kind), mix)
            XCTAssertEqual(context.library.mix(otherKind), other)
            await context.assertNoCatalogRequests()
            context.player.pause()
        }
    }

    func testReplacedMixPeriodOpensCurrentSavedMixWithoutAutoplay() async throws {
        for kind in GeneratedPlaylistKind.allCases {
            let previous = WidgetRouteFixtures.mix(kind, period: "previous-period")
            let replacement = WidgetRouteFixtures.mix(kind, period: "replacement-period", tracks: [WidgetRouteFixtures.newer])
            let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback, generatesMixes: true) {
                _ = $0.seedListener(primary: WidgetRouteFixtures.selected)
                $0.library.saveMix(previous)
            }
            let captured = MusicWidgetRoute.mix(kind: kind, periodKey: previous.periodKey, play: true).url
            context.library.saveMix(replacement)

            XCTAssertTrue(context.model.handleOpenURL(captured))

            XCTAssertEqual(context.model.selectedTab, .home)
            XCTAssertEqual(context.model.navigationPaths[.home], [replacement.collection])
            XCTAssertTrue(context.model.toast?.contains("refreshed") == true)
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertFalse(context.model.isGeneratingMixes)
            XCTAssertEqual(context.library.mix(kind), replacement)
            context.assertPausedPlayback(WidgetRouteFixtures.playback)
            let streams = await context.base.streams.streams.requests
            XCTAssertTrue(streams.isEmpty)
            await context.assertNoCatalogRequests()
        }
    }

    func testMissingAndDislikedAwayMixesOpenHomeWithAnExplanationWithoutGeneration() async throws {
        for kind in GeneratedPlaylistKind.allCases {
            for removeSavedMix in [false, true] {
                let mix = WidgetRouteFixtures.mix(kind, tracks: [WidgetRouteFixtures.selected])
                let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback, generatesMixes: true) {
                    _ = $0.seedListener(primary: WidgetRouteFixtures.current)
                    if removeSavedMix { $0.library.saveMix(mix) }
                }
                if removeSavedMix { context.library.toggleDislike(WidgetRouteFixtures.selected) }
                XCTAssertNil(context.library.mix(kind))
                for play in [false, true] {
                    XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.mix(kind: kind, periodKey: mix.periodKey, play: play).url))
                    XCTAssertEqual(context.model.selectedTab, .home)
                    XCTAssertEqual(context.model.navigationPaths[.home], [])
                    XCTAssertTrue(context.model.toast?.contains("no longer available") == true)
                    XCTAssertFalse(context.model.isPlayerPresented)
                    XCTAssertFalse(context.model.isGeneratingMixes)
                    context.assertPausedPlayback(WidgetRouteFixtures.playback)
                }
                await context.assertNoCatalogRequests()
            }
        }
    }
}
