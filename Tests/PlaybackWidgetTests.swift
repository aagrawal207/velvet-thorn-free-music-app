import AppIntents
import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackWidgetTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackWidget-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testStateStoreRoundTripsSkipsUnchangedWritesAndRejectsBadFiles() throws {
        let store = WidgetPlaybackStateStore(directory: try temporaryDirectory())
        XCTAssertEqual(store.read(), .empty, "A missing file reads as no selection")
        let state = WidgetPlaybackState(hasSelection: true, isPlaying: true, title: "Tum Hi Ho", subtitle: "Arijit Singh", accent: .mint)
        XCTAssertTrue(try store.write(state))
        XCTAssertEqual(store.read(), state)
        XCTAssertFalse(try store.write(state), "An identical state is not rewritten, so no reload is owed")

        XCTAssertThrowsError(try store.write(WidgetPlaybackState(hasSelection: false, isPlaying: true)))
        XCTAssertThrowsError(try store.write(WidgetPlaybackState(hasSelection: true, isPlaying: false, title: "")))
        XCTAssertEqual(store.read(), state, "Rejected states leave the published file alone")

        let url = try XCTUnwrap(store.fileURL)
        try Data("{\"version\":2,\"hasSelection\":true,\"isPlaying\":true}".utf8).write(to: url)
        XCTAssertEqual(store.read(), .empty, "A future version is never shown")
        try Data(repeating: 0x20, count: WidgetPlaybackState.maximumFileBytes + 1).write(to: url)
        XCTAssertEqual(store.read(), .empty)
    }

    func testBoundedTextKeepsShortTitlesAndTruncatesLongOnesWithinTheByteLimit() throws {
        XCTAssertNil(WidgetPlaybackState.bounded("  \n"))
        XCTAssertEqual(WidgetPlaybackState.bounded(" Kesariya "), "Kesariya")
        let long = String(repeating: "गाना", count: 40)
        let bounded = try XCTUnwrap(WidgetPlaybackState.bounded(long))
        XCTAssertLessThanOrEqual(bounded.utf8.count, WidgetPlaybackState.maximumTextBytes)
        XCTAssertTrue(bounded.hasSuffix("..."))
        XCTAssertNotNil(WidgetPlaybackState(hasSelection: true, isPlaying: false, title: bounded).validated())
    }

    func testPresentationNamesTheSongWhenKnownAndStaysGenericOtherwise() {
        let empty = NowPlayingWidgetPresentation(state: .empty)
        XCTAssertEqual(empty.title, "Velvet Thorn")
        XCTAssertEqual(empty.subtitle, "Choose music to play")
        XCTAssertEqual(empty.accessibilityLabel, "Open Velvet Thorn")
        XCTAssertEqual(empty.inlineText, "Velvet Thorn")

        let playing = NowPlayingWidgetPresentation(state: .init(hasSelection: true, isPlaying: true, title: "Tum Hi Ho", subtitle: "Arijit Singh"))
        XCTAssertEqual(playing.symbol, "pause.fill")
        XCTAssertEqual(playing.actionLabel, "Pause")
        XCTAssertEqual(playing.accessibilityLabel, "Tum Hi Ho, Arijit Singh. Playing")
        XCTAssertEqual(playing.controlTitle, "Tum Hi Ho")

        let private_ = NowPlayingWidgetPresentation(state: .init(hasSelection: true, isPlaying: false))
        XCTAssertEqual(private_.symbol, "play.fill")
        XCTAssertEqual(private_.title, "Your last song")
        XCTAssertEqual(private_.subtitle, "Paused")
        XCTAssertEqual(private_.inlineText, "Paused in Velvet Thorn")
        XCTAssertEqual(private_.controlTitle, "Velvet Thorn")

        let radio = NowPlayingWidgetPresentation(state: .init(hasSelection: true, isPlaying: true, isLiveRadio: true))
        XCTAssertEqual(radio.title, "Live radio")
        XCTAssertEqual(radio.accessibilityLabel, "Live radio. Playing")
    }

    func testIntentsSendTheirCommandsToTheInstalledApp() async throws {
        let previous = PlaybackIntentRuntime.perform
        defer { PlaybackIntentRuntime.perform = previous }
        var commands: [PlaybackIntentCommand] = []
        PlaybackIntentRuntime.perform = { command in commands.append(command); return .success }

        _ = try await TogglePlaybackIntent().perform()
        var set = SetBreezyPlaybackIntent()
        set.value = true
        _ = try await set.perform()
        set.value = false
        _ = try await set.perform()
        _ = try await OpenBreezyPlayerIntent().perform()
        XCTAssertEqual(commands, [.toggle, .play, .pause, .openPlayer])
        XCTAssertTrue(OpenBreezyPlayerIntent.openAppWhenRun)

        PlaybackIntentRuntime.perform = nil
        _ = try await TogglePlaybackIntent().perform()
        XCTAssertEqual(commands.count, 4, "Without the app's model, as in the widget extension, an intent does nothing")
    }

    func testPlaybackIntentPlaysAndPausesTheRestoredSongAndOpensThePlayer() async throws {
        let media = try makeWidgetAudioFile()
        let current = WidgetRouteFixtures.current, next = WidgetRouteFixtures.next
        let resolver = PlaybackFixtureResolver([current.id: .init(url: media, duration: 30), next.id: .init(url: media, duration: 30)])
        let context = try makeWidgetRouteContext(snapshot: PlaybackSnapshot(queue: [current, next], position: 2), resolver: resolver)
        let model = context.model, player = context.player
        XCTAssertFalse(player.isPlaying)

        XCTAssertEqual(model.performPlaybackIntent(.toggle), .success)
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        XCTAssertEqual(player.currentTrack, current, "The restored song resumes rather than a new queue")
        XCTAssertEqual(model.performPlaybackIntent(.play), .unchanged)
        XCTAssertEqual(model.performPlaybackIntent(.toggle), .success)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(model.performPlaybackIntent(.pause), .unchanged)
        XCTAssertEqual(model.performPlaybackIntent(.play), .success)
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        XCTAssertEqual(model.performPlaybackIntent(.pause), .success)
        XCTAssertFalse(player.isPlaying)

        model.isSettingsPresented = true
        XCTAssertEqual(model.performPlaybackIntent(.openPlayer), .success)
        XCTAssertTrue(model.isPlayerPresented)
        XCTAssertFalse(model.isSettingsPresented)
        model.isPlayerPresented = false
        XCTAssertTrue(model.handleOpenURL(NowPlayingWidgetPresentation.openURL))
        XCTAssertTrue(model.isPlayerPresented)
        XCTAssertFalse(player.isPlaying, "Opening the player never starts audio")
        XCTAssertFalse(model.handleOpenURL(URL(string: "ganabajana://player?id=1")!))
        await context.assertNoCatalogRequests()
    }

    func testPlaybackIntentWithoutASelectionOrBeforeWelcomeChangesNothing() async throws {
        let empty = try makeWidgetRouteContext()
        XCTAssertEqual(empty.model.performPlaybackIntent(.toggle), .noSelection)
        XCTAssertEqual(empty.model.performPlaybackIntent(.openPlayer), .noSelection)
        XCTAssertFalse(empty.model.isPlayerPresented)

        let media = try makeWidgetAudioFile()
        let current = WidgetRouteFixtures.current
        let resolver = PlaybackFixtureResolver([current.id: .init(url: media, duration: 30)])
        let welcome = try makeWidgetRouteContext(snapshot: PlaybackSnapshot(queue: [current]), resolver: resolver, completedWelcome: false)
        XCTAssertEqual(welcome.model.performPlaybackIntent(.toggle), .unavailable)
        XCTAssertEqual(welcome.model.performPlaybackIntent(.openPlayer), .unavailable)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(welcome.player.isPlaying)
        XCTAssertFalse(welcome.model.isPlayerPresented)
    }

    func testPublisherMirrorsPlayStateRedactsHistoryAndFollowsAccentWithoutWritingOnTicks() async throws {
        let media = try makeWidgetAudioFile()
        let current = WidgetRouteFixtures.current, next = WidgetRouteFixtures.next
        let resolver = PlaybackFixtureResolver([current.id: .init(url: media, duration: 30), next.id: .init(url: media, duration: 30)])
        let context = try makeWidgetRouteContext(snapshot: PlaybackSnapshot(queue: [current, next], position: 2), resolver: resolver)
        let store = WidgetPlaybackStateStore(directory: try temporaryDirectory())
        var reloads = 0
        let publisher = PlaybackWidgetPublisher(player: context.player, library: context.library, store: store,
                                                delay: .milliseconds(20)) { reloads += 1 }
        XCTAssertEqual(store.read(), WidgetPlaybackState(hasSelection: true, isPlaying: false, title: current.title,
                                                         subtitle: current.artistName, accent: .coral))
        XCTAssertEqual(reloads, 1)

        context.player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { store.read().isPlaying }
        let playingReloads = reloads
        try await PlaybackTestSupport.waitUntil { context.player.position > 3 }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(reloads, playingReloads, "Position ticks and loading-to-playing never rewrite the widget state")

        context.player.pause()
        try await PlaybackTestSupport.waitUntil { !store.read().isPlaying }

        context.model.updatePreferences { $0.accent = .mint }
        try await PlaybackTestSupport.waitUntil { store.read().accent == .mint }

        context.model.updatePreferences { $0.saveListeningHistory = false }
        try await PlaybackTestSupport.waitUntil { store.read().title == nil }
        let redacted = store.read()
        XCTAssertNil(redacted.subtitle, "History off shows a generic Resume, never the song")
        XCTAssertEqual(redacted.hasSelection, context.player.currentTrack != nil)
        XCTAssertEqual(publisher.reloadCount, reloads)
    }
}
