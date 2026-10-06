// CarPlay templates exist only on iPhone; Mac Catalyst links the framework but cannot host its scenes.
#if !targetEnvironment(macCatalyst)
import CarPlay
import MediaPlayer
import XCTest
@testable import GanaBajana

@MainActor
final class CarPlayPlaybackIntegrationTests: CarPlayTestCase {
    func testDisconnectKeepsThePhonePlayerMetadataCommandsAndOtherObserversAlive() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 20)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = try makeContext(resolver: PlaybackFileResolver(url: url, duration: 20))
        context.model.updatePreferences { $0.autoplay = false }
        let track = libraryTestTrack("carplay-continuity", duration: 20)
        context.model.play(track)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.2 }
        let bridge = CompanionPlaybackController(model: context.model)
        let observed = CarPlayObservedSnapshots()
        let observer = bridge.observe { observed.snapshots.append($0) }
        defer { bridge.removeObserver(observer) }
        let interface = CarPlayTestInterface()
        let session = CarPlaySessionController(interface: interface,
                                               limits: CarPlayTemplateLimits(tabs: 4, items: 20, sections: 1), playbackProvider: { bridge })
        defer { session.disconnect() }
        session.connect()
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let commandEnabled = MPRemoteCommandCenter.shared().pauseCommand.isEnabled
        let stream = context.player.currentStreamURL
        let position = context.player.position
        let externalDelegate = CarPlayExternalInterfaceDelegate()
        interface.delegate = externalDelegate
        session.disconnect()
        XCTAssertTrue(interface.delegate === externalDelegate, "Disconnect must only remove the delegate it installed")
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertEqual(context.player.currentStreamURL, stream)
        XCTAssertEqual(MPRemoteCommandCenter.shared().pauseCommand.isEnabled, commandEnabled)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String,
                       info?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String)
        let before = observed.snapshots.count
        let response = bridge.handle(CompanionRequest(action: .setFavorite(true), expectedTrackID: track.id), origin: .carPlay)
        XCTAssertTrue(response.accepted)
        XCTAssertGreaterThan(observed.snapshots.count, before)
        XCTAssertTrue(observed.snapshots.last?.nowPlaying?.isFavorite == true)
        XCTAssertTrue(observed.snapshots.last?.nowPlaying?.isSuperLiked == false)
        let promoted = bridge.handle(CompanionRequest(action: .setSuperLiked(true), expectedTrackID: track.id), origin: .carPlay)
        XCTAssertTrue(promoted.accepted)
        XCTAssertTrue(promoted.snapshot.nowPlaying?.isSuperLiked == true)
        XCTAssertTrue(observed.snapshots.last?.nowPlaying?.isSuperLiked == true)
        XCTAssertTrue(context.library.isSuperLiked(track))
        XCTAssertTrue(context.player.isPlaying)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > position + 0.3 }
    }

    func testLateStreamFailureCannotReplaceANewerPhonePlaybackIntent() async throws {
        let context = try makeContext()
        let old = libraryTestTrack("carplay-late-failure-old")
        let new = libraryTestTrack("carplay-late-failure-new")
        context.library.toggleFavorite(old)
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface)
        let favorites = try rootList(session, at: 0)
        try await waitForRows(1, in: favorites)
        try select(try XCTUnwrap(rows(favorites).first))
        let request = try await context.streams.streams.request(at: 0)
        context.model.play(new)
        try await context.streams.streams.complete(request, with: .failure(MusicServiceError.unavailable("Old selection failed")))
        _ = try await context.streams.streams.request(at: 1)
        XCTAssertEqual(context.player.currentTrack, new)
        XCTAssertNil(context.player.errorMessage)
        XCTAssertTrue(interface.topTemplate === CPNowPlayingTemplate.shared)
        XCTAssertEqual(interface.operations.filter { $0 == .push }.count, 1)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String, new.id)
    }

    func testLibraryWriteFailureDuringPlaybackNeverOffersAPlaybackRetryOrRestartsAudio() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 20)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resolver = PlaybackFileResolver(url: url, duration: 20)
        let context = try makeContext(resolver: resolver)
        context.model.updatePreferences {
            $0.autoplay = false
            $0.gaplessPlayback = false
            $0.automix = false
            $0.crossfadeSeconds = 0
        }
        let track = libraryTestTrack("carplay-library-failure-playing", duration: 20)
        context.library.toggleFavorite(track)
        let bridge = CompanionPlaybackController(model: context.model)
        let interface = CarPlayTestInterface()
        let session = CarPlaySessionController(interface: interface,
                                               limits: CarPlayTemplateLimits(tabs: 4, items: 20, sections: 1), playbackProvider: { bridge })
        defer { session.disconnect() }
        session.connect()
        let favorites = try rootList(session, at: 0)
        try await waitForRows(1, in: favorites)
        let selection = try select(try XCTUnwrap(rows(favorites).first))
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.2 }
        let stream = context.player.currentStreamURL
        let initialOperations = interface.operations
        let external = LibraryStore(directory: context.directory)
        external.toggleFavorite(libraryTestTrack("carplay-external-library-write"))
        context.library.toggleFavorite(track)
        XCTAssertTrue(context.library.requiresReload)
        XCTAssertTrue(context.library.isFavorite(track))
        let failedSnapshot = bridge.handle(CompanionRequest(action: .snapshot)).snapshot
        XCTAssertEqual(failedSnapshot.libraryError, "Your library change couldn’t be saved. Open Velvet Thorn on your iPhone to try again.")
        XCTAssertNil(failedSnapshot.nowPlaying?.errorMessage)
        XCTAssertTrue(failedSnapshot.nowPlaying?.isPlaying == true)
        let beforeNotice = context.player.position
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > beforeNotice + 0.3 }
        XCTAssertTrue(interface.topTemplate === CPNowPlayingTemplate.shared)
        XCTAssertEqual(interface.operations, initialOperations, "A library-only observer update must not present a playback failure")

        let controls = try XCTUnwrap(session.nowPlayingControls)
        controls.activate(.favorite)
        let notice = try XCTUnwrap(interface.topTemplate as? CPListTemplate)
        XCTAssertEqual(notice.title, "Library")
        XCTAssertEqual(rows(notice).first?.text, "Library needs attention")
        XCTAssertEqual(rows(notice).first?.detailText, failedSnapshot.libraryError)
        XCTAssertFalse(rows(notice).contains { $0.text == "Retry" })
        XCTAssertEqual(notice.trailingNavigationBarButtons.first?.title, "Now Playing")
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertEqual(context.player.currentStreamURL, stream)
        let dismissal = try select(try XCTUnwrap(rows(notice).first { $0.text == "Now Playing" }))
        let returnedOperations = interface.operations
        let resumedPosition = context.player.position
        for _ in 0..<3 { _ = bridge.handle(CompanionRequest(action: .snapshot)) }
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > resumedPosition + 0.3 }
        XCTAssertTrue(interface.topTemplate === CPNowPlayingTemplate.shared)
        XCTAssertEqual(interface.operations, returnedOperations, "Returning to Now Playing must not create a library-error retry loop")
        XCTAssertEqual(context.player.currentStreamURL, stream)
        XCTAssertTrue(context.library.requiresReload)
        XCTAssertTrue(context.library.isFavorite(track))
        XCTAssertNil(context.player.errorMessage)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        let resolutions = await resolver.refreshes
        XCTAssertEqual(resolutions, [false])
        XCTAssertEqual(selection.value, 1)
        XCTAssertEqual(dismissal.value, 1)
    }
}

@MainActor
private final class CarPlayObservedSnapshots {
    var snapshots: [CompanionSnapshot] = []
}

@MainActor
private final class CarPlayExternalInterfaceDelegate: NSObject, CPInterfaceControllerDelegate { }
#endif
