import XCTest
@testable import GanaBajana

final class PlaybackShuffleQueueTests: XCTestCase {
    private let recent = Track(id: "shuffle-queue-recent", title: "Recent", duration: 180)
    private let halfway = Track(id: "shuffle-queue-halfway", title: "Halfway", duration: 180)
    private let fresh = Track(id: "shuffle-queue-fresh", title: "Fresh", duration: 180)

    @MainActor
    func testMappingOnlyPlaybackUpdatePersistsWithoutCreatingASharedMutation() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            var snapshot = PlaybackSnapshot(queue: [recent, recent], position: 17, shuffleEnabled: true,
                                            originalQueue: [recent, recent], originalQueueIndices: [0, 1])
            library.updatePlayback(snapshot)
            let replicaID = UUID()
            let shared = try library.cloudReplica(replicaID: replicaID).state
            var publications = 0
            library.onSyncChange = { publications += 1 }
            snapshot.originalQueueIndices = [1, 0]
            library.updatePlayback(snapshot)
            XCTAssertNil(library.errorMessage)
            let saved = LibraryStore(directory: directory)
            XCTAssertNil(saved.errorMessage)
            XCTAssertEqual(saved.playback.originalQueueIndices, [1, 0])
            XCTAssertEqual(saved.playback.position, 17)
            var restored = PlaybackQueue()
            restored.restore(saved.playback)
            restored.toggleShuffle()
            XCTAssertEqual(restored.index, 1, "The selected identical occurrence must retain its original position")
            XCTAssertEqual(try library.cloudReplica(replicaID: replicaID).state, shared)
            XCTAssertEqual(publications, 0)
        }
    }

    func testShuffledListChoosesFirstAndTailTogetherAndUnshufflesToSourceOrder() {
        let source = [recent, halfway, fresh, recent]
        let policy = policy()
        var generator = PlaybackShuffleTestSupport.ScriptedGenerator(values: Array(repeating: UInt64.max / 2, count: source.count))
        var queue = PlaybackQueue()
        var calls = 0
        queue.replaceShuffled(source) { entries in
            calls += 1
            XCTAssertEqual(entries.map(\.track), source)
            return policy.order(entries, using: &generator).entries
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(queue.tracks, [fresh, halfway, recent, recent])
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(queue.current, fresh)
        XCTAssertEqual(queue.original.map(\.track), source)
        XCTAssertEqual(Set(queue.entries.map(\.id)), Set(queue.original.map(\.id)))
        XCTAssertEqual(queue.entries.count, source.count)
        let selected = queue.selectedID
        queue.toggleShuffle { _ in XCTFail("Unshuffle must not sample another order"); return [] }
        XCTAssertEqual(queue.tracks, source)
        XCTAssertEqual(queue.current, fresh)
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(queue.index, 2)
    }

    func testToggleKeepsTheSelectedDuplicateAndWeightsEveryOtherOccurrence() {
        let source = [recent, halfway, fresh, recent]
        let policy = policy()
        var queue = PlaybackQueue()
        queue.replace(source, startingAt: 3)
        let selected = queue.selectedID
        let originalIDs = queue.original.map(\.id)
        var generator = PlaybackShuffleTestSupport.ScriptedGenerator(values: Array(repeating: UInt64.max / 2, count: 3))
        queue.toggleShuffle { entries in
            XCTAssertEqual(entries.map(\.id), Array(originalIDs.prefix(3)))
            XCTAssertFalse(entries.contains { $0.id == selected })
            return policy.order(entries, using: &generator).entries
        }
        XCTAssertEqual(queue.tracks, [recent, fresh, halfway, recent])
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(queue.entries.first?.id, selected)
        XCTAssertEqual(Set(queue.entries.map(\.id)), Set(originalIDs))
        XCTAssertEqual(queue.tracks.filter { $0 == recent }.count, 2)
        queue.toggleShuffle()
        XCTAssertEqual(queue.tracks, source)
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(queue.index, 3)
    }

    func testExplicitShuffledReplacementPinsTheRequestedSong() {
        let policy = policy()
        var generator = PlaybackShuffleTestSupport.Generator(seed: 7)
        var queue = PlaybackQueue()
        queue.replace([fresh, recent, halfway, recent], startingAt: 3, shuffled: true) {
            policy.order($0, using: &generator).entries
        }
        XCTAssertEqual(queue.current, recent)
        XCTAssertEqual(queue.selectedID, queue.original[3].id)
        XCTAssertEqual(queue.index, 0)
        queue.toggleShuffle()
        XCTAssertEqual(queue.index, 3)
        XCTAssertEqual(queue.tracks, [fresh, recent, halfway, recent])
    }

    func testWeightedSnapshotRoundTripKeepsOrderSelectionAndDuplicateMetadata() throws {
        var otherOccurrence = recent
        otherOccurrence.title = "Selected occurrence metadata"
        let source = [recent, fresh, halfway, otherOccurrence]
        let policy = policy()
        var generator = PlaybackShuffleTestSupport.Generator(seed: 99)
        var queue = PlaybackQueue()
        queue.replace(source, startingAt: 3, shuffled: true) { policy.order($0, using: &generator).entries }
        let saved = queue.snapshot(position: 42, repeatMode: .one)
        let decoded = try roundTrip(saved)
        var restored = PlaybackQueue()
        restored.restore(decoded)
        XCTAssertEqual(restored.tracks, saved.queue)
        XCTAssertEqual(restored.current, otherOccurrence)
        XCTAssertEqual(restored.snapshot(position: decoded.position, repeatMode: decoded.repeatMode).originalQueue, source)
        let selected = restored.selectedID
        restored.toggleShuffle { _ in XCTFail("Restore and unshuffle must reuse the saved order"); return [] }
        XCTAssertEqual(restored.tracks, source)
        XCTAssertEqual(restored.selectedID, selected)
        XCTAssertEqual(restored.current, otherOccurrence)
        XCTAssertEqual(restored.index, 3)
        XCTAssertEqual(decoded.position, 42)
        XCTAssertEqual(decoded.repeatMode, .one)
    }

    func testManualEnqueueRemovalAndMoveRemainDeliberateWhileWeighted() {
        let added = Track(id: "shuffle-manual", title: "Explicitly next", duration: 180)
        let history = [PlaybackShuffleTestSupport.event(added, ageDays: 0), PlaybackShuffleTestSupport.event(halfway, ageDays: 3.5)]
        let policy = PlaybackShufflePolicy(style: .fewerRepeats, history: history, now: PlaybackShuffleTestSupport.now)
        var generator = PlaybackShuffleTestSupport.ScriptedGenerator(values: Array(repeating: UInt64.max / 2, count: 2))
        var queue = PlaybackQueue()
        queue.replace([recent, fresh, halfway], shuffled: true) { policy.order($0, using: &generator).entries }
        let selected = queue.selectedID
        queue.enqueue(added, next: true)
        XCTAssertEqual(queue.tracks, [recent, added, fresh, halfway])
        queue.remove(at: 3)
        queue.move(from: IndexSet(integer: 2), to: 1)
        XCTAssertEqual(queue.tracks, [recent, fresh, added])
        queue.toggleShuffle { _ in XCTFail("Manual edits must survive without another ranking"); return [] }
        XCTAssertEqual(queue.tracks, [recent, fresh, added])
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertFalse(queue.tracks.contains(halfway))
    }

    func testRepeatOneAndQueueWrapReuseTheWeightedOrderWhileManualNextStillAdvances() {
        let policy = policy()
        var generator = PlaybackShuffleTestSupport.Generator(seed: 2)
        var calls = 0
        var queue = PlaybackQueue()
        queue.replaceShuffled([recent, fresh, halfway]) {
            calls += 1
            return policy.order($0, using: &generator).entries
        }
        let ids = queue.entries.map(\.id)
        for _ in 0..<3 {
            XCTAssertTrue(queue.advance(repeatMode: .one, automatic: true))
            XCTAssertEqual(queue.selectedID, ids[0])
        }
        XCTAssertTrue(queue.advance(repeatMode: .one, automatic: false))
        XCTAssertEqual(queue.selectedID, ids[1])
        XCTAssertTrue(queue.advance(repeatMode: .off, automatic: true))
        XCTAssertEqual(queue.selectedID, ids[2])
        XCTAssertFalse(queue.advance(repeatMode: .off, automatic: true))
        XCTAssertTrue(queue.advance(repeatMode: .all, automatic: true))
        XCTAssertEqual(queue.selectedID, ids[0])
        XCTAssertEqual(queue.entries.map(\.id), ids)
        XCTAssertEqual(calls, 1)
    }

    func testOfflineNavigationFollowsWeightedOccurrencesWithoutRerankingOrDroppingDuplicates() throws {
        let policy = policy()
        var generator = PlaybackShuffleTestSupport.ScriptedGenerator(values: Array(repeating: UInt64.max / 2, count: 4))
        var queue = PlaybackQueue()
        queue.replaceShuffled([recent, halfway, fresh, recent]) { policy.order($0, using: &generator).entries }
        let ids = queue.entries.map(\.id)
        XCTAssertEqual(queue.current, fresh)
        let next = try XCTUnwrap(OfflineQueueNavigation.advancing(queue, repeatMode: .off, automatic: false, cachedTrackIDs: [recent.id]))
        XCTAssertEqual(next.selectedID, ids[2])
        let duplicate = try XCTUnwrap(OfflineQueueNavigation.advancing(next, repeatMode: .off, automatic: true, cachedTrackIDs: [recent.id]))
        XCTAssertEqual(duplicate.selectedID, ids[3])
        XCTAssertEqual(duplicate.entries.map(\.id), ids)
        XCTAssertEqual(duplicate.original.map(\.track), [recent, halfway, fresh, recent])
        XCTAssertEqual(OfflineQueueNavigation.advancing(next, repeatMode: .one, automatic: true, cachedTrackIDs: [recent.id])?.selectedID,
                       next.selectedID)
    }

    func testEmptyShuffledReplacementClearsTheOldSelectionAndOriginalOrder() {
        var queue = PlaybackQueue()
        queue.replace([recent, fresh], startingAt: 1)
        queue.replaceShuffled([])
        XCTAssertNil(queue.current)
        XCTAssertNil(queue.selectedID)
        XCTAssertEqual(queue.index, 0)
        XCTAssertTrue(queue.entries.isEmpty)
        XCTAssertTrue(queue.original.isEmpty)
        XCTAssertTrue(queue.shuffled)
        queue.toggleShuffle()
        XCTAssertTrue(queue.tracks.isEmpty)
    }

    func testIdenticalDuplicateRoundTripPreservesTheSecondOccurrenceAndItsNextSong() throws {
        let source = [recent, halfway, recent, fresh]
        XCTAssertEqual(source[0], source[2])
        let policy = policy()
        for shuffledList in [false, true] {
            var queue = PlaybackQueue()
            if shuffledList {
                var generator = PlaybackShuffleTestSupport.ScriptedGenerator(values: [0, UInt64.max / 2, .max, UInt64.max / 2])
                queue.replaceShuffled(source) { policy.order($0, using: &generator).entries }
            } else {
                queue.replace(source, startingAt: 2)
                var generator = PlaybackShuffleTestSupport.ScriptedGenerator(values: Array(repeating: UInt64.max / 2, count: 3))
                queue.toggleShuffle { policy.order($0, using: &generator).entries }
            }
            XCTAssertEqual(queue.selectedID, queue.original[2].id)
            let saved = queue.snapshot(position: 42, repeatMode: .one)
            XCTAssertEqual(saved.originalQueueIndices, [2, 3, 1, 0])
            let decoded = try roundTrip(saved)
            var restored = PlaybackQueue()
            restored.restore(decoded)
            XCTAssertEqual(restored.tracks, saved.queue)
            XCTAssertEqual(restored.current, recent)
            XCTAssertEqual(restored.index, 0)
            let selected = restored.selectedID
            restored.toggleShuffle { _ in XCTFail("Unshuffle must use persisted occurrence identity"); return [] }
            XCTAssertEqual(restored.tracks, source)
            XCTAssertEqual(restored.selectedID, selected)
            XCTAssertEqual(restored.index, 2)
            XCTAssertEqual(restored.snapshot(position: 42, repeatMode: .one).originalQueueIndices, [0, 1, 2, 3])
            XCTAssertTrue(restored.advance(repeatMode: .off, automatic: false))
            XCTAssertEqual(restored.current, fresh, "Next after the second A in [A, B, A, C] is C")
            XCTAssertEqual(decoded.position, 42)
            XCTAssertEqual(decoded.repeatMode, .one)
        }
    }

    func testMappedRestoreKeepsLiveOccurrenceMetadataWhenOriginalMetadataIsStale() throws {
        var selectedTrack = recent
        selectedTrack.title = "Current selected metadata"
        var otherTrack = recent
        otherTrack.title = "Current other occurrence metadata"
        var stale = recent
        stale.title = "Old saved title"
        stale.duration = 1
        let saved = PlaybackSnapshot(queue: [selectedTrack, otherTrack, halfway], shuffleEnabled: true,
                                     originalQueue: [stale, halfway, stale], originalQueueIndices: [2, 0, 1])
        var restored = PlaybackQueue()
        restored.restore(try roundTrip(saved))
        let liveIDs = restored.entries.map(\.id)
        XCTAssertEqual(restored.original.map(\.id), [liveIDs[1], liveIDs[2], liveIDs[0]])
        XCTAssertEqual(restored.original.map(\.track), [otherTrack, halfway, selectedTrack])
        restored.toggleShuffle()
        XCTAssertEqual(restored.current, selectedTrack)
        XCTAssertEqual(restored.selectedID, liveIDs[0])
        XCTAssertEqual(restored.index, 2)
        XCTAssertEqual(restored.tracks, [otherTrack, halfway, selectedTrack])
    }

    func testManualDuplicateEnqueueRemovalAndSelectedOccurrenceMovePersistUpdatedMapping() throws {
        var queue = PlaybackQueue()
        queue.replace([recent, halfway, recent, fresh], startingAt: 2, shuffled: true) { $0 }
        let selected = queue.selectedID
        XCTAssertEqual(queue.snapshot(position: 10, repeatMode: .off).originalQueueIndices, [2, 0, 1, 3])
        queue.enqueue(recent, next: true)
        XCTAssertEqual(queue.snapshot(position: 10, repeatMode: .off).originalQueueIndices, [2, 3, 0, 1, 4])
        queue.remove(at: 2)
        XCTAssertEqual(queue.snapshot(position: 10, repeatMode: .off).originalQueueIndices, [1, 2, 0, 3])
        let currentIndex = queue.index
        queue.move(from: IndexSet(integer: currentIndex), to: 3)
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(queue.index, 2)
        let saved = queue.snapshot(position: 10, repeatMode: .off)
        XCTAssertEqual(saved.queue, [recent, halfway, recent, fresh])
        XCTAssertEqual(saved.originalQueue, [halfway, recent, recent, fresh])
        XCTAssertEqual(saved.originalQueueIndices, [1, 0, 2, 3])
        var restored = PlaybackQueue()
        restored.restore(try roundTrip(saved))
        let restoredSelection = restored.selectedID
        restored.toggleShuffle()
        XCTAssertEqual(restored.tracks, [halfway, recent, recent, fresh])
        XCTAssertEqual(restored.index, 2)
        XCTAssertEqual(restored.selectedID, restoredSelection)
        XCTAssertEqual(restored.tracks.filter { $0 == recent }.count, 2)
        XCTAssertTrue(restored.advance(repeatMode: .off, automatic: false))
        XCTAssertEqual(restored.current, fresh)
    }

    func testUnshuffledManualReorderPersistsIdentityMappingAndSelectedDuplicate() throws {
        var queue = PlaybackQueue()
        queue.replace([recent, halfway, recent, fresh], startingAt: 2)
        queue.move(from: IndexSet(integer: 0), to: 4)
        let saved = queue.snapshot(position: 10, repeatMode: .off)
        XCTAssertEqual(saved.queue, [halfway, recent, fresh, recent])
        XCTAssertEqual(saved.originalQueue, saved.queue)
        XCTAssertEqual(saved.originalQueueIndices, [0, 1, 2, 3])
        var restored = PlaybackQueue()
        restored.restore(try roundTrip(saved))
        XCTAssertFalse(restored.shuffled)
        XCTAssertEqual(restored.tracks, saved.queue)
        XCTAssertEqual(restored.index, 1)
        XCTAssertTrue(restored.advance(repeatMode: .off, automatic: false))
        XCTAssertEqual(restored.current, fresh)
    }

    func testLegacyMissingAndNullMappingKeepTrackBasedFallback() throws {
        let legacy = PlaybackSnapshot(queue: [recent, fresh, halfway, recent], shuffleEnabled: true,
                                      originalQueue: [recent, halfway, recent, fresh])
        XCTAssertNil(legacy.originalQueueIndices)
        let data = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["originalQueueIndices"])
        for explicitNull in [false, true] {
            if explicitNull { object["originalQueueIndices"] = NSNull() }
            let decoded = try JSONDecoder().decode(PlaybackSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(decoded.originalQueueIndices)
            XCTAssertNoThrow(try LibraryValidation.validatePlayback(decoded))
            var restored = PlaybackQueue()
            restored.restore(decoded)
            let selected = restored.selectedID
            restored.toggleShuffle()
            XCTAssertEqual(restored.tracks, legacy.originalQueue)
            XCTAssertEqual(restored.selectedID, selected)
            XCTAssertEqual(restored.index, 0, "A legacy file has no evidence distinguishing identical A occurrences")
        }
        var withoutOriginal = legacy
        withoutOriginal.originalQueue = nil
        var restored = PlaybackQueue()
        restored.restore(try roundTrip(withoutOriginal))
        restored.toggleShuffle()
        XCTAssertEqual(restored.tracks, legacy.queue)
    }

    func testLegacyRestoreAndPlainCheckpointsPreserveSnapshotEncoding() throws {
        let source = [recent, halfway, recent, fresh]
        let snapshots = [
            PlaybackSnapshot(queue: [halfway, recent, recent], currentIndex: 2, position: 47.375,
                shuffleEnabled: true, repeatMode: .all, originalQueue: [recent, halfway, recent]),
            PlaybackSnapshot(queue: [recent, fresh, halfway, recent], position: 17,
                shuffleEnabled: true, repeatMode: .one, originalQueue: source),
            PlaybackSnapshot(queue: source, currentIndex: 2, position: 17, originalQueue: source),
            PlaybackSnapshot(queue: [recent], position: 17, originalQueue: [recent]),
            PlaybackSnapshot(originalQueue: [])
        ]
        for saved in snapshots {
            let legacy = try roundTrip(saved)
            let before = try encodeSnapshot(legacy)
            var queue = PlaybackQueue()
            queue.replaceShuffled(source) { $0 }
            queue.restore(legacy)
            for _ in 0..<3 {
                let checkpoint = queue.snapshot(position: legacy.position, repeatMode: legacy.repeatMode)
                XCTAssertNil(checkpoint.originalQueueIndices)
                XCTAssertEqual(checkpoint.originalQueue, legacy.originalQueue)
                XCTAssertEqual(try encodeSnapshot(checkpoint), before)
                queue.restore(try roundTrip(checkpoint))
            }
            let position = legacy.queue.isEmpty ? 0 : legacy.position + 0.5
            XCTAssertNil(queue.snapshot(position: position, repeatMode: .one).originalQueueIndices)
        }
    }

    func testExistingMappingRoundTripsThroughPlainRestoreAndCheckpoints() throws {
        let saved = PlaybackSnapshot(queue: [recent, fresh, halfway, recent], position: 47.375,
            shuffleEnabled: true, repeatMode: .all, originalQueue: [recent, halfway, recent, fresh],
            originalQueueIndices: [2, 3, 1, 0])
        let before = try encodeSnapshot(saved)
        var queue = PlaybackQueue()
        queue.restore(try roundTrip(saved))
        for _ in 0..<3 {
            let checkpoint = queue.snapshot(position: saved.position, repeatMode: saved.repeatMode)
            XCTAssertEqual(checkpoint.originalQueueIndices, saved.originalQueueIndices)
            XCTAssertEqual(try encodeSnapshot(checkpoint), before)
            queue.restore(try roundTrip(checkpoint))
        }
        queue.toggleShuffle()
        XCTAssertEqual(queue.index, 2)
        XCTAssertEqual(queue.snapshot(position: saved.position, repeatMode: saved.repeatMode).originalQueueIndices, [0, 1, 2, 3])
    }

    func testLegacyQueueMutationsOptIntoCorrectOccurrenceMappings() throws {
        let source = [recent, halfway, recent, fresh]
        let duplicate = recent
        let legacy = PlaybackSnapshot(queue: source, currentIndex: 2, position: 17, originalQueue: source)
        let operations: [(name: String, apply: (inout PlaybackQueue) -> Void, expected: [Int])] = [
            ("replace", { $0.replace(source, startingAt: 2) }, [0, 1, 2, 3]),
            ("replace shuffled", { queue in queue.replaceShuffled(source) { Array($0.reversed()) } }, [3, 2, 1, 0]),
            ("clear", { $0.replace([]) }, []),
            ("shuffle", { queue in queue.toggleShuffle { $0 } }, [2, 0, 1, 3]),
            ("enqueue identical occurrence", { $0.enqueue(duplicate, next: true) }, [0, 1, 2, 3, 4]),
            ("remove", { $0.remove(at: 0) }, [0, 1, 2]),
            ("move", { $0.move(from: IndexSet(integer: 0), to: 4) }, [0, 1, 2, 3]),
            ("manual next", { _ = $0.advance(repeatMode: .one, automatic: false) }, [0, 1, 2, 3]),
            ("automatic next", { _ = $0.advance(repeatMode: .off, automatic: true) }, [0, 1, 2, 3]),
            ("previous", { $0.previous(repeatMode: .off) }, [0, 1, 2, 3])
        ]
        for (name, apply, expected) in operations {
            var queue = PlaybackQueue()
            queue.restore(legacy)
            XCTAssertNil(queue.snapshot(position: 17, repeatMode: .off).originalQueueIndices, name)
            apply(&queue)
            let checkpoint = queue.snapshot(position: queue.current == nil ? 0 : 17, repeatMode: .off)
            XCTAssertEqual(checkpoint.originalQueueIndices, expected, name)
            let decoded = try roundTrip(checkpoint)
            var restored = PlaybackQueue()
            restored.restore(decoded)
            XCTAssertEqual(restored.snapshot(position: decoded.position, repeatMode: decoded.repeatMode).originalQueueIndices,
                           expected, name)
        }

        let shuffled = PlaybackSnapshot(queue: [halfway, recent, recent], currentIndex: 2, position: 17,
            shuffleEnabled: true, originalQueue: [recent, halfway, recent])
        var queue = PlaybackQueue()
        queue.restore(shuffled)
        queue.toggleShuffle { _ in XCTFail("Unshuffle must not sample a new order"); return [] }
        let checkpoint = try roundTrip(queue.snapshot(position: 17, repeatMode: .off))
        XCTAssertEqual(checkpoint.queue, shuffled.originalQueue)
        XCTAssertEqual(checkpoint.currentIndex, 2)
        XCTAssertEqual(checkpoint.originalQueueIndices, [0, 1, 2])
    }

    func testIdenticalOccurrenceReorderOptsInEvenWhenTrackValuesAndSelectionIndexMatch() throws {
        let legacy = PlaybackSnapshot(queue: [recent, recent, recent], position: 17, shuffleEnabled: true,
                                      originalQueue: [recent, recent, recent])
        var queue = PlaybackQueue()
        queue.restore(legacy)
        let originalIDs = queue.entries.map(\.id)
        let selected = queue.selectedID
        queue.move(from: IndexSet(integer: 1), to: 3)
        let checkpoint = try roundTrip(queue.snapshot(position: 17, repeatMode: .off))
        XCTAssertEqual(queue.entries.map(\.id), [originalIDs[0], originalIDs[2], originalIDs[1]])
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(checkpoint.queue, legacy.queue)
        XCTAssertEqual(checkpoint.originalQueue, legacy.originalQueue)
        XCTAssertEqual(checkpoint.currentIndex, legacy.currentIndex)
        XCTAssertEqual(checkpoint.shuffleEnabled, legacy.shuffleEnabled)
        XCTAssertEqual(checkpoint.originalQueueIndices, [0, 1, 2])
        XCTAssertNotEqual(try encodeSnapshot(checkpoint), try encodeSnapshot(legacy))
    }

    func testSelectingAnotherIdenticalOccurrenceOptsInAndSurvivesUnshuffle() throws {
        for forward in [false, true] {
            let legacy = PlaybackSnapshot(queue: [halfway, recent, recent, fresh], currentIndex: forward ? 1 : 2,
                position: 17, shuffleEnabled: true, originalQueue: [recent, halfway, recent, fresh])
            var queue = PlaybackQueue()
            queue.restore(legacy)
            let selected = queue.selectedID
            if forward { XCTAssertTrue(queue.advance(repeatMode: .one, automatic: false)) }
            else { queue.previous(repeatMode: .off) }
            XCTAssertEqual(queue.current, recent)
            XCTAssertNotEqual(queue.selectedID, selected)
            let checkpoint = try roundTrip(queue.snapshot(position: 17, repeatMode: .off))
            XCTAssertEqual(checkpoint.originalQueueIndices, [1, 0, 2, 3])
            var restored = PlaybackQueue()
            restored.restore(checkpoint)
            restored.toggleShuffle()
            XCTAssertEqual(restored.index, forward ? 2 : 0)
            XCTAssertTrue(restored.advance(repeatMode: .off, automatic: false))
            XCTAssertEqual(restored.current, forward ? fresh : halfway)
        }
    }

    func testNoOpNavigationEditsAndDiscardedProbesKeepLegacyMappingAbsent() throws {
        let sources: [[Track]] = [[], [recent], [recent, halfway, recent, fresh]]
        for source in sources {
            for shuffled in [false, true] {
                let position: TimeInterval = source.isEmpty ? 0 : 17
                let legacy = PlaybackSnapshot(queue: source, position: position, shuffleEnabled: shuffled, originalQueue: source)
                let before = try encodeSnapshot(legacy)
                var queue = PlaybackQueue()
                queue.restore(legacy)
                XCTAssertEqual(queue.advance(repeatMode: .one, automatic: true), !source.isEmpty)
                queue.previous(repeatMode: .off)
                queue.remove(at: -1)
                queue.remove(at: source.count)
                queue.move(from: IndexSet(), to: 0)
                queue.move(from: IndexSet(integer: source.count), to: 0)
                if !source.isEmpty {
                    queue.move(from: IndexSet(integer: 0), to: 0)
                    queue.move(from: IndexSet(integer: 0), to: 1)
                }
                if source.count == 1 {
                    XCTAssertTrue(queue.advance(repeatMode: .all, automatic: true))
                    XCTAssertTrue(queue.advance(repeatMode: .all, automatic: false))
                    queue.previous(repeatMode: .all)
                }
                let checkpoint = queue.snapshot(position: position, repeatMode: .off)
                XCTAssertNil(checkpoint.originalQueueIndices)
                XCTAssertEqual(try encodeSnapshot(checkpoint), before)
                if source.count > 1 {
                    var probe = queue
                    XCTAssertTrue(probe.advance(repeatMode: .off, automatic: true))
                    XCTAssertNotNil(probe.snapshot(position: position, repeatMode: .off).originalQueueIndices)
                    XCTAssertEqual(try encodeSnapshot(queue.snapshot(position: position, repeatMode: .off)), before)
                }
                var last = legacy
                last.currentIndex = max(0, source.count - 1)
                queue.restore(last)
                XCTAssertFalse(queue.advance(repeatMode: .off, automatic: true))
                XCTAssertEqual(try encodeSnapshot(queue.snapshot(position: position, repeatMode: .off)), try encodeSnapshot(last))
                if source.count > 1 {
                    XCTAssertTrue(queue.advance(repeatMode: .all, automatic: true))
                    XCTAssertEqual(queue.index, 0)
                    XCTAssertNotNil(queue.snapshot(position: position, repeatMode: .all).originalQueueIndices)
                    queue.restore(legacy)
                    queue.previous(repeatMode: .all)
                    XCTAssertEqual(queue.index, source.count - 1)
                    XCTAssertNotNil(queue.snapshot(position: position, repeatMode: .all).originalQueueIndices)
                }
            }
        }
    }

    func testEmptyAndSingletonMappingsRoundTripWithTheirOriginalQueue() throws {
        for source in [[], [recent]] {
            for shuffled in [false, true] {
                var queue = PlaybackQueue()
                queue.replace(source, shuffled: shuffled)
                let saved = queue.snapshot(position: 0, repeatMode: .off)
                XCTAssertEqual(saved.originalQueueIndices, Array(source.indices))
                let decoded = try roundTrip(saved)
                var restored = PlaybackQueue()
                restored.restore(decoded)
                XCTAssertEqual(restored.tracks, source)
                XCTAssertEqual(restored.original.map(\.track), source)
                XCTAssertEqual(restored.shuffled, shuffled)
            }
        }
    }

    func testMalformedPresentMappingsAreRejectedAndDirectRestoreKeepsTheVisibleOrder() throws {
        for (name, snapshot) in malformedSnapshots() {
            XCTAssertThrowsError(try LibraryValidation.validatePlayback(snapshot), name)
            var restored = PlaybackQueue()
            restored.restore(snapshot)
            XCTAssertEqual(restored.tracks, snapshot.queue, name)
            XCTAssertEqual(restored.original.map(\.id), restored.entries.map(\.id), name)
            let selected = restored.selectedID
            if restored.shuffled { restored.toggleShuffle() }
            XCTAssertEqual(restored.tracks, snapshot.queue, name)
            XCTAssertEqual(restored.selectedID, selected, name)
            XCTAssertEqual(restored.current, snapshot.queue.first, name)
            XCTAssertEqual(restored.index, 0, name)
        }
    }

    @MainActor
    func testMalformedStoredMappingsBlockLoadingAndPreserveLibraryBytes() async throws {
        for (name, snapshot) in malformedSnapshots() {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                document.favorites = [recent]
                document.playback = snapshot
                let data = try LibraryPersistence.encode(document)
                XCTAssertThrowsError(try LibraryPersistence.decode(data, now: PlaybackShuffleTestSupport.now), name)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(data, to: url, replacing: nil)
                let store = LibraryStore(directory: directory)
                let error = try XCTUnwrap(store.errorMessage, name)
                store.updatePlayback(PlaybackSnapshot())
                store.toggleFavorite(recent)
                XCTAssertEqual(store.errorMessage, error, name)
                XCTAssertEqual(try Data(contentsOf: url), data, name)
            }
        }
    }

    func testMalformedMappingJSONTypesCannotSilentlyDecodeAsLegacy() throws {
        let valid = PlaybackSnapshot(queue: [recent, halfway], shuffleEnabled: true,
                                     originalQueue: [halfway, recent], originalQueueIndices: [1, 0])
        let encoded = try JSONEncoder().encode(valid)
        let invalidValues: [Any] = [1, "1,0", ["1", "0"], [0.5, 1], [true, false]]
        for value in invalidValues {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object["originalQueueIndices"] = value
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(PlaybackSnapshot.self, from: data))
        }
    }

    private func malformedSnapshots() -> [(String, PlaybackSnapshot)] {
        let valid = PlaybackSnapshot(queue: [recent, fresh, halfway, recent], shuffleEnabled: true,
                                     originalQueue: [recent, halfway, recent, fresh], originalQueueIndices: [2, 3, 1, 0])
        let mappings: [(String, [Int])] = [
            ("empty mapping", []), ("short mapping", [2, 3, 1]), ("long mapping", [2, 3, 1, 0, 4]),
            ("negative index", [2, 3, 1, -1]), ("upper boundary", [2, 3, 1, 4]),
            ("maximum index", [2, 3, 1, .max]), ("minimum index", [2, 3, 1, .min]),
            ("duplicate index for identical track", [2, 3, 1, 2]), ("wrong track identity", [1, 3, 2, 0])
        ]
        var snapshots: [(String, PlaybackSnapshot)] = mappings.map { name, indices in
            var snapshot = valid
            snapshot.originalQueueIndices = indices
            return (name, snapshot)
        }
        var absent = valid
        absent.originalQueue = nil
        snapshots.append(("missing original queue", absent))
        var wrongLength = valid
        wrongLength.originalQueue = [recent, halfway, fresh]
        snapshots.append(("wrong original queue length", wrongLength))
        var wrongOrder = valid
        wrongOrder.originalQueue = [halfway, recent, recent, fresh]
        snapshots.append(("wrong corresponding original order", wrongOrder))
        snapshots.append(("unshuffled nonidentity occurrence mapping", PlaybackSnapshot(queue: [recent, recent],
            originalQueue: [recent, recent], originalQueueIndices: [1, 0])))
        snapshots.append(("empty mapping without original queue", PlaybackSnapshot(originalQueueIndices: [])))
        snapshots.append(("nonempty mapping for empty queues", PlaybackSnapshot(originalQueue: [], originalQueueIndices: [0])))
        return snapshots
    }

    private func roundTrip(_ snapshot: PlaybackSnapshot) throws -> PlaybackSnapshot {
        try LibraryValidation.validatePlayback(snapshot)
        let data = try encodeSnapshot(snapshot)
        let decoded = try JSONDecoder().decode(PlaybackSnapshot.self, from: data)
        try LibraryValidation.validatePlayback(decoded)
        return decoded
    }

    private func encodeSnapshot(_ snapshot: PlaybackSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    private func policy() -> PlaybackShufflePolicy {
        PlaybackShufflePolicy(style: .fewerRepeats,
            history: [PlaybackShuffleTestSupport.event(recent, ageDays: 0), PlaybackShuffleTestSupport.event(halfway, ageDays: 3.5)],
            now: PlaybackShuffleTestSupport.now)
    }
}
