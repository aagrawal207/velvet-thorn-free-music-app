import XCTest
@testable import GanaBajana

final class PlaybackQueueTests: XCTestCase {
    private let tracks = (0..<8).map { Track(id: "song-\($0)", title: "Song \($0)") }

    func testShufflePreservesCurrentOccurrenceAndRestoresOriginalOrder() {
        var queue = PlaybackQueue()
        queue.replace(tracks, startingAt: 4)
        let selected = queue.selectedID
        queue.toggleShuffle()
        XCTAssertTrue(queue.shuffled)
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(queue.current, tracks[4])
        XCTAssertEqual(Set(queue.tracks), Set(tracks))
        queue.toggleShuffle()
        XCTAssertEqual(queue.tracks, tracks)
        XCTAssertEqual(queue.index, 4)
        XCTAssertEqual(queue.selectedID, selected)
    }

    func testDuplicateSongsRemainDistinctQueueOccurrences() {
        var queue = PlaybackQueue()
        queue.replace([tracks[0], tracks[0], tracks[1]], startingAt: 1)
        let selected = queue.selectedID
        queue.toggleShuffle()
        queue.remove(at: queue.entries.firstIndex { $0.track == tracks[0] && $0.id != selected }!)
        queue.toggleShuffle()
        XCTAssertEqual(queue.tracks, [tracks[0], tracks[1]])
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(queue.index, 0)
    }

    func testEditsWhileShuffledSurviveUnshuffleWithoutRevivingRemovedSongs() {
        var queue = PlaybackQueue()
        queue.replace(tracks, startingAt: 3)
        let selected = queue.selectedID
        queue.toggleShuffle()
        queue.remove(at: queue.tracks.firstIndex(of: tracks[6])!)
        let added = Track(id: "added", title: "Added")
        queue.enqueue(added, next: true)
        XCTAssertEqual(queue.tracks[queue.index + 1], added)
        queue.move(from: IndexSet(integer: queue.tracks.count - 1), to: 1)
        queue.toggleShuffle()
        XCTAssertEqual(queue.tracks.count, tracks.count)
        XCTAssertFalse(queue.tracks.contains(tracks[6]))
        XCTAssertEqual(queue.tracks.filter { $0 == added }.count, 1)
        XCTAssertEqual(queue.selectedID, selected)
    }

    func testRemovingAndMovingAroundCurrentPreservesSelection() {
        var queue = PlaybackQueue()
        queue.replace(tracks, startingAt: 4)
        let selected = queue.selectedID
        queue.remove(at: 0)
        XCTAssertEqual(queue.index, 3)
        queue.move(from: IndexSet([1, 3]), to: 7)
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(queue.current, tracks[4])
        XCTAssertEqual(queue.tracks.map(\.id), ["song-1", "song-3", "song-5", "song-6", "song-7", "song-2", "song-4"])
        queue.remove(at: queue.index)
        XCTAssertEqual(queue.current, tracks[2])
        XCTAssertEqual(queue.index, queue.tracks.count - 1)
    }

    func testRepeatModesDistinguishAutomaticEndFromManualSkip() {
        var queue = PlaybackQueue()
        queue.replace(Array(tracks.prefix(2)))
        XCTAssertTrue(queue.advance(repeatMode: .one, automatic: true))
        XCTAssertEqual(queue.index, 0)
        XCTAssertTrue(queue.advance(repeatMode: .one, automatic: false))
        XCTAssertEqual(queue.index, 1)
        XCTAssertFalse(queue.advance(repeatMode: .off, automatic: true))
        XCTAssertTrue(queue.advance(repeatMode: .all, automatic: true))
        XCTAssertEqual(queue.index, 0)
        queue.previous(repeatMode: .all)
        XCTAssertEqual(queue.index, 1)
    }

