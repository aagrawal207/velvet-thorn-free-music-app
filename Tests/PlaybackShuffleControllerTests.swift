import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackShuffleControllerTests: XCTestCase {
    private let a = Track(id: "shuffle-player-a", title: "A", duration: 180)
    private let b = Track(id: "shuffle-player-b", title: "B", duration: 180)
    private let c = Track(id: "shuffle-player-c", title: "C", duration: 180)

    func testStyleAndHistoryConfigurationDoNotPublishReorderOrReadAndRestoreRemainsPaused() async {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        defer { player.pause() }
        var reads = 0
        var snapshots: [PlaybackSnapshot] = []
        player.shuffleHistoryProvider = { reads += 1; return [] }
        player.onSnapshotChanged = { snapshots.append($0) }
        let saved = PlaybackSnapshot(queue: [b, a, c, a], currentIndex: 2, position: 42,
                                     shuffleEnabled: true, repeatMode: .one, originalQueue: [a, b, a, c])
        XCTAssertEqual(player.shuffleStyle, .random)
        player.restore(saved)
        let publications = snapshots.count
        for style in [ShuffleStyle.fewerRepeats, .fewerRepeats, .random, .fewerRepeats] {
            player.setShuffleStyle(style)
            XCTAssertEqual(player.shuffleStyle, style)
            XCTAssertEqual(player.queue, saved.queue)
            XCTAssertEqual(player.currentTrack, c)
            XCTAssertEqual(player.position, 42)
            XCTAssertEqual(player.repeatMode, .one)
            XCTAssertTrue(player.shuffleEnabled)
            XCTAssertEqual(snapshots.count, publications)
        }
        player.shuffleHistoryProvider = { reads += 1; return nil }
        XCTAssertEqual(snapshots.count, publications)
        player.handleLifecycleCheckpoint()
        player.restore(saved)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(snapshots.last?.originalQueue, saved.originalQueue)
        XCTAssertEqual(player.queue, saved.queue)
        XCTAssertEqual(player.position, 42)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertNil(player.currentStreamURL)
        let requests = await gate.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOnlyExplicitShuffleOrdersReadTheCurrentHistoryProvider() {
        let player = PlayerController(resolver: PlaybackResolutionGate())
        defer { player.pause() }
        player.restore(PlaybackSnapshot(queue: [a, b, c], position: 12))
        var history: [ListeningEvent]? = [event(a)]
        var observations: [[UUID]?] = []
        player.shuffleHistoryProvider = { observations.append(history?.map(\.id)); return history }
        player.setShuffleStyle(.fewerRepeats)
        XCTAssertTrue(observations.isEmpty)
        player.toggleShuffle()
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0], history?.map(\.id))
        let weightedOrder = player.queue

        history = []
        player.flushListeningProgress()
        player.handleLifecycleCheckpoint()
        player.discardPendingListening()
        player.setShuffleStyle(.random)
        player.setShuffleStyle(.fewerRepeats)
        XCTAssertEqual(player.queue, weightedOrder)
        XCTAssertEqual(player.position, 12)
        XCTAssertEqual(observations.count, 1)
        player.seek(to: 5)
        player.enqueue(c, next: true)
        player.moveQueue(from: IndexSet(integer: 3), to: 2)
        player.removeFromQueue(at: 1)
        player.cycleRepeatMode()
        player.cycleRepeatMode()
        player.next()
        player.previous()
        player.pause()
        XCTAssertEqual(observations.count, 1)

        player.toggleShuffle()
        XCTAssertEqual(observations.count, 1, "Turning Shuffle off must not read history")
        player.toggleShuffle()
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations[1], [])
        player.toggleShuffle()
        history = nil
        player.toggleShuffle()
        XCTAssertEqual(observations.count, 3)
        XCTAssertNil(observations[2])
        XCTAssertEqual(player.queue.count, 3)
    }

    func testOrdinaryListPlayReplacesTheQueueWithoutFirstDisablingTheOldShuffledQueue() async throws {
        let gate = PlaybackResolutionGate()
        addTeardownBlock { await gate.cancelRemaining() }
        let player = PlayerController(resolver: gate)
        defer { player.pause() }
        let old = [c, a, b]
        player.restore(PlaybackSnapshot(queue: old, currentIndex: 1, position: 25, shuffleEnabled: true,
                                        originalQueue: [a, b, c]))
        player.setShuffleStyle(.fewerRepeats)
        player.shuffleHistoryProvider = { XCTFail("Ordinary list play must not generate a shuffle order"); return [] }
        var snapshots: [PlaybackSnapshot] = []
        player.onSnapshotChanged = { snapshots.append($0) }
        let source = [b, b, a]
        player.play(source, startingAt: 1, shuffle: false)
        XCTAssertEqual(player.queue, source)
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.currentTrack, b)
        XCTAssertEqual(player.position, 0)
        XCTAssertFalse(player.shuffleEnabled)
        XCTAssertEqual(snapshots.last?.originalQueue, source)
        let oldPublications = snapshots.filter { $0.queue == old }
        XCTAssertFalse(oldPublications.isEmpty, "Retiring playback retains the normal checkpoint publication")
        XCTAssertTrue(oldPublications.allSatisfy { $0.shuffleEnabled && $0.currentIndex == 1 && $0.position == 25 })
        XCTAssertTrue(snapshots.allSatisfy { $0.queue == old || $0.queue == source })
        let request = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
        XCTAssertEqual(request.trackID, b.id)
    }

    func testShuffledListReadsOnceAndPreservesItsSourceOccurrencesWithoutMutatingTheOldQueue() async throws {
        let gate = PlaybackResolutionGate()
        addTeardownBlock { await gate.cancelRemaining() }
        let player = PlayerController(resolver: gate)
        defer { player.pause() }
        let old = [c, b, a]
        player.restore(PlaybackSnapshot(queue: old, currentIndex: 1, position: 25, shuffleEnabled: true,
                                        originalQueue: [a, b, c]))
        player.setShuffleStyle(.fewerRepeats)
        let history = [event(a)]
        var reads = 0
        player.shuffleHistoryProvider = { [weak player] in
            reads += 1
            XCTAssertEqual(player?.queue, old)
            return history
        }
        var secondA = a
        secondA.title = "Other occurrence of A"
        let source = [a, b, secondA]
        var snapshots: [PlaybackSnapshot] = []
        player.onSnapshotChanged = { snapshots.append($0) }
        player.playShuffled(source)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(player.shuffleEnabled)
        XCTAssertFalse(player.isRadioSession)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.queue.count, source.count)
        XCTAssertEqual(Set(player.queue), Set(source))
        XCTAssertEqual(player.queue.filter { $0.id == a.id }.count, 2)
        XCTAssertEqual(snapshots.last?.originalQueue, source)
        XCTAssertTrue(snapshots.filter { $0.queue == old }.allSatisfy { $0.shuffleEnabled && $0.currentIndex == 1 })
        let selected = try XCTUnwrap(player.currentTrack)
        let request = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
        XCTAssertEqual(request.trackID, selected.id)
        player.toggleShuffle()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(player.queue, source)
        XCTAssertEqual(player.currentTrack, selected)
        XCTAssertEqual(player.currentIndex, source.firstIndex(of: selected))
    }

    func testExplicitSelectionsKeepLegacyShuffleStateUnlessTheTrailingOverrideIsProvided() async throws {
        let cases: [(initial: Bool, requested: Bool?, expected: Bool)] = [
            (false, nil, false), (true, nil, true), (false, true, true),
            (true, true, true), (false, false, false), (true, false, false)
        ]
        for (initial, requested, expected) in cases {
            let gate = PlaybackResolutionGate()
            addTeardownBlock { await gate.cancelRemaining() }
            let player = PlayerController(resolver: gate)
            defer { player.pause() }
            player.restore(PlaybackSnapshot(queue: [a, b, c], shuffleEnabled: initial))
            player.setShuffleStyle(.fewerRepeats)
            var reads = 0
            let history = [event(a)]
            player.shuffleHistoryProvider = { reads += 1; return history }
            let source = [a, c, b, a]
            var latest: PlaybackSnapshot?
            player.onSnapshotChanged = { latest = $0 }
            player.play(source, startingAt: 3, isRadio: true, shuffle: requested)
            XCTAssertEqual(player.shuffleEnabled, expected)
            XCTAssertEqual(player.currentTrack, a)
            XCTAssertEqual(player.currentIndex, expected ? 0 : 3)
            XCTAssertEqual(reads, expected ? 1 : 0)
            XCTAssertEqual(latest?.originalQueue, source)
            XCTAssertTrue(player.isRadioSession)
            if expected {
                player.toggleShuffle()
                XCTAssertEqual(player.currentIndex, 3)
            }
            XCTAssertEqual(player.queue, source)
            let request = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
            XCTAssertEqual(request.trackID, a.id)
        }
    }

    func testEmptyAndSingletonShuffleReplaceTheQueueAndAvoidReadingAnEmptyCandidatePool() async throws {
        let gate = PlaybackResolutionGate()
        addTeardownBlock { await gate.cancelRemaining() }
        let player = PlayerController(resolver: gate)
        defer { player.pause() }
        player.restore(PlaybackSnapshot(queue: [a, b], position: 15))
        var reads = 0
        player.setShuffleStyle(.fewerRepeats)
        player.shuffleHistoryProvider = { reads += 1; return nil }
        var latest: PlaybackSnapshot?
        player.onSnapshotChanged = { latest = $0 }
        player.playShuffled([])
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentTrack)
        XCTAssertEqual(player.position, 0)
        XCTAssertTrue(player.shuffleEnabled)
        XCTAssertEqual(latest?.originalQueue, [])
        XCTAssertEqual(reads, 0)
        player.playShuffled([a])
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(player.queue, [a])
        XCTAssertEqual(player.currentTrack, a)
        player.toggleShuffle()
        player.toggleShuffle()
        XCTAssertEqual(reads, 1, "A pinned singleton has no tail to shuffle")
        XCTAssertEqual(latest?.originalQueue, [a])
        _ = try await PlaybackTestSupport.waitForRequests(1, on: gate)
    }

    private func event(_ track: Track) -> ListeningEvent {
        ListeningEvent(id: UUID(), track: track, startedAt: Date().addingTimeInterval(-60), listenedSeconds: 30)
    }
}
