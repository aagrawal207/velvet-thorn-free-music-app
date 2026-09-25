import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelWidgetNavigationTests: XCTestCase {
    func testHeadingsOpenTypedLibraryDestinationsOrHomeWithoutChangingSavedPlayback() async throws {
        let cases: [(MusicWidgetKind, AppTab, LibrarySavedSongsView.Kind?)] = [
            (.recentlyPlayed, .library, .recents), (.likedSongs, .library, .likes), (.mixes, .home, nil),
        ]
        let snapshot = WidgetRouteFixtures.playback
        let detail = MusicCollection(id: "previous-album", title: "Previous album", kind: .album)
        for (kind, tab, destination) in cases {
            let context = try makeWidgetRouteContext(snapshot: snapshot)
            let model = context.model
            model.navigationPaths = [.home: [detail], .library: [detail]]
            model.selectedTab = .search
            model.isPlayerPresented = true
            model.isSettingsPresented = true
            let root = model.libraryRootGeneration

            XCTAssertTrue(model.handleOpenURL(MusicWidgetRoute.open(kind).url))

            XCTAssertEqual(model.selectedTab, tab)
            XCTAssertEqual(model.widgetLibraryDestination, destination)
            XCTAssertEqual(model.navigationPaths[.library], [])
            if kind == .mixes { XCTAssertEqual(model.navigationPaths[.home], []) }
            XCTAssertNotEqual(model.libraryRootGeneration, root)
            XCTAssertFalse(model.isPlayerPresented)
            XCTAssertFalse(model.isSettingsPresented)
            XCTAssertNil(model.toast)
            context.assertPausedPlayback(snapshot)
            XCTAssertNil(context.player.currentStreamURL)
            await context.assertNoCatalogRequests()
        }
    }

    func testHeadingBrowsingKeepsNativeAudioPlayingAtItsExistingPosition() async throws {
        let media = try makeWidgetAudioFile()
        let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback,
            resolver: PlaybackFileResolver(url: media, duration: 30))
        context.player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
        for kind in MusicWidgetKind.allCases {
            let position = context.player.position

            XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.open(kind).url))

            XCTAssertEqual(context.player.queue, WidgetRouteFixtures.playback.queue)
            XCTAssertEqual(context.player.currentIndex, 2)
            XCTAssertEqual(context.player.position, position)
            XCTAssertEqual(context.player.currentStreamURL, media)
            XCTAssertTrue(context.player.isPlaying)
            XCTAssertFalse(context.player.isLoading)
            XCTAssertFalse(context.model.isPlayerPresented)
            try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > position + 0.2 }
        }
        await context.assertNoCatalogRequests()
    }

    func testInvalidWidgetURLsLeavePlaybackNavigationAndPresentationUntouched() async throws {
        let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback)
        let model = context.model
        let detail = MusicCollection(id: "keep-album", title: "Keep album", kind: .album)
        model.selectedTab = .search
        model.navigationPaths[.search] = [detail]
        model.searchQuery = "Keep this draft"
        model.isSettingsPresented = true
        let paths = model.navigationPaths
        let root = model.libraryRootGeneration
        for raw in ["ganabajana://widget/play?source=likedSongs&id=one&id=two",
                    "ganabajana://widget/open?kind=unknown", "https://widget/open?kind=mixes",
                    "ganabajana://elsewhere/open?kind=likedSongs"] {
            XCTAssertFalse(model.handleOpenURL(try XCTUnwrap(URL(string: raw))))
            XCTAssertEqual(model.selectedTab, .search)
            XCTAssertEqual(model.navigationPaths, paths)
            XCTAssertEqual(model.libraryRootGeneration, root)
            XCTAssertEqual(model.searchQuery, "Keep this draft")
            XCTAssertTrue(model.isSettingsPresented)
            XCTAssertFalse(model.isPlayerPresented)
            XCTAssertNil(model.widgetLibraryDestination)
            XCTAssertNil(model.toast)
            context.assertPausedPlayback(WidgetRouteFixtures.playback)
        }
        let streams = await context.base.streams.streams.requests
        XCTAssertTrue(streams.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testExistingSearchURLStillOpensSearchAfterWidgetBrowsing() async throws {
        let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback)
        XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.open(.likedSongs).url))
        let url = try XCTUnwrap(URL(string: "ganabajana://search?q=Dream%20pop%20%E9%9B%AA"))

        XCTAssertTrue(context.model.handleOpenURL(url))

        XCTAssertEqual(context.model.selectedTab, .search)
        XCTAssertEqual(context.model.searchQuery, "Dream pop 雪")
        XCTAssertEqual(context.model.searchFilter, .songs)
        XCTAssertEqual(context.model.navigationPaths[.search], [])
        XCTAssertFalse(context.model.isPlayerPresented)
        context.assertPausedPlayback(WidgetRouteFixtures.playback)
        await context.assertNoCatalogRequests()
    }

    func testRecognizedRoutesCannotBypassIncompleteWelcomeEvenWithSavedMusic() async throws {
        let mix = WidgetRouteFixtures.mix()
        let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback, completedWelcome: false) {
            $0.library.toggleFavorite(WidgetRouteFixtures.selected)
            $0.library.recordRecent(track: WidgetRouteFixtures.current, position: 11)
            $0.library.saveMix(mix)
        }
        let model = context.model
        model.selectedTab = .search
        model.isSettingsPresented = true
        let saved = try Data(contentsOf: context.libraryURL)
        let routes = MusicWidgetKind.allCases.map(MusicWidgetRoute.open) + [
            .playTrack(source: .likedSongs, id: WidgetRouteFixtures.selected.id),
            .playTrack(source: .recentlyPlayed, id: WidgetRouteFixtures.current.id),
            .mix(kind: mix.kind, periodKey: mix.periodKey, play: false),
            .mix(kind: mix.kind, periodKey: mix.periodKey, play: true),
        ]
        for route in routes {
            XCTAssertTrue(model.handleOpenURL(route.url), "Recognized but unavailable routes are still handled")
            XCTAssertEqual(model.selectedTab, .search)
            XCTAssertNil(model.widgetLibraryDestination)
            XCTAssertTrue(model.isSettingsPresented)
            XCTAssertFalse(model.isPlayerPresented)
            XCTAssertNil(model.widgetOpenTask)
            XCTAssertFalse(context.library.preferences.hasCompletedWelcome)
            context.assertPausedPlayback(WidgetRouteFixtures.playback)
        }
        XCTAssertEqual(try Data(contentsOf: context.libraryURL), saved)
        let streams = await context.base.streams.streams.requests
        XCTAssertTrue(streams.isEmpty)
        await context.assertNoCatalogRequests()
    }

    func testUnsupportedCorruptAndFutureStartupLibrariesAreHandledWithoutOverwritingTheirBytes() async throws {
        let invalid = [Data("{broken library".utf8), Data("{\"version\":0}".utf8),
                       Data("{\"version\":\(LibraryPersistence.currentVersion + 1),\"future\":\"keep\"}".utf8)]
        for bytes in invalid {
            let context = try makeWidgetRouteContext {
                try bytes.write(to: $0.directory.appendingPathComponent(LibraryPersistence.fileName), options: .atomic)
            }
            XCTAssertFalse(context.library.hasLoadedDocument)
            XCTAssertTrue(context.library.requiresReload)
            for route in [MusicWidgetRoute.open(.likedSongs), .playTrack(source: .recentlyPlayed, id: "saved-song"),
                          .mix(kind: .dailyMix, periodKey: "saved-day", play: true)] {
                XCTAssertTrue(context.model.handleOpenURL(route.url))
                XCTAssertEqual(context.model.selectedTab, .library)
                XCTAssertNil(context.model.widgetLibraryDestination)
                XCTAssertFalse(context.model.isPlayerPresented)
                XCTAssertTrue(context.player.queue.isEmpty)
                XCTAssertEqual(context.player.position, 0)
                XCTAssertFalse(context.player.isLoading)
                XCTAssertFalse(context.player.isPlaying)
                XCTAssertTrue(context.model.toast?.contains("Reload") == true)
                XCTAssertEqual(try Data(contentsOf: context.libraryURL), bytes)
            }
            let streams = await context.base.streams.streams.requests
            XCTAssertTrue(streams.isEmpty)
            await context.assertNoCatalogRequests()
        }
    }

    func testDirectRouteChecksExternallyReplacedOrDeletedActualLibraryBeforePlayback() async throws {
        for deleted in [false, true] {
            let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback) {
                $0.library.toggleFavorite(WidgetRouteFixtures.selected)
            }
            let route = MusicWidgetRoute.playTrack(source: .likedSongs, id: WidgetRouteFixtures.selected.id)
            let external = LibraryStore(directory: context.base.directory)
            external.toggleFavorite(WidgetRouteFixtures.selected)
            XCTAssertNil(external.errorMessage)
            let externalBytes = try Data(contentsOf: context.libraryURL)
            if deleted { try FileManager.default.removeItem(at: context.libraryURL) }
            XCTAssertEqual(context.library.favorites, [WidgetRouteFixtures.selected])
            XCTAssertFalse(context.library.requiresReload)

            XCTAssertTrue(context.model.handleOpenURL(route.url))

            XCTAssertFalse(context.library.widgetLibrarySourceIsAvailable)
            XCTAssertEqual(context.model.selectedTab, .library)
            XCTAssertNil(context.model.widgetLibraryDestination)
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertTrue(context.model.toast?.contains("Reload") == true)
            context.assertPausedPlayback(WidgetRouteFixtures.playback)
            if deleted { XCTAssertFalse(FileManager.default.fileExists(atPath: context.libraryURL.path)) }
            else { XCTAssertEqual(try Data(contentsOf: context.libraryURL), externalBytes) }
            let streams = await context.base.streams.streams.requests
            XCTAssertTrue(streams.isEmpty)
            await context.assertNoCatalogRequests()
        }
    }

    func testDirectRecentRouteAfterExternalClearRedactsPublishedMetadataAndArtworkWithoutLifecycleRefresh() async throws {
        let recent = WidgetSnapshotTestData.artworkTrack("private-widget-recent")
        let mixed = WidgetSnapshotTestData.artworkTrack("private-widget-mix")
        let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback) {
            $0.library.recordRecent(track: recent, position: 11)
            $0.library.saveMix(WidgetRouteFixtures.mix(tracks: [mixed]))
            $0.library.toggleFavorite(WidgetRouteFixtures.selected)
        }
        let store = WidgetSnapshotStore(directory: context.base.directory.appendingPathComponent("widgets"))
        let image = WidgetSnapshotTestData.jpeg()
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(library: context.library, store: store, thumbnail: { _ in image }) { reloads += 1 }
        try await PlaybackTestSupport.waitUntil { store.read().artwork.count == 2 }
        let baselineReloads = reloads
        let external = LibraryStore(directory: context.base.directory)
        external.clearHistory()
        XCTAssertNil(external.errorMessage)
        let clearedBytes = try Data(contentsOf: context.libraryURL)
        XCTAssertEqual(store.read().recentlyPlayed.map(\.id), [recent.id])
        XCTAssertFalse(store.read().mixes.isEmpty)

        XCTAssertTrue(context.model.handleOpenURL(MusicWidgetRoute.playTrack(source: .recentlyPlayed, id: recent.id).url))

        let redacted = store.read()
        XCTAssertEqual(redacted.availability, .unavailable)
        XCTAssertFalse(redacted.historyEnabled)
        XCTAssertTrue(redacted.displayedTracks.isEmpty)
        XCTAssertTrue(redacted.mixes.isEmpty)
        XCTAssertTrue(redacted.mixSongCounts.isEmpty)
        XCTAssertTrue(redacted.artwork.isEmpty)
        XCTAssertEqual(reloads, baselineReloads + 1)
        XCTAssertEqual(try Data(contentsOf: context.libraryURL), clearedBytes)
        context.assertPausedPlayback(WidgetRouteFixtures.playback)
        XCTAssertFalse(context.model.isPlayerPresented)
        await context.assertNoCatalogRequests()
        withExtendedLifetime(publisher) { }
    }

    func testLocalHistoryClearPublishesRedactionAndMakesCapturedRecentRouteStale() async throws {
        let recent = WidgetRouteFixtures.selected
        let context = try makeWidgetRouteContext(snapshot: WidgetRouteFixtures.playback) {
            $0.library.recordRecent(track: recent, position: 11)
            $0.library.saveMix(WidgetRouteFixtures.mix())
            $0.library.toggleFavorite(WidgetRouteFixtures.next)
        }
        let store = WidgetSnapshotStore(directory: context.base.directory.appendingPathComponent("widgets"))
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(library: context.library, store: store, thumbnail: { _ in nil }) { reloads += 1 }
        let route = MusicWidgetRoute.playTrack(source: .recentlyPlayed, id: recent.id)
        XCTAssertEqual(store.read().recentlyPlayed.map(\.id), [recent.id])

        context.library.clearHistory()
        XCTAssertTrue(context.model.handleOpenURL(route.url))

        let cleared = store.read()
        XCTAssertEqual(cleared.availability, .ready)
        XCTAssertTrue(cleared.historyEnabled)
        XCTAssertTrue(cleared.recentlyPlayed.isEmpty)
        XCTAssertTrue(cleared.mixes.isEmpty)
        XCTAssertTrue(cleared.mixSongCounts.isEmpty)
        XCTAssertEqual(cleared.likedSongs.map(\.id), [WidgetRouteFixtures.next.id])
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(context.model.widgetLibraryDestination, .recents)
        XCTAssertTrue(context.model.toast?.contains("no longer") == true)
        context.assertPausedPlayback(WidgetRouteFixtures.playback)
        await context.assertNoCatalogRequests()
        withExtendedLifetime(publisher) { }
    }
}
