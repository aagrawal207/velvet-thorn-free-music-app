import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackHandoffPublisherTests: XCTestCase {
    func testPublishesOnSelectionSeekPlayAndPauseButNotOnPositionTicks() async throws {
        let audio = try PlaybackTestSupport.audioFile(seconds: 12)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let queue = (0..<3).map { libraryTestTrack("song-\($0)", duration: 12) }
        let player = PlayerController(resolver: PlaybackFileResolver(url: audio, duration: 12))
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.autoplay = false
        player.apply(settings)
        player.restore(PlaybackSnapshot(queue: queue, currentIndex: 1, position: 2))
        let sink = RecordingHandoffSink()
        let publisher = PlaybackHandoffPublisher(player: player, sink: sink, hostAllowsHandoff: true)
        publisher.setSceneActive(true)
        publisher.start()
        defer { publisher.stop() }

        let first = try XCTUnwrap(sink.payloads.last)
        XCTAssertEqual(sink.payloads.count, 1)
        XCTAssertEqual(sink.titles.last, "Listening to Song song-1")
        XCTAssertEqual(first.senderID, PlaybackHandoffCodec.localSenderID)
        XCTAssertEqual(first.snapshot.queue, queue)
        XCTAssertEqual(first.snapshot.currentIndex, 1)
        XCTAssertEqual(first.snapshot.position, 2)
        XCTAssertFalse(first.wasPlaying)
        XCTAssertEqual(sink.becameCurrent, 1)

        player.seek(to: 4)
        try await PlaybackTestSupport.waitUntil { sink.payloads.last?.snapshot.position == 4 }
        XCTAssertFalse(try XCTUnwrap(sink.payloads.last).wasPlaying)

        player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { sink.payloads.last?.wasPlaying == true }
        try await PlaybackTestSupport.waitUntil { player.isPlaying && !player.isLoading && player.position > 4.5 }
        try await Task.sleep(for: .milliseconds(100))
        let settled = sink.payloads.count
        let position = player.position
        // Several 500 ms ticks advance the position without any semantic change.
        try await PlaybackTestSupport.waitUntil { player.position > position + 1.6 }
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(sink.payloads.count, settled)

        player.pause()
        try await PlaybackTestSupport.waitUntil { sink.payloads.last?.wasPlaying == false }
        let paused = sink.payloads.count

        XCTAssertTrue(player.selectQueueTrack(at: 2))
        try await PlaybackTestSupport.waitUntil {
            guard let snapshot = sink.payloads.last?.snapshot else { return false }
            return snapshot.queue[snapshot.currentIndex].id == "song-2"
        }
        XCTAssertGreaterThan(sink.payloads.count, paused)
        XCTAssertEqual(sink.titles.last, "Listening to Song song-2")
        XCTAssertEqual(sink.invalidations, 0)
    }

    func testSemanticStateIgnoresPositionAndPublicationWaitsForActiveScene() throws {
        let player = PlayerController(resolver: PlaybackResolutionGate())
        player.restore(PlaybackSnapshot(queue: [libraryTestTrack()], position: 10))
        let sink = RecordingHandoffSink()
        let publisher = PlaybackHandoffPublisher(player: player, sink: sink, hostAllowsHandoff: true)
        publisher.start()
        defer { publisher.stop() }
        XCTAssertEqual(sink.payloads.count, 1)
        XCTAssertEqual(sink.becameCurrent, 0)
        publisher.setSceneActive(true)
        XCTAssertEqual(sink.becameCurrent, 1)
        publisher.setSceneActive(true)
        XCTAssertEqual(sink.becameCurrent, 1)

        let state = PlaybackHandoffPublisher.SemanticState(entryID: UUID(), trackID: "a", queueSignature: 1, queueCount: 1,
            playing: true, shuffleEnabled: false, repeatMode: .off, isLiveRadio: false, controlRevision: 3)
        var seek = state
        seek.controlRevision = 4
        XCTAssertNotEqual(state, seek)
        var pause = state
        pause.playing = false
        XCTAssertNotEqual(state, pause)
    }

    func testWithdrawsForLiveRadioAndWhenNothingIsSelected() async throws {
        let live = LiveRadioResolutionGate()
        let music = PlaybackResolutionGate()
        let player = PlayerController(resolver: music, liveRadioResolver: live)
        let song = libraryTestTrack()
        player.restore(PlaybackSnapshot(queue: [song], position: 30))
        let sink = RecordingHandoffSink()
        let publisher = PlaybackHandoffPublisher(player: player, sink: sink, hostAllowsHandoff: true)
        publisher.setSceneActive(true)
        publisher.start()
        defer { publisher.stop() }
        XCTAssertEqual(sink.payloads.count, 1)

        XCTAssertTrue(player.playLiveRadio(LiveRadioTestSupport.station))
        try await PlaybackTestSupport.waitUntil { sink.invalidations == 1 }
        let published = sink.payloads.count
        player.seek(to: 50)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sink.payloads.count, published)
        XCTAssertEqual(sink.invalidations, 1)

        player.stopLiveRadio()
        try await PlaybackTestSupport.waitUntil { sink.payloads.count > published }
        XCTAssertEqual(sink.payloads.last?.snapshot.queue, [song])
        XCTAssertEqual(sink.payloads.last?.snapshot.position, 30)
        await live.cancelRemaining()

        let empty = PlayerController(resolver: PlaybackResolutionGate())
        let emptySink = RecordingHandoffSink()
        let idle = PlaybackHandoffPublisher(player: empty, sink: emptySink, hostAllowsHandoff: true)
        idle.setSceneActive(true)
        idle.start()
        XCTAssertTrue(emptySink.payloads.isEmpty)
        XCTAssertEqual(emptySink.becameCurrent, 0)
        idle.stop()

        await player.waitForListeningCheckpointDelivery()
    }

    func testTestHostsNeverAdvertise() {
        let player = PlayerController(resolver: PlaybackResolutionGate())
        player.restore(PlaybackSnapshot(queue: [libraryTestTrack()]))
        let sink = RecordingHandoffSink()
        XCTAssertFalse(PlaybackHandoffPublisher.hostAllowsHandoff)
        let publisher = PlaybackHandoffPublisher(player: player, sink: sink)
        publisher.setSceneActive(true)
        publisher.start()
        XCTAssertTrue(sink.payloads.isEmpty)
        XCTAssertEqual(sink.becameCurrent, 0)
        XCTAssertEqual(sink.invalidations, 1)
    }

    func testContinuedElsewherePausesTheSender() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.restore(PlaybackSnapshot(queue: [libraryTestTrack()], position: 12))
        let sink = RecordingHandoffSink()
        let publisher = PlaybackHandoffPublisher(player: player, sink: sink, hostAllowsHandoff: true)
        publisher.start()
        defer { publisher.stop() }
        player.resumePlayback()
        XCTAssertTrue(player.isLoading)
        try await PlaybackTestSupport.waitUntil { sink.payloads.last?.wasPlaying == true }

        sink.onContinuedElsewhere?()
        XCTAssertFalse(player.isLoading)
        XCTAssertFalse(player.isPlaying)
        try await PlaybackTestSupport.waitUntil { sink.payloads.last?.wasPlaying == false }
        XCTAssertEqual(player.position, 12)
        await gate.cancelRemaining()
    }

    // MARK: Model continuation

    func testContinuePlaybackAppliesQueueSelectionAndPositionPaused() async throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack("local")]))
        let queue = (0..<3).map { libraryTestTrack("remote-\($0)") }
        let snapshot = PlaybackSnapshot(queue: queue, currentIndex: 2, position: 1, repeatMode: .all)
        XCTAssertTrue(context.model.continuePlayback(from: snapshot, at: 45, startPlaying: false, origin: .nearbyDevice))
        XCTAssertEqual(context.player.queue, queue)
        XCTAssertEqual(context.player.currentIndex, 2)
        XCTAssertEqual(context.player.position, 45)
        XCTAssertEqual(context.player.repeatMode, .all)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        try await AppModelFixtures.eventually { context.library.playback.queue == queue && context.library.playback.position == 45 }
        let requests = await context.streams.streams.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(context.library.events.isEmpty)
    }

    func testContinuePlaybackStartsWhenAskedAndRefusesInvalidSnapshots() async throws {
        let local = libraryTestTrack("local")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [local], position: 8))
        XCTAssertFalse(context.model.continuePlayback(from: PlaybackSnapshot(), at: 0, startPlaying: true, origin: .handoff))
        let outOfRange = PlaybackSnapshot(queue: [libraryTestTrack("x")], currentIndex: 3)
        XCTAssertFalse(context.model.continuePlayback(from: outOfRange, at: 0, startPlaying: true, origin: .handoff))
        XCTAssertFalse(context.model.continuePlayback(from: PlaybackSnapshot(queue: [libraryTestTrack("x")]), at: .infinity,
                                                      startPlaying: true, origin: .handoff))
        XCTAssertEqual(context.player.queue, [local])
        XCTAssertEqual(context.player.position, 8)
        XCTAssertFalse(context.player.isLoading)

        let remote = libraryTestTrack("remote")
        XCTAssertTrue(context.model.continuePlayback(from: PlaybackSnapshot(queue: [remote]), at: 20, startPlaying: true,
                                                     origin: .handoff))
        XCTAssertEqual(context.player.currentTrack, remote)
        XCTAssertTrue(context.player.isLoading)
        let request = try await context.streams.streams.request(at: 0)
        XCTAssertEqual(request.input.track.id, "remote")
    }

    func testAcceptHandoffContinuesOtherDevicesAndIgnoresItsOwnActivity() async throws {
        let local = libraryTestTrack("local")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [local], position: 8))
        let remote = (0..<2).map { libraryTestTrack("remote-\($0)") }
        let snapshot = PlaybackSnapshot(queue: remote, currentIndex: 1, position: 30)

        let own = try activity(PlaybackHandoff(senderID: MusicAppModel.handoffSenderID, sentAt: Date(), wasPlaying: false,
                                               snapshot: snapshot))
        XCTAssertFalse(context.model.acceptHandoff(own))
        XCTAssertEqual(context.player.queue, [local])

        let other = NSUserActivity(activityType: "com.example.other")
        other.addUserInfoEntries(from: own.userInfo ?? [:])
        XCTAssertFalse(context.model.acceptHandoff(other))
        let corrupt = NSUserActivity(activityType: PlaybackHandoffCodec.activityType)
        corrupt.addUserInfoEntries(from: [PlaybackHandoffCodec.payloadKey: Data("bad".utf8)])
        XCTAssertFalse(context.model.acceptHandoff(corrupt))
        XCTAssertEqual(context.player.queue, [local])
        XCTAssertNil(context.model.toast)

        let paused = try activity(PlaybackHandoff(senderID: UUID(), sentAt: Date().addingTimeInterval(-10), wasPlaying: false,
                                                  snapshot: snapshot))
        XCTAssertTrue(context.model.acceptHandoff(paused))
        XCTAssertEqual(context.player.queue, remote)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.position, 30)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertEqual(context.model.toast, "Picked up from your other device.")

        let playing = try activity(PlaybackHandoff(senderID: UUID(), sentAt: Date().addingTimeInterval(-10), wasPlaying: true,
                                                   snapshot: PlaybackSnapshot(queue: [local], position: 50)))
        XCTAssertTrue(context.model.acceptHandoff(playing))
        XCTAssertEqual(context.player.currentTrack, local)
        XCTAssertGreaterThanOrEqual(context.player.position, 60)
        XCTAssertLessThan(context.player.position, 62)
        XCTAssertTrue(context.player.isLoading)
        let request = try await context.streams.streams.request(at: 0)
        XCTAssertEqual(request.input.track.id, "local")
    }

    // MARK: Helpers

    private func activity(_ handoff: PlaybackHandoff) throws -> NSUserActivity {
        let activity = NSUserActivity(activityType: PlaybackHandoffCodec.activityType)
        activity.addUserInfoEntries(from: try PlaybackHandoffCodec.userInfo(for: handoff))
        return activity
    }

    private func makeContext(snapshot: PlaybackSnapshot) throws -> AppModelTestContext {
        let context = try AppModelTestContext(snapshot: snapshot)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}

@MainActor
private final class RecordingHandoffSink: PlaybackHandoffActivitySink {
    var onContinuedElsewhere: (@MainActor () -> Void)?
    private(set) var payloads: [PlaybackHandoff] = []
    private(set) var titles: [String] = []
    private(set) var becameCurrent = 0
    private(set) var invalidations = 0

    func update(_ payload: PlaybackHandoff, data: Data, title: String, duration: TimeInterval?) {
        XCTAssertEqual(try? PlaybackHandoffCodec.decode(data), payload)
        payloads.append(payload)
        titles.append(title)
    }

    func becomeCurrent() { becameCurrent += 1 }
    func invalidate() { invalidations += 1 }
}
