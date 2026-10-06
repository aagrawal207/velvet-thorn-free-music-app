import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class SeedRadioQueueRetentionTests: XCTestCase {
    private let seed = Track(id: "retention-seed", title: "Seed", duration: 180)

    func testRepeatedEightSongRefillsRetainFortyPreviousSelectionsAndBoundExclusionMemory() throws {
        let player = makePlayer()
        let tracks = generated(200)
        let seedID = try XCTUnwrap(player.queueEntries.first?.id)
        var latestSnapshot: PlaybackSnapshot?
        player.onSnapshotChanged = { latestSnapshot = $0 }

        for start in stride(from: 0, to: tracks.count, by: 8) {
            player.appendAutoplay(Array(tracks[start..<(start + 8)]))
            for track in tracks[start..<(start + 8)] {
                let revision = player.controlRevision
                player.next()
                XCTAssertEqual(player.controlRevision, revision + 1, "Pruning adds no transport revision.")
                XCTAssertEqual(player.currentTrack, track)
                XCTAssertLessThanOrEqual(player.currentIndex, 41)
            }
        }

        XCTAssertEqual(player.queue, [seed] + Array(tracks[159...199]))
        XCTAssertEqual(player.generatedRadioEntryIDs.count, 41)
        XCTAssertEqual(player.radioRecentTracks, Array(tracks[31...158]))
        XCTAssertEqual(player.autoplayTrackIDs, Set(tracks[159...199].map(\.id)))
        XCTAssertEqual(player.queueEntries.first?.id, seedID)
        XCTAssertEqual(player.currentIndex, 41)
        let currentID = player.queueEntries[player.currentIndex].id
        player.seek(to: 37)
        let revision = player.controlRevision
        let identity = player.activePlayerIdentity
        player.appendAutoplay([tracks[158], tracks[199], Track(id: "next-refill", title: "Next")])
        XCTAssertEqual(player.queue.count, 43, "A pruned recent recording is still excluded.")
        XCTAssertEqual(player.queueEntries[player.currentIndex].id, currentID)
        XCTAssertEqual(player.position, 37)
        XCTAssertEqual(player.activePlayerIdentity, identity)
        XCTAssertEqual(player.controlRevision, revision)
        XCTAssertFalse(player.isPlaying)
        try assertValidMapping(XCTUnwrap(latestSnapshot))
    }

    func testManualDuplicatesKeepExactOccurrencesWhileTheirGeneratedTwinIsPruned() throws {
        let player = makePlayer()
        let tracks = generated(52)
        appendInBatches(tracks, to: player)
        let generatedIDs = player.generatedRadioEntryIDs
        let generatedTwin = try XCTUnwrap(player.queueEntries.first { $0.track == tracks[0] }?.id)
        player.enqueue(tracks[0], next: true)
        player.enqueue(tracks[0])
        let manualIDs = Set(player.queueEntries.map(\.id)).subtracting(generatedIDs)

        for track in tracks.prefix(50) { try select(track, in: player) }

        XCTAssertFalse(player.generatedRadioEntryIDs.contains(generatedTwin))
        XCTAssertFalse(player.queueEntries.contains { $0.id == generatedTwin })
        XCTAssertTrue(manualIDs.isSubset(of: Set(player.queueEntries.map(\.id))))
        XCTAssertTrue(manualIDs.isDisjoint(with: player.generatedRadioEntryIDs))
        XCTAssertEqual(player.queue.filter { $0 == tracks[0] }.count, 2)
        XCTAssertEqual(player.queue.filter { $0 == tracks[50] || $0 == tracks[51] }, Array(tracks[50...51]))
        XCTAssertEqual(player.currentTrack, tracks[49])
        XCTAssertEqual(player.currentIndex, 42)

        let entries = player.queueEntries.map(\.id)
        player.seek(to: 29)
        let revision = player.controlRevision
        player.refreshSeedRadioRequests()
        XCTAssertEqual(player.queueEntries.map(\.id), entries)
        XCTAssertEqual(player.generatedRadioEntryIDs.count, 43)
        XCTAssertEqual(player.radioRecentTracks, Array(tracks[0...8]))
        XCTAssertEqual(player.position, 29)
        XCTAssertEqual(player.controlRevision, revision)
    }

    func testShuffleAndQueueJumpsNeverTurnUnselectedPredecessorsIntoPlayedHistory() throws {
        let player = makePlayer()
        let tracks = generated(64)
        appendInBatches(tracks, to: player)
        let unheardIDs = Set(player.queueEntries.filter { tracks[48...63].contains($0.track) }.map(\.id))
        for track in tracks.prefix(48) { try select(track, in: player) }
        let currentID = player.queueEntries[player.currentIndex].id
        let unheardLastIndex = try XCTUnwrap(player.queue.firstIndex(of: tracks[63]))
        player.moveQueue(from: IndexSet(integer: unheardLastIndex), to: 0)
        player.seek(to: 23)
        player.toggleShuffle()
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.queueEntries[player.currentIndex].id, currentID)
        player.toggleShuffle()
        XCTAssertEqual(player.queueEntries[player.currentIndex].id, currentID)
        XCTAssertEqual(player.position, 23)
        XCTAssertTrue(unheardIDs.isSubset(of: Set(player.queueEntries.map(\.id))))

        // Jumping over untouched occurrences must not manufacture selection history for them.
        try select(tracks[62], in: player)
        XCTAssertTrue(unheardIDs.isSubset(of: Set(player.queueEntries.map(\.id))))
        XCTAssertEqual(player.radioRecentTracks, Array(tracks[0...7]))
        XCTAssertEqual(player.queue.first, tracks[63])
    }

    func testMostRecentlySelectedHistoryWinsAndPlayedUpcomingEntriesStayProtected() throws {
        let player = makePlayer()
        let tracks = generated(50)
        appendInBatches(tracks, to: player)
        let allIDs = player.queueEntries.map(\.id)
        for track in tracks.reversed() { try select(track, in: player) }
        XCTAssertEqual(player.queueEntries.map(\.id), allIDs, "Previously selected upcoming entries stay queued.")
        XCTAssertTrue(player.radioRecentTracks.isEmpty)
        player.toggleShuffle()
        player.toggleShuffle()
        XCTAssertEqual(player.queueEntries.map(\.id), allIDs)

        var snapshot: PlaybackSnapshot?
        player.onSnapshotChanged = { snapshot = $0 }
        try select(tracks[49], in: player)
        XCTAssertEqual(player.queue, [seed] + Array(tracks[0...39]) + [tracks[49]])
        XCTAssertEqual(player.radioRecentTracks, Array(tracks[40...48].reversed()))
        XCTAssertEqual(player.generatedRadioEntryIDs.count, 41)
        try assertValidMapping(XCTUnwrap(snapshot))
    }

    func testQueueSelectionKeepsRadioAndDuplicateIdentityAndRejectsInvalidIndexes() throws {
        let player = makePlayer()
        let track = generated(1)[0]
        player.appendAutoplay([track])
        player.enqueue(track)
        let ids = player.queueEntries.map(\.id)
        let generatedIDs = player.generatedRadioEntryIDs
        player.toggleShuffle()
        let manualIndex = try XCTUnwrap(player.queueEntries.firstIndex { $0.id == ids[2] })
        let revision = player.controlRevision
        XCTAssertTrue(player.selectQueueTrack(at: manualIndex))
        XCTAssertEqual(player.controlRevision, revision + 1)
        player.pause()
        XCTAssertEqual(player.queueEntries[player.currentIndex].id, ids[2])
        XCTAssertEqual(player.generatedRadioEntryIDs, generatedIDs)
        XCTAssertTrue(player.isRadioSession)
        XCTAssertTrue(player.shuffleEnabled)
        player.toggleShuffle()
        XCTAssertEqual(player.queueEntries.map(\.id), ids)
        XCTAssertEqual(player.currentIndex, 2)
        let unchangedRevision = player.controlRevision
        XCTAssertFalse(player.selectQueueTrack(at: -1))
        XCTAssertFalse(player.selectQueueTrack(at: player.queue.count))
        XCTAssertEqual(player.controlRevision, unchangedRevision)
        XCTAssertEqual(player.queueEntries.map(\.id), ids)
        player.removeFromQueue(at: 1)
        XCTAssertTrue(player.generatedRadioEntryIDs.isEmpty)
        XCTAssertEqual(player.queueEntries[player.currentIndex].id, ids[2])
        XCTAssertEqual(player.queue, [seed, track])
    }

    func testPruningWhileShuffledPersistsSurvivingOriginalOccurrencesAndUnshufflesWithoutRestart() throws {
        let player = makePlayer()
        let tracks = generated(56)
        appendInBatches(tracks, to: player)
        player.enqueue(tracks[0])
        player.enqueue(tracks[0])
        let original = player.queueEntries
        let generatedIDs = player.generatedRadioEntryIDs
        player.toggleShuffle()
        let playOrder = player.queueEntries
        let lastID = try XCTUnwrap(playOrder.last?.id)
        let previousGenerated = playOrder.dropLast().filter { generatedIDs.contains($0.id) }
        let expectedIDs = Set(previousGenerated.suffix(40).map(\.id))
            .union(original.filter { !generatedIDs.contains($0.id) }.map(\.id))
            .union([lastID])
        while player.currentIndex + 1 < player.queue.count { player.next() }
        XCTAssertEqual(Set(player.queueEntries.map(\.id)), expectedIDs)
        XCTAssertEqual(player.queueEntries[player.currentIndex].id, lastID)
        player.seek(to: 43)
        var snapshot: PlaybackSnapshot?
        player.onSnapshotChanged = { snapshot = $0 }
        player.handleLifecycleCheckpoint()
        let saved = try XCTUnwrap(snapshot)
        try assertValidMapping(saved)
        var restored = PlaybackQueue()
        restored.restore(saved)
        restored.toggleShuffle()
        let survivingOriginal = original.filter { expectedIDs.contains($0.id) }
        XCTAssertEqual(restored.tracks, survivingOriginal.map(\.track))
        XCTAssertEqual(restored.index, try XCTUnwrap(survivingOriginal.firstIndex { $0.id == lastID }))

        let revision = player.controlRevision
        let identity = player.activePlayerIdentity
        player.toggleShuffle()
        XCTAssertEqual(player.queueEntries.map(\.id), survivingOriginal.map(\.id))
        XCTAssertEqual(player.queueEntries[player.currentIndex].id, lastID)
        XCTAssertEqual(player.position, 43)
        XCTAssertEqual(player.activePlayerIdentity, identity)
        XCTAssertEqual(player.controlRevision, revision + 1)
    }

    func testReplacementPathsClearProvenanceAndRecentMemoryWithoutRetaggingOldOccurrences() async throws {
        for replacement in ["play", "shuffle", "restore", "live", "radio", "attach"] {
            let live = LiveRadioResolutionGate()
            let player = makePlayer(live: live)
            let tracks = generated(48)
            appendInBatches(tracks, to: player)
            for _ in tracks { player.next() }
            XCTAssertFalse(player.radioRecentTracks.isEmpty, replacement)
            let entries = player.queueEntries.map(\.id)
            player.seek(to: 31)
            let revision = player.controlRevision
            let identity = player.activePlayerIdentity

            switch replacement {
            case "play": player.play([seed])
            case "shuffle": player.playShuffled([seed])
            case "restore": player.restore(PlaybackSnapshot(queue: [seed], position: 11))
            case "live":
                XCTAssertTrue(player.playLiveRadio(LiveRadioTestSupport.station))
                try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
            case "radio": player.play([seed], isRadio: true)
            default:
                XCTAssertTrue(player.configureSeedRadio(keeping: tracks[47].id))
                XCTAssertEqual(player.queueEntries.map(\.id), entries)
                XCTAssertEqual(player.position, 31)
                XCTAssertEqual(player.controlRevision, revision)
                XCTAssertEqual(player.activePlayerIdentity, identity)
            }
            player.pause()
            await live.cancelRemaining()
            XCTAssertTrue(player.generatedRadioEntryIDs.isEmpty, replacement)
            XCTAssertTrue(player.radioRecentTracks.isEmpty, replacement)
            player.appendAutoplay([Track(id: "replacement-refill", title: "Replacement")])
            XCTAssertEqual(player.generatedRadioEntryIDs.count, replacement == "attach" ? 1 : 0, replacement)
        }
    }

    func testOrdinaryAutoplayAndFailedAttachmentDoNotAcquireSeedRadioProvenance() {
        let player = makePlayer(configure: false)
        let tracks = generated(56)
        appendInBatches(tracks, to: player)
        XCTAssertFalse(player.configureSeedRadio(keeping: "not-current"))
        for _ in tracks { player.next() }
        XCTAssertEqual(player.queue, [seed] + tracks)
        XCTAssertTrue(player.generatedRadioEntryIDs.isEmpty)
        XCTAssertTrue(player.radioRecentTracks.isEmpty)
        XCTAssertFalse(player.isRadioSession)
    }

    func testQueueHousekeepingPreservesOriginalPermutationAndCurrentAndUpcomingUUIDs() throws {
        var queue = PlaybackQueue()
        let tracks = generated(5)
        queue.replace([tracks[0], tracks[0]] + Array(tracks[1...4]), startingAt: 1)
        let original = queue.entries
        queue.toggleShuffle { Array($0.reversed()) }
        XCTAssertTrue(queue.select(at: 3))
        let selected = try XCTUnwrap(queue.selectedID)
        let upcoming = Array(queue.entries.dropFirst(queue.index).map(\.id))
        let removalCandidates = Set([original[0].id, original[1].id, original[5].id, selected])
        let removed = queue.removePreviousEntries(withIDs: removalCandidates)
        XCTAssertEqual(Set(removed.map(\.id)), Set([original[1].id, original[5].id]))
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(Array(queue.entries.dropFirst(queue.index).map(\.id)), upcoming)
        try assertValidMapping(queue.snapshot(position: 39, repeatMode: .off))
        queue.toggleShuffle()
        XCTAssertEqual(queue.entries.map(\.id), [original[0].id, original[2].id, original[3].id, original[4].id])
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertFalse(queue.select(at: -1))
    }

    private func makePlayer(configure: Bool = true, live: LiveRadioResolutionGate = LiveRadioResolutionGate()) -> PlayerController {
        let resolver = PlaybackResolutionGate()
        let player = PlayerController(resolver: resolver, liveRadioResolver: live)
        player.restore(PlaybackSnapshot(queue: [seed], position: 17))
        if configure { XCTAssertTrue(player.configureSeedRadio(keeping: seed.id)) }
        addTeardownBlock { @MainActor in
            player.pause()
            await resolver.cancelRemaining()
            await live.cancelRemaining()
        }
        return player
    }

    private func generated(_ count: Int) -> [Track] {
        (0..<count).map { Track(id: "radio-generated-\($0)", title: "Generated \($0)", duration: 180) }
    }

    private func appendInBatches(_ tracks: [Track], to player: PlayerController) {
        for start in stride(from: 0, to: tracks.count, by: 8) {
            player.appendAutoplay(Array(tracks[start..<min(start + 8, tracks.count)]))
        }
    }

    private func select(_ track: Track, in player: PlayerController) throws {
        let index = try XCTUnwrap(player.queueEntries.firstIndex {
            $0.track == track && player.generatedRadioEntryIDs.contains($0.id)
        })
        XCTAssertTrue(player.selectQueueTrack(at: index))
        player.pause()
    }

    private func assertValidMapping(_ snapshot: PlaybackSnapshot) throws {
        try LibraryValidation.validateOriginalQueueIndices(snapshot)
        let indices = try XCTUnwrap(snapshot.originalQueueIndices)
        let original = try XCTUnwrap(snapshot.originalQueue)
        XCTAssertEqual(Set(indices), Set(snapshot.queue.indices))
        XCTAssertEqual(snapshot.queue, indices.map { original[$0] })
    }
}
