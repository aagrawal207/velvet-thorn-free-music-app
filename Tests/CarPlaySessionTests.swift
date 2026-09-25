import CarPlay
import MediaPlayer
import XCTest
@testable import GanaBajana

@MainActor
final class CarPlaySessionTests: CarPlayTestCase {
    func testColdCarPlayLaunchUsesTheInstalledRuntimeWithoutAPhoneView() async throws {
        let track = libraryTestTrack("carplay-restored")
        let saved = PlaybackSnapshot(queue: [track], position: 42)
        let context = try makeContext(snapshot: saved)
        let previousRuntime = CompanionRuntime.playback
        CompanionRuntime.playback = CompanionPlaybackController(model: context.model)
        defer { CompanionRuntime.playback = previousRuntime }
        let interface = CarPlayTestInterface()
        let session = CarPlaySessionController(interface: interface, limits: CarPlayTemplateLimits(tabs: 4, items: 20, sections: 1))
        defer { session.disconnect() }
        session.connect()
        let queue = try rootList(session, at: 3)
        try await waitForRows(1, in: queue)
        XCTAssertEqual(rows(queue).first?.text, track.title)
        XCTAssertEqual(context.player.currentTrack, track)
        XCTAssertEqual(context.player.position, 42)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertEqual(context.library.playback.queue, saved.queue)
        XCTAssertEqual(context.library.playback.position, saved.position)
        XCTAssertEqual(context.library.playback.currentIndex, saved.currentIndex)
        XCTAssertEqual(context.library.playback.shuffleEnabled, saved.shuffleEnabled)
        XCTAssertEqual(context.library.playback.repeatMode, saved.repeatMode)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String, track.id)
        let streams = await context.streams.streams.requests
        XCTAssertTrue(streams.isEmpty)
        XCTAssertEqual(NSStringFromClass(CarPlaySceneDelegate.self), "GanaBajana.CarPlaySceneDelegate")
    }

    func testMissingRegistryShowsAClearRetryAndCanBindLater() async throws {
        let context = try makeContext()
        let favorite = libraryTestTrack("carplay-late-registry")
        context.library.toggleFavorite(favorite)
        let registry = CarPlayTestRegistry()
        let interface = CarPlayTestInterface()
        let session = CarPlaySessionController(interface: interface, limits: CarPlayTemplateLimits(tabs: 4, items: 20, sections: 1),
                                               playbackProvider: { registry.playback })
        defer { session.disconnect() }
        session.connect()
        let favorites = try rootList(session, at: 0)
        try await waitForRows(2, in: favorites)
        XCTAssertEqual(rows(favorites).first?.text, "Breezy isn’t ready")
        XCTAssertFalse(try XCTUnwrap(rows(favorites).first).isEnabled)
        registry.playback = CompanionPlaybackController(model: context.model)
        try select(try retryRow(favorites))
        XCTAssertEqual(rows(favorites).map(\.text), [favorite.title])
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertEqual(interface.operations, [.root])
    }

    func testPlaylistSelectionMutatesTheSharedPhoneQueueAndCompletesBeforePresentation() async throws {
        let context = try makeContext()
        let tracks = [libraryTestTrack("carplay-playlist-a"), libraryTestTrack("carplay-playlist-b")]
        let id = context.library.createPlaylist(name: "On the road")
        tracks.forEach { context.library.add($0, to: id) }
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let playlists = try rootList(session, at: 2)
        try await waitForRows(1, in: playlists)
        try interface.selectTab(at: 2)
        let folder = try XCTUnwrap(rows(playlists).first)
        XCTAssertEqual(folder.accessoryType, .disclosureIndicator)
        try select(folder)
        let songs = try XCTUnwrap(interface.topTemplate as? CPListTemplate)
        XCTAssertEqual(songs.title, "On the road")
        XCTAssertEqual(rows(songs).map(\.text), tracks.map(\.title))
        interface.automaticallyCompletes = false
        let completion = try select(try XCTUnwrap(rows(songs).last))
        XCTAssertEqual(context.player.queue, tracks)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertTrue(context.player.isLoading)
        XCTAssertEqual(interface.pendingCount, 1)
        XCTAssertEqual(completion.value, 1)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String, tracks[1].id)
        try interface.completeNext()
        XCTAssertTrue(interface.topTemplate === CPNowPlayingTemplate.shared)
        XCTAssertEqual(completion.value, 1)
    }

    func testReorderedQueueRejectsTheOldRevisionThenReloadsTheCorrectOccurrence() async throws {
        let tracks = [libraryTestTrack("carplay-queue-a"), libraryTestTrack("carplay-queue-b"), libraryTestTrack("carplay-queue-c")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: tracks))
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let queue = try rootList(session, at: 3)
        try await waitForRows(3, in: queue)
        try interface.selectTab(at: 3)
        let oldRow = rows(queue)[1]
        context.player.moveQueue(from: IndexSet(integer: 1), to: 0)
        try select(oldRow)
        XCTAssertEqual(context.player.currentTrack, tracks[0])
        XCTAssertFalse(context.player.isLoading)
        XCTAssertEqual(rows(queue).first?.text, "Couldn’t play this song")
        try select(try retryRow(queue))
        XCTAssertEqual(rows(queue).map(\.text), [tracks[1].title, tracks[0].title, tracks[2].title])
        try select(try XCTUnwrap(rows(queue).first))
        XCTAssertEqual(context.player.currentTrack, tracks[1])
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertTrue(interface.topTemplate === CPNowPlayingTemplate.shared)
    }

    func testDuplicateQueueSelectionKeepsRadioAndCancelsThePhonesPendingStationIntent() async throws {
        let context = try makeContext()
        let track = libraryTestTrack("carplay-radio-repeat")
        let tracks = [track, track]
        context.player.play(tracks, isRadio: true)
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let queue = try rootList(session, at: 3)
        try await waitForRows(2, in: queue)
        try interface.selectTab(at: 3)
        let pending = context.model.startRadio(ExperienceRadioFixtures.melancholy)
        _ = try await context.catalog.searches.request(at: 1)
        XCTAssertTrue(context.model.isLoadingRadio)
        try select(try XCTUnwrap(rows(queue).last))
        XCTAssertFalse(context.model.isLoadingRadio, "Queue selection must pass through MusicAppModel.playQueueTrack")
        XCTAssertTrue(context.player.isRadioSession)
        XCTAssertEqual(context.player.queue, tracks)
        XCTAssertEqual(context.player.currentIndex, 1)
        try await ExperienceRadioFixtures.answerSearches(context, from: 0, with: ExperienceRadioFixtures.melancholySearches)
        await pending.value
        XCTAssertEqual(context.player.currentTrack, tracks[1])
    }

    func testLatestSongSelectionWinsWhileAnOlderNowPlayingPushIsPending() async throws {
        let context = try makeContext()
        let first = libraryTestTrack("carplay-old-intent")
        let second = libraryTestTrack("carplay-new-intent")
        context.library.toggleFavorite(first)
        context.library.toggleFavorite(second)
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let favorites = try rootList(session, at: 0)
        try await waitForRows(2, in: favorites)
        let firstRow = try XCTUnwrap(rows(favorites).first { $0.text == first.title })
        let secondRow = try XCTUnwrap(rows(favorites).first { $0.text == second.title })
        interface.automaticallyCompletes = false
        let oldCompletion = try select(firstRow)
        let newCompletion = try select(secondRow)
        XCTAssertEqual(context.player.currentTrack, second)
        XCTAssertEqual(interface.pendingCount, 1)
        try interface.completeNext(success: false, message: "Obsolete push failure")
        XCTAssertEqual(rows(favorites).count, 2)
        XCTAssertEqual(interface.pendingCount, 1)
        try interface.completeNext()
        XCTAssertTrue(interface.topTemplate === CPNowPlayingTemplate.shared)
        XCTAssertEqual(oldCompletion.value, 1)
        XCTAssertEqual(newCompletion.value, 1)
    }

    func testExtrasUseThePhoneControllerAndReflectDurableFavoriteShuffleAndRepeat() async throws {
        let track = libraryTestTrack("carplay-controls")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [track]))
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let controls = try XCTUnwrap(session.nowPlayingControls)
        XCTAssertEqual(controls.buttons.count, 3)
        controls.activate(.favorite)
        XCTAssertTrue(context.library.isFavorite(track))
        XCTAssertTrue(LibraryStore(directory: context.directory).isFavorite(track))
        XCTAssertTrue(controls.buttons[2].isSelected)
        controls.activate(.shuffle)
        XCTAssertTrue(context.player.shuffleEnabled)
        XCTAssertTrue(controls.buttons[0].isSelected)
        for expected in [RepeatMode.all, .one, .off] {
            controls.activate(.repeatMode)
            XCTAssertEqual(context.player.repeatMode, expected)
            XCTAssertEqual(controls.buttons[1].isSelected, expected != .off)
        }
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertEqual(interface.operations, [.root])
    }

    func testAnOldTrackControlCannotMutateANewerPhoneSelection() throws {
        let old = libraryTestTrack("carplay-control-old")
        let new = libraryTestTrack("carplay-control-new")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [old]))
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let controls = try XCTUnwrap(session.nowPlayingControls)
        context.model.play(new)
        controls.activate(.favorite)
        XCTAssertFalse(context.library.isFavorite(old))
        XCTAssertFalse(context.library.isFavorite(new))
        XCTAssertEqual(context.player.currentTrack, new)
        XCTAssertEqual(interface.operations, [.root])
    }

    func testADelayedControlDoesNotUndoANewerPhoneRepeatChoice() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack("carplay-repeat-intent")]))
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let controls = try XCTUnwrap(session.nowPlayingControls)
        context.player.cycleRepeatMode()
        context.player.cycleRepeatMode()
        controls.activate(.repeatMode)
        XCTAssertEqual(context.player.repeatMode, .one)
        XCTAssertTrue(controls.buttons[1].isSelected)
        controls.activate(.repeatMode)
        XCTAssertEqual(context.player.repeatMode, .off)
    }

    func testReplacingTheRegistryRequiresReloadEvenForIdenticalLibraryRows() async throws {
        let context = try makeContext()
        let track = libraryTestTrack("carplay-replaced-registry")
        context.library.toggleFavorite(track)
        let registry = CarPlayTestRegistry()
        registry.playback = CompanionPlaybackController(model: context.model)
        let interface = CarPlayTestInterface()
        let session = CarPlaySessionController(interface: interface, limits: CarPlayTemplateLimits(tabs: 4, items: 20, sections: 1),
                                               playbackProvider: { registry.playback })
        defer { session.disconnect() }
        session.connect()
        let favorites = try rootList(session, at: 0)
        try await waitForRows(1, in: favorites)
        let oldRow = try XCTUnwrap(rows(favorites).first)
        registry.playback = CompanionPlaybackController(model: context.model)
        try select(oldRow)
        XCTAssertNil(context.player.currentTrack)
        XCTAssertEqual(rows(favorites).first?.text, "Your player changed")
        try select(try retryRow(favorites))
        try select(try XCTUnwrap(rows(favorites).first))
        XCTAssertEqual(context.player.currentTrack, track)
    }

    func testPlaybackFailureHasAFreshRetryWithoutHoldingTheOriginalListCompletion() async throws {
        let context = try makeContext()
        let track = libraryTestTrack("carplay-failing-stream")
        context.library.toggleFavorite(track)
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let favorites = try rootList(session, at: 0)
        try await waitForRows(1, in: favorites)
        let completion = try select(try XCTUnwrap(rows(favorites).first))
        let request = try await context.streams.streams.request(at: 0)
        try await context.streams.streams.complete(request, with: .failure(MusicServiceError.unavailable("Fixture playback failed")))
        try await AppModelFixtures.eventually { (interface.topTemplate as? CPListTemplate)?.title == "Playback" }
        let error = try XCTUnwrap(interface.topTemplate as? CPListTemplate)
        XCTAssertEqual(context.player.errorMessage, "Fixture playback failed")
        XCTAssertEqual(rows(error).first?.detailText, "Playback couldn’t continue. Open Breezy on your iPhone to try again.")
        try select(try retryRow(error))
        XCTAssertTrue(interface.topTemplate === CPNowPlayingTemplate.shared)
        XCTAssertTrue(context.player.isLoading)
        XCTAssertNil(context.player.errorMessage)
        _ = try await context.streams.streams.request(at: 1)
        XCTAssertEqual(completion.value, 1)
    }

    func testGenuinePlaybackFailureStillOffersRetryAlongsideALibraryError() async throws {
        let context = try makeContext()
        let track = libraryTestTrack("carplay-playback-and-library-failure")
        context.library.toggleFavorite(track)
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let favorites = try rootList(session, at: 0)
        try await waitForRows(1, in: favorites)
        let completion = try select(try XCTUnwrap(rows(favorites).first))
        let request = try await context.streams.streams.request(at: 0)
        let external = LibraryStore(directory: context.directory)
        external.toggleFavorite(libraryTestTrack("carplay-concurrent-library-write"))
        context.library.toggleFavorite(track)
        XCTAssertTrue(context.library.requiresReload)
        try await context.streams.streams.complete(request, with: .failure(MusicServiceError.unavailable("Genuine playback failure")))

        try await AppModelFixtures.eventually { (interface.topTemplate as? CPListTemplate)?.title == "Playback" }
        let error = try XCTUnwrap(interface.topTemplate as? CPListTemplate)
        XCTAssertEqual(rows(error).first?.detailText, "Playback couldn’t continue. Open Breezy on your iPhone to try again.")
        XCTAssertEqual(context.player.errorMessage, "Genuine playback failure")
        XCTAssertTrue(context.library.requiresReload)
        let retry = try retryRow(error)
        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        let retried = try select(retry)
        XCTAssertTrue(interface.topTemplate === CPNowPlayingTemplate.shared)
        XCTAssertTrue(context.player.isLoading)
        XCTAssertNil(context.player.errorMessage)
        _ = try await context.streams.streams.request(at: 1)
        XCTAssertEqual(completion.value, 1)
        XCTAssertEqual(retried.value, 1)
    }

    func testLibrarySelectionFailureOffersReadOnlyReloadAfterPhoneRecovery() async throws {
        let track = libraryTestTrack("carplay-library-recovery")
        let externalTrack = libraryTestTrack("carplay-external-favorite")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [track], position: 17))
        context.library.toggleFavorite(track)
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let favorites = try rootList(session, at: 0)
        try await waitForRows(1, in: favorites)
        let oldRow = try XCTUnwrap(rows(favorites).first)
        let external = LibraryStore(directory: context.directory)
        external.toggleFavorite(externalTrack)
        context.library.toggleFavorite(track)
        XCTAssertTrue(context.library.requiresReload)

        let completion = try select(oldRow)
        XCTAssertEqual(rows(favorites).first?.text, "Library needs attention")
        XCTAssertEqual(rows(favorites).first?.detailText, "Your library change couldn’t be saved. Open Breezy on your iPhone to try again.")
        XCTAssertFalse(rows(favorites).contains { $0.text == "Retry" })
        XCTAssertEqual(favorites.trailingNavigationBarButtons.first?.title, "Reload")
        let reload = try select(try XCTUnwrap(rows(favorites).first { $0.text == "Reload" }))
        XCTAssertTrue(context.library.requiresReload, "CarPlay Reload only browses; recovery requires the phone model")
        XCTAssertEqual(rows(favorites).first?.text, "Library needs attention")
        XCTAssertTrue(context.library.isFavorite(track))

        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        try select(try XCTUnwrap(rows(favorites).first { $0.text == "Reload" }))
        XCTAssertEqual(Set(rows(favorites).compactMap(\.text)), [track.title, externalTrack.title])
        XCTAssertEqual(context.player.currentTrack, track)
        XCTAssertEqual(context.player.position, 17)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertEqual(interface.operations, [.root])
        XCTAssertEqual(completion.value, 1)
        XCTAssertEqual(reload.value, 1)
        let requests = await context.streams.streams.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUpNextUsesTheObserverAndAnOldCallbackCannotInterruptANewTab() async throws {
        let track = libraryTestTrack("carplay-up-next")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [track]))
        context.library.toggleFavorite(track)
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let favorites = try rootList(session, at: 0)
        try await waitForRows(1, in: favorites)
        try select(try XCTUnwrap(rows(favorites).first))
        let controls = try XCTUnwrap(session.nowPlayingControls)
        let nowPlaying = CPNowPlayingTemplate.shared
        await Task.detached { controls.nowPlayingTemplateUpNextButtonTapped(nowPlaying) }.value
        try await AppModelFixtures.eventually { (interface.topTemplate as? CPListTemplate)?.title == "Queue" }
        let queue = try XCTUnwrap(interface.topTemplate as? CPListTemplate)
        XCTAssertEqual(rows(queue).map(\.text), [track.title])
        try select(try XCTUnwrap(rows(queue).first))
        XCTAssertTrue(interface.topTemplate === CPNowPlayingTemplate.shared)
        XCTAssertEqual(interface.templates.filter { $0 === CPNowPlayingTemplate.shared }.count, 1)
        controls.nowPlayingTemplateUpNextButtonTapped(.shared)
        try interface.selectTab(at: 2)
        let playlists = interface.topTemplate
        await Task.yield()
        XCTAssertTrue(interface.topTemplate === playlists)
    }

    func testRootFailureFallsBackToAnActionableRetry() async throws {
        let context = try makeContext()
        let interface = CarPlayTestInterface()
        interface.automaticallyCompletes = false
        let session = makeSession(context: context, interface: interface)
        try interface.completeNext(success: false, message: "Vehicle is starting")
        XCTAssertEqual(interface.operations, [.root, .root])
        try interface.completeNext()
        let fallback = try XCTUnwrap(interface.topTemplate as? CPListTemplate)
        XCTAssertEqual(rows(fallback).first?.text, "Couldn’t open CarPlay")
        let retry = try retryRow(fallback)
        try select(retry)
        XCTAssertEqual(interface.pendingCount, 1)
        try interface.completeNext()
        XCTAssertTrue(interface.root === session.rootTemplate)
        XCTAssertTrue(interface.root is CPTabBarTemplate)
        try select(retry)
        XCTAssertEqual(interface.operations, [.root, .root, .root])
    }

    func testUpNextPresentationFailureShowsRetryWithoutRepeatingPlayback() async throws {
        let track = libraryTestTrack("carplay-up-next-failure")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [track]))
        context.library.toggleFavorite(track)
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let favorites = try rootList(session, at: 0)
        try await waitForRows(1, in: favorites)
        try select(try XCTUnwrap(rows(favorites).first))
        let controls = try XCTUnwrap(session.nowPlayingControls)
        let dismissals = context.model.searchFocusDismissal
        interface.automaticallyCompletes = false
        controls.nowPlayingTemplateUpNextButtonTapped(.shared)
        try await AppModelFixtures.eventually { interface.pendingCount == 1 }
        try interface.completeNext(success: false, message: "Vehicle is busy")
        XCTAssertEqual(interface.pendingCount, 1)
        try interface.completeNext()
        let error = try XCTUnwrap(interface.topTemplate as? CPListTemplate)
        XCTAssertEqual(rows(error).first?.detailText, "Vehicle is busy")
        try select(try retryRow(error))
        try interface.completeNext()
        XCTAssertEqual((interface.topTemplate as? CPListTemplate)?.title, "Queue")
        XCTAssertEqual(context.player.currentTrack, track)
        XCTAssertEqual(context.model.searchFocusDismissal, dismissals)
    }

    func testDisconnectAndReconnectRetireRowsControlsAndLateInterfaceErrors() async throws {
        let track = libraryTestTrack("carplay-disconnect")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [track], position: 8))
        context.library.toggleFavorite(track)
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let favorites = try rootList(session, at: 0)
        try await waitForRows(1, in: favorites)
        let oldRow = try XCTUnwrap(rows(favorites).first)
        let oldControls = try XCTUnwrap(session.nowPlayingControls)
        interface.automaticallyCompletes = false
        try select(oldRow)
        session.disconnect()
        let dismissals = context.model.searchFocusDismissal
        try select(oldRow)
        oldControls.activate(.favorite)
        oldControls.nowPlayingTemplateUpNextButtonTapped(.shared)
        try interface.completeNext(success: false, message: "Late disconnected callback")
        XCTAssertEqual(context.model.searchFocusDismissal, dismissals)
        XCTAssertTrue(context.library.isFavorite(track))
        XCTAssertTrue(context.player.isLoading, "CarPlay disconnect must not cancel the phone's stream resolution")
        XCTAssertNil(interface.delegate)
        interface.automaticallyCompletes = true
        session.connect()
        try select(oldRow)
        await Task.yield()
        XCTAssertEqual(context.model.searchFocusDismissal, dismissals)
        XCTAssertEqual(interface.operations, [.root, .push, .root])
    }
}

@MainActor
private final class CarPlayTestRegistry {
    var playback: CompanionPlaybackController?
}