    func testRestoreDoesNotReshuffleAndSanitizesIndexes() {
        var queue = PlaybackQueue()
        let order = [tracks[3], tracks[0], tracks[5]]
        queue.restore(PlaybackSnapshot(queue: order, currentIndex: 1, position: 123, shuffleEnabled: true))
        XCTAssertEqual(queue.tracks, order)
        XCTAssertEqual(queue.current, tracks[0])
        XCTAssertTrue(queue.shuffled)
        queue.restore(PlaybackSnapshot(queue: order, currentIndex: .max))
        XCTAssertEqual(queue.index, 2)
        queue.restore(PlaybackSnapshot())
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.index, 0)
        XCTAssertFalse(queue.advance(repeatMode: .all, automatic: true))
    }

    func testShufflePersistRestoreUnshuffleRestoresOriginalOrder() throws {
        var queue = PlaybackQueue()
        queue.replace(tracks, startingAt: 4)
        queue.toggleShuffle()
        let snapshot = queue.snapshot(position: 42, repeatMode: .all)
        XCTAssertEqual(snapshot.originalQueue, tracks)
        let persisted = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PlaybackSnapshot.self, from: persisted)
        var restored = PlaybackQueue()
        restored.restore(decoded)
        XCTAssertEqual(restored.tracks, queue.tracks)
        XCTAssertEqual(restored.current, tracks[4])
        let selected = restored.selectedID
        restored.toggleShuffle()
        XCTAssertEqual(restored.tracks, tracks)
        XCTAssertEqual(restored.index, 4)
        XCTAssertEqual(restored.selectedID, selected)
    }

    func testRestoreRejectsOriginalOrdersWithDifferentIDMultisets() {
        let playback = [tracks[0], tracks[0], tracks[1]]
        let invalidOrders = [
            [tracks[0], tracks[1]],
            [tracks[0], tracks[1], tracks[1]],
            [tracks[0], tracks[0], tracks[2]],
            [tracks[0], tracks[0], tracks[1], tracks[1]],
            []
        ]
        for invalid in invalidOrders {
            var queue = PlaybackQueue()
            queue.restore(PlaybackSnapshot(queue: playback, currentIndex: 2, shuffleEnabled: true, originalQueue: invalid))
            XCTAssertEqual(queue.snapshot(position: 0, repeatMode: .off).originalQueue, playback)
            queue.toggleShuffle()
            XCTAssertEqual(queue.tracks, playback)
            XCTAssertEqual(queue.current, tracks[1])
        }
    }

    func testLegacyShuffledSnapshotFallsBackToItsExistingPlaybackOrder() {
        let playback = [tracks[2], tracks[0], tracks[1]]
        var queue = PlaybackQueue()
        queue.restore(PlaybackSnapshot(queue: playback, currentIndex: 1, shuffleEnabled: true))
        queue.toggleShuffle()
        XCTAssertEqual(queue.tracks, playback)
        XCTAssertEqual(queue.current, tracks[0])
        XCTAssertEqual(queue.snapshot(position: 5, repeatMode: .one).originalQueue, playback)
    }

    func testRestoreReusesOccurrenceIdentityAndLiveMetadata() {
        let first = Track(id: "duplicate", title: "First occurrence")
        let second = Track(id: "duplicate", title: "Second occurrence")
        var queue = PlaybackQueue()
        queue.restore(PlaybackSnapshot(queue: [second, tracks[1], first], currentIndex: 0,
            shuffleEnabled: true, originalQueue: [first, second, tracks[1]]))
        let selected = queue.selectedID
        queue.toggleShuffle()
        XCTAssertEqual(queue.tracks, [first, second, tracks[1]])
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(queue.index, 1)
        queue.remove(at: 0)
        XCTAssertEqual(queue.current, second)
        XCTAssertEqual(queue.tracks, [second, tracks[1]])

        let stale = Track(id: tracks[0].id, title: "Stale title", duration: 1)
        queue.restore(PlaybackSnapshot(queue: [tracks[1], tracks[0]], shuffleEnabled: true,
            originalQueue: [stale, tracks[1]]))
        queue.toggleShuffle()
        XCTAssertEqual(queue.tracks, [tracks[0], tracks[1]])
    }

    func testRestoredShuffleEditsSurviveAnotherPersistenceRoundTrip() throws {
        var queue = PlaybackQueue()
        queue.restore(PlaybackSnapshot(queue: [tracks[3], tracks[1], tracks[0], tracks[2]], currentIndex: 1,
            shuffleEnabled: true, originalQueue: Array(tracks.prefix(4))))
        queue.remove(at: 2)
        queue.enqueue(tracks[4], next: true)
        XCTAssertEqual(queue.tracks, [tracks[3], tracks[1], tracks[4], tracks[2]])
        queue.move(from: IndexSet(integer: 1), to: 4)
        XCTAssertEqual(queue.current, tracks[1])
        let expected = [tracks[4], tracks[2], tracks[3], tracks[1]]
        let data = try JSONEncoder().encode(queue.snapshot(position: 10, repeatMode: .off))
        var restored = PlaybackQueue()
        restored.restore(try JSONDecoder().decode(PlaybackSnapshot.self, from: data))
        restored.toggleShuffle()
        XCTAssertEqual(restored.tracks, expected)
        XCTAssertEqual(restored.current, tracks[1])
        XCTAssertEqual(restored.index, 3)
        XCTAssertFalse(restored.tracks.contains(tracks[0]))
    }

    func testNonshuffledRestoreUsesVisibleOrderInsteadOfAStaleOriginalField() {
        let playback = Array(tracks.prefix(3))
        var queue = PlaybackQueue()
        queue.restore(PlaybackSnapshot(queue: playback, originalQueue: Array(playback.reversed())))
        XCTAssertEqual(queue.snapshot(position: 0, repeatMode: .off).originalQueue, playback)
    }
}
