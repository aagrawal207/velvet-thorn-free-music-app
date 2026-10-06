import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class CompanionPlaybackControllerTests: XCTestCase {
    func testInitializationRegistryAndReadRequestsKeepRestoredPlaybackPaused() async throws {
        let song = libraryTestTrack()
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song], position: 37))
        let bytes = try savedBytes(context)
        let controller = CompanionPlaybackController(model: context.model)
        let previous = CompanionRuntime.playback
        defer { CompanionRuntime.playback = previous }
        CompanionRuntime.playback = controller
        XCTAssertTrue(CompanionRuntime.playback === controller)
        var received: [CompanionSnapshot] = []
        let observation = controller.observe { received.append($0) }
        defer { controller.removeObserver(observation) }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].nowPlaying?.trackID, song.id)
        XCTAssertEqual(received[0].nowPlaying?.position, 37)
        XCTAssertTrue(controller.handle(.init(action: .snapshot)).accepted)
        XCTAssertEqual(try page("root", on: controller).items.count, 4)
        await Task.yield()
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertEqual(context.player.position, 37)
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertTrue(context.library.recentlyPlayed.isEmpty)
        let requests = await context.streams.streams.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(try savedBytes(context), bytes)
    }

    func testObservationRefreshesWithoutReplacingAnyPlayerOrLibraryCallback() async throws {
        let song = libraryTestTrack()
        let next = libraryTestTrack("next")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song]))
        let saveSnapshot = try XCTUnwrap(context.player.onSnapshotChanged)
        let recordListening = try XCTUnwrap(context.player.onListeningProgress)
        let recordStart = try XCTUnwrap(context.player.onTrackStarted)
        let clearHistory = try XCTUnwrap(context.library.onHistoryCleared)
        var checkpoints = 0
        var listens = 0
        var starts = 0
        var clears = 0
        context.player.onSnapshotChanged = { checkpoints += 1; saveSnapshot($0) }
        context.player.onListeningProgress = { track, session, started, seconds in
            listens += 1
            return recordListening(track, session, started, seconds)
        }
        context.player.onTrackStarted = { starts += 1; recordStart($0) }
        context.library.onHistoryCleared = { clears += 1; clearHistory() }

        let controller = CompanionPlaybackController(model: context.model)
        var received: [CompanionSnapshot] = []
        let observation = controller.observe { received.append($0) }
        defer { controller.removeObserver(observation) }
        context.player.seek(to: 31)
        try await AppModelFixtures.eventually { received.last?.nowPlaying?.position == 31 }
        XCTAssertGreaterThan(checkpoints, 0)
        XCTAssertEqual(context.library.playback.position, 31)
        context.library.toggleFavorite(song)
        try await AppModelFixtures.eventually { received.last?.nowPlaying?.isFavorite == true }
        XCTAssertEqual(received.last?.nowPlaying?.isSuperLiked, false)
        context.library.setSuperLiked(song, true)
        try await AppModelFixtures.eventually { received.last?.nowPlaying?.isSuperLiked == true }
        XCTAssertEqual(received.last?.nowPlaying?.isFavorite, true)
        let beforeQueueChange = try XCTUnwrap(received.last).sequence
        context.player.enqueue(next)
        try await AppModelFixtures.eventually { (received.last?.sequence ?? 0) > beforeQueueChange }

        context.player.onTrackStarted?(song)
        let session = UUID()
        XCTAssertEqual(context.player.onListeningProgress?(song, session, Date().addingTimeInterval(-90), 30), true)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(listens, 1)
        XCTAssertEqual(context.library.events.first?.id, session)
        XCTAssertEqual(context.library.recentlyPlayed.first?.track, song)
        let additional = libraryTestTrack("autoplay-callback")
        await context.catalog.autoplayRadios.enqueue(.success([additional]))
        await context.catalog.autoplayRadios.enqueue(.success([]))   // the thin batch borrows `song`'s radio; nothing more to add
        let exhaust = try XCTUnwrap(context.player.onQueueExhausted)
        let continuation = await exhaust(next)
        XCTAssertEqual(continuation, [additional])
        context.library.clearHistory()
        XCTAssertEqual(clears, 1)
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertTrue(context.library.recentlyPlayed.isEmpty)
        let reloaded = LibraryStore(directory: context.directory)
        XCTAssertEqual(reloaded.favorites, [song])
        XCTAssertEqual(reloaded.playback.queue, [song, next])
        XCTAssertEqual(reloaded.playback.position, 31)
        XCTAssertTrue(zip(received, received.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
        XCTAssertEqual(Set(received.map(\.sessionID)).count, 1)
    }

    func testDisconnectingObserversAndReconnectingDoesNotReplayTransportActions() async throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b"), libraryTestTrack("c")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs))
        let controller = CompanionPlaybackController(model: context.model)
        var firstConnection: [CompanionSnapshot] = []
        let firstID = controller.observe { firstConnection.append($0) }
        let request = CompanionRequest(action: .next, expectedTrackID: songs[0].id)
        let accepted = controller.handle(request)
        XCTAssertTrue(accepted.accepted)
        controller.removeObserver(firstID)
        let countAtDisconnect = firstConnection.count
        context.player.seek(to: 44)
        try await AppModelFixtures.eventually { controller.snapshot.nowPlaying?.position == 44 }
        var reconnected: [CompanionSnapshot] = []
        let secondID = controller.observe { reconnected.append($0) }
        defer { controller.removeObserver(secondID) }
        XCTAssertEqual(reconnected.count, 1)
        XCTAssertEqual(reconnected[0].nowPlaying?.position, 44)
        assertSameReceipt(controller.handle(request), accepted)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.position, 44)
        XCTAssertEqual(firstConnection.count, countAtDisconnect)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        let requests = await context.streams.streams.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testTransportChangesReachTheRealPlayerAndSavedPlayback() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b"), libraryTestTrack("c")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs, currentIndex: 1))
        let controller = CompanionPlaybackController(model: context.model)
        XCTAssertTrue(controller.handle(.init(action: .seek(42.5), expectedTrackID: songs[1].id)).accepted)
        XCTAssertEqual(context.player.position, 42.5)
        XCTAssertTrue(controller.handle(.init(action: .previous)).accepted)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.position, 0)
        XCTAssertTrue(controller.handle(.init(action: .previous)).accepted)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertTrue(controller.handle(.init(action: .next)).accepted)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertTrue(controller.handle(.init(action: .setShuffle(true))).accepted)
        XCTAssertTrue(context.player.shuffleEnabled)
        XCTAssertTrue(controller.handle(.init(action: .setShuffle(false))).accepted)
        XCTAssertEqual(context.player.queue, songs)
        XCTAssertTrue(controller.handle(.init(action: .setRepeatMode(.one))).accepted)
        XCTAssertEqual(context.player.repeatMode, .one)
        XCTAssertTrue(controller.handle(.init(action: .setRepeatMode(.off))).accepted)
        XCTAssertTrue(controller.handle(.init(action: .setRepeatMode(.all))).accepted)
        XCTAssertTrue(controller.handle(.init(action: .pause)).accepted)
        let saved = LibraryStore(directory: context.directory).playback
        XCTAssertEqual(saved.queue, songs)
        XCTAssertEqual(saved.currentIndex, 1)
        XCTAssertEqual(saved.position, 0)
        XCTAssertEqual(saved.repeatMode, .all)
        XCTAssertFalse(saved.shuffleEnabled)
        XCTAssertFalse(context.player.isPlaying)
    }

    func testPlayDuringLoadingIsIdempotentAndPauseRetiresLateResolution() async throws {
        let song = libraryTestTrack()
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song], position: 17))
        let controller = CompanionPlaybackController(model: context.model)
        let request = CompanionRequest(action: .play, expectedTrackID: song.id)
        let first = controller.handle(request)
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(first.snapshot.nowPlaying?.isLoading, true)
        XCTAssertEqual(first.snapshot.nowPlaying?.isPlaying, false)
        let extraction = try await context.streams.streams.request(at: 0)
        XCTAssertTrue(controller.handle(.init(action: .play)).accepted)
        assertSameReceipt(controller.handle(request), first)
        await Task.yield()
        let requests = await context.streams.streams.requests
        let cancellations = await context.streams.streams.cancellations
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(cancellations.isEmpty)
        XCTAssertTrue(context.player.isLoading)
        XCTAssertEqual(context.player.position, 17)
        XCTAssertTrue(controller.handle(.init(action: .pause)).accepted)
        try await context.streams.streams.complete(extraction, with: .failure(MusicServiceError.unavailable("Late failure")))
        await Task.yield()
        XCTAssertFalse(context.player.isLoading)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertNil(context.player.errorMessage)
        XCTAssertNil(controller.snapshot.nowPlaying?.errorMessage)
    }

    func testPlayDuringRealPlaybackDoesNotRestartOrPauseAudio() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 20)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resolver = PlaybackFileResolver(url: url, duration: 20)
        let song = libraryTestTrack(duration: 20)
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song]), resolver: resolver)
        context.model.updatePreferences { $0.autoplay = false; $0.gaplessPlayback = false; $0.automix = false; $0.crossfadeSeconds = 0 }
        let controller = CompanionPlaybackController(model: context.model)
        XCTAssertTrue(controller.handle(.init(action: .play)).accepted)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0 }
        let position = context.player.position
        for _ in 0..<3 { XCTAssertTrue(controller.handle(.init(action: .play)).accepted) }
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertGreaterThanOrEqual(context.player.position, position)
        let resolutions = await resolver.refreshes
        XCTAssertEqual(resolutions.count, 1)
    }

    func testFavoriteAssignmentIsDurableAndDoesNotToggleOnDuplicateOrRepeatedDesiredState() throws {
        let song = libraryTestTrack()
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song]))
        let controller = CompanionPlaybackController(model: context.model)
        let request = CompanionRequest(action: .setFavorite(true), expectedTrackID: song.id)
        let response = controller.handle(request)
        XCTAssertTrue(response.accepted)
        XCTAssertEqual(response.snapshot.nowPlaying?.isFavorite, true)
        XCTAssertEqual(LibraryStore(directory: context.directory).favorites, [song])
        let bytes = try savedBytes(context)
        assertSameReceipt(controller.handle(request), response)
        XCTAssertTrue(controller.handle(.init(action: .setFavorite(true))).accepted)
        XCTAssertEqual(try savedBytes(context), bytes)
        XCTAssertTrue(controller.handle(.init(action: .setFavorite(false))).accepted)
        XCTAssertTrue(LibraryStore(directory: context.directory).favorites.isEmpty)
    }

    func testFailedFavoriteWriteIsRejectedAndOnlyANewRequestRetriesAfterRecovery() throws {
        let song = libraryTestTrack()
        let externalSong = libraryTestTrack("external")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song]))
        let controller = CompanionPlaybackController(model: context.model)
        let external = LibraryStore(directory: context.directory)
        external.toggleFavorite(externalSong)
        let externalBytes = try savedBytes(context)
        let request = CompanionRequest(action: .setFavorite(true))
        let rejected = controller.handle(request)
        XCTAssertFalse(rejected.accepted)
        XCTAssertNotNil(rejected.error)
        XCTAssertEqual(rejected.snapshot.nowPlaying?.isFavorite, false)
        XCTAssertNil(rejected.snapshot.nowPlaying?.errorMessage)
        XCTAssertNotNil(rejected.snapshot.libraryError)
        XCTAssertFalse(context.library.isFavorite(song))
        XCTAssertTrue(context.library.requiresReload)
        XCTAssertFalse(controller.handle(.init(action: .browse("favorites"))).accepted)
        XCTAssertEqual(try savedBytes(context), externalBytes)
        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        assertSameReceipt(controller.handle(request), rejected)
        XCTAssertFalse(context.library.isFavorite(song))
        XCTAssertTrue(controller.handle(.init(action: .setFavorite(true))).accepted)
        XCTAssertEqual(Set(LibraryStore(directory: context.directory).favorites.map(\.id)), [song.id, externalSong.id])
    }

    func testSuperLikePromotesLikingIfNeededDemotesToALikeAndUnlikeRemovesBothDurably() throws {
        let song = libraryTestTrack()
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song]))
        let controller = CompanionPlaybackController(model: context.model)
        XCTAssertEqual(CompanionPlaybackController.Origin.watch.likeSurface, .watch)
        XCTAssertEqual(CompanionPlaybackController.Origin.carPlay.likeSurface, .carPlay)
        XCTAssertEqual(controller.snapshot.nowPlaying?.isFavorite, false)
        XCTAssertEqual(controller.snapshot.nowPlaying?.isSuperLiked, false)

        let promote = CompanionRequest(action: .setSuperLiked(true), expectedTrackID: song.id)
        let promoted = controller.handle(promote, origin: .carPlay)
        XCTAssertTrue(promoted.accepted)
        XCTAssertEqual(promoted.snapshot.nowPlaying?.isFavorite, true, "Promoting an unliked song likes it first")
        XCTAssertEqual(promoted.snapshot.nowPlaying?.isSuperLiked, true)
        XCTAssertTrue(context.library.isSuperLiked(song))
        let saved = LibraryStore(directory: context.directory)
        XCTAssertEqual(saved.favorites, [song])
        XCTAssertTrue(saved.isSuperLiked(song))
        let promotedBytes = try savedBytes(context)
        assertSameReceipt(controller.handle(promote, origin: .watch), promoted)
        XCTAssertTrue(controller.handle(.init(action: .setSuperLiked(true), expectedTrackID: song.id), origin: .watch).accepted)
        XCTAssertEqual(try savedBytes(context), promotedBytes, "A repeated desired tier writes nothing")

        let demoted = controller.handle(.init(action: .setSuperLiked(false), expectedTrackID: song.id), origin: .watch)
        XCTAssertTrue(demoted.accepted)
        XCTAssertEqual(demoted.snapshot.nowPlaying?.isFavorite, true, "Demotion keeps the like")
        XCTAssertEqual(demoted.snapshot.nowPlaying?.isSuperLiked, false)
        XCTAssertTrue(context.library.isFavorite(song))
        XCTAssertFalse(context.library.isSuperLiked(song))
        let demotedStore = LibraryStore(directory: context.directory)
        XCTAssertEqual(demotedStore.favorites, [song])
        XCTAssertTrue(demotedStore.superLikedIDs.isEmpty)

        XCTAssertTrue(controller.handle(.init(action: .setSuperLiked(true), expectedTrackID: song.id), origin: .carPlay).accepted)
        XCTAssertTrue(context.library.isSuperLiked(song))
        let unliked = controller.handle(.init(action: .setFavorite(false), expectedTrackID: song.id), origin: .carPlay)
        XCTAssertTrue(unliked.accepted)
        XCTAssertEqual(unliked.snapshot.nowPlaying?.isFavorite, false, "Unliking removes the like and the super like")
        XCTAssertEqual(unliked.snapshot.nowPlaying?.isSuperLiked, false)
        XCTAssertFalse(context.library.isFavorite(song))
        XCTAssertFalse(context.library.isSuperLiked(song))
        let cleared = LibraryStore(directory: context.directory)
        XCTAssertTrue(cleared.favorites.isEmpty)
        XCTAssertTrue(cleared.superLikedIDs.isEmpty)

        XCTAssertTrue(controller.handle(.init(action: .setFavorite(true), expectedTrackID: song.id)).accepted)
        XCTAssertTrue(controller.handle(.init(action: .setSuperLiked(true), expectedTrackID: song.id)).accepted)
        XCTAssertEqual(context.library.favorites, [song], "Promoting a liked song keeps one favorite entry")
        XCTAssertTrue(context.library.isSuperLiked(song))
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
    }

    func testSuperLikeWithoutACurrentTrackFailsWithNoTrackAndWritesNothing() throws {
        let context = try makeContext()
        let controller = CompanionPlaybackController(model: context.model)
        XCTAssertNil(controller.snapshot.nowPlaying)
        let bytes = try savedBytes(context)
        for action in [CompanionAction.setSuperLiked(true), .setSuperLiked(false), .setFavorite(true)] {
            let response = controller.handle(.init(action: action))
            XCTAssertFalse(response.accepted, "\(action)")
            XCTAssertEqual(response.error, "Choose a song on your iPhone or in the library first.", "\(action)")
            XCTAssertNil(response.snapshot.libraryError, "\(action)")
        }
        XCTAssertTrue(context.library.favorites.isEmpty)
        XCTAssertTrue(context.library.superLikedIDs.isEmpty)
        XCTAssertEqual(try savedBytes(context), bytes)
    }

    func testFailedSuperLikeWriteIsRejectedWithTheLibraryErrorAndRetriesAfterRecovery() throws {
        let song = libraryTestTrack()
        let externalSong = libraryTestTrack("external")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song]))
        let controller = CompanionPlaybackController(model: context.model)
        LibraryStore(directory: context.directory).toggleFavorite(externalSong)
        let externalBytes = try savedBytes(context)
        let request = CompanionRequest(action: .setSuperLiked(true), expectedTrackID: song.id)
        let rejected = controller.handle(request, origin: .carPlay)
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.error, rejected.snapshot.libraryError)
        XCTAssertEqual(rejected.snapshot.nowPlaying?.isFavorite, false)
        XCTAssertEqual(rejected.snapshot.nowPlaying?.isSuperLiked, false)
        XCTAssertNil(rejected.snapshot.nowPlaying?.errorMessage)
        XCTAssertFalse(context.library.isSuperLiked(song))
        XCTAssertTrue(context.library.requiresReload)
        XCTAssertEqual(try savedBytes(context), externalBytes)
        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        assertSameReceipt(controller.handle(request, origin: .carPlay), rejected)
        XCTAssertFalse(context.library.isSuperLiked(song))
        let retried = controller.handle(.init(action: .setSuperLiked(true), expectedTrackID: song.id), origin: .carPlay)
        XCTAssertTrue(retried.accepted)
        XCTAssertNil(retried.snapshot.libraryError)
        XCTAssertEqual(retried.snapshot.nowPlaying?.isSuperLiked, true)
        let saved = LibraryStore(directory: context.directory)
        XCTAssertEqual(Set(saved.favorites.map(\.id)), [song.id, externalSong.id])
        XCTAssertEqual(saved.superLikedIDs, [song.id])
    }

    func testSuperLikeHonoursAFreshLeaseAndRejectsAnExpiredOneWithoutChangingTheTier() throws {
        let song = libraryTestTrack()
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song]))
        var now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let lease = try XCTUnwrap(controller.handle(.init(action: .snapshot)).executionLease)
        now = now.advanced(by: .milliseconds(5_999))
        XCTAssertTrue(controller.handle(.init(action: .setSuperLiked(true), expectedTrackID: song.id, executionLease: lease)).accepted)
        XCTAssertTrue(context.library.isSuperLiked(song))
        let bytes = try savedBytes(context)
        now = now.advanced(by: .milliseconds(1))
        let expired = controller.handle(.init(action: .setSuperLiked(false), expectedTrackID: song.id, executionLease: lease))
        XCTAssertFalse(expired.accepted)
        XCTAssertEqual(expired.error, "This playback request expired. Refresh and try again.")
        XCTAssertTrue(context.library.isSuperLiked(song))
        XCTAssertTrue(context.library.isFavorite(song))
        XCTAssertEqual(try savedBytes(context), bytes)
        let foreign = CompanionExecutionLease(id: UUID(), sessionID: controller.snapshot.sessionID)
        XCTAssertFalse(controller.handle(.init(action: .setSuperLiked(false), expectedTrackID: song.id, executionLease: foreign)).accepted)
        XCTAssertTrue(context.library.isSuperLiked(song))
        XCTAssertEqual(try savedBytes(context), bytes)
    }

    func testCheckpointWriteFailureIsVisibleAlongsideTheActualLivePosition() throws {
        let song = libraryTestTrack()
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song]))
        let controller = CompanionPlaybackController(model: context.model)
        LibraryStore(directory: context.directory).toggleFavorite(libraryTestTrack("external"))
        let externalBytes = try savedBytes(context)
        let response = controller.handle(.init(action: .seek(28)))
        XCTAssertFalse(response.accepted)
        XCTAssertNotNil(response.error)
        XCTAssertNotNil(response.snapshot.libraryError)
        XCTAssertNil(response.snapshot.nowPlaying?.errorMessage)
        XCTAssertEqual(response.snapshot.nowPlaying?.position, 28)
        XCTAssertEqual(context.player.position, 28)
        XCTAssertEqual(context.library.playback.position, 0)
        XCTAssertEqual(try savedBytes(context), externalBytes)
    }

    func testNextAndSeekReceiptsPreventRepeatedMutationAndRejectReusedIDs() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b"), libraryTestTrack("c")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs))
        let controller = CompanionPlaybackController(model: context.model)
        let next = CompanionRequest(action: .next, expectedTrackID: songs[0].id)
        let nextResponse = controller.handle(next)
        XCTAssertTrue(nextResponse.accepted)
        context.player.seek(to: 17)
        assertSameReceipt(controller.handle(next), nextResponse)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.position, 17)
        let seek = CompanionRequest(action: .seek(40), expectedTrackID: songs[1].id)
        let seekResponse = controller.handle(seek)
        context.player.seek(to: 60)
        assertSameReceipt(controller.handle(seek), seekResponse)
        XCTAssertEqual(context.player.position, 60)
        let reused = controller.handle(.init(id: seek.id, action: .next))
        XCTAssertFalse(reused.accepted)
        XCTAssertEqual(context.player.currentIndex, 1)
    }

    func testReceiptWindowRetainsTheMostRecent128RequestIDs() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()]))
        let controller = CompanionPlaybackController(model: context.model)
        let oldest = CompanionRequest(action: .snapshot)
        let retained = CompanionRequest(action: .snapshot)
        let oldResponse = controller.handle(oldest)
        let retainedResponse = controller.handle(retained)
        for _ in 0..<127 { _ = controller.handle(.init(action: .snapshot)) }
        context.player.seek(to: 32)
        assertSameReceipt(controller.handle(retained), retainedResponse)
        let refreshed = controller.handle(oldest)
        XCTAssertGreaterThan(refreshed.snapshot.sequence, oldResponse.snapshot.sequence)
        XCTAssertEqual(refreshed.snapshot.nowPlaying?.position, 32)
    }

    func testReceiptIsInstalledBeforeObserversCanReenterWithTheSameNextRequest() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b"), libraryTestTrack("c")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs))
        let controller = CompanionPlaybackController(model: context.model)
        let request = CompanionRequest(action: .next, expectedTrackID: songs[0].id)
        var replay: CompanionResponse?
        let observation = controller.observe { [weak controller] snapshot in
            if snapshot.nowPlaying?.trackID == songs[1].id, replay == nil { replay = controller?.handle(request) }
        }
        defer { controller.removeObserver(observation) }
        let response = controller.handle(request)
        assertSameReceipt(try XCTUnwrap(replay), response)
        XCTAssertEqual(context.player.currentIndex, 1)
    }

    func testStaleExpectedTrackRejectsAllTrackActionsBeforeMutation() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs, currentIndex: 1, position: 12))
        let controller = CompanionPlaybackController(model: context.model)
        let bytes = try savedBytes(context)
        let actions: [CompanionAction] = [.play, .pause, .next, .previous, .seek(99), .setFavorite(true), .setSuperLiked(true),
                                          .setShuffle(true), .setRepeatMode(.all)]
        for action in actions {
            XCTAssertFalse(controller.handle(.init(action: action, expectedTrackID: songs[0].id)).accepted)
        }
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.position, 12)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertFalse(context.player.shuffleEnabled)
        XCTAssertTrue(context.library.favorites.isEmpty)
        XCTAssertTrue(context.library.superLikedIDs.isEmpty)
        XCTAssertEqual(try savedBytes(context), bytes)
    }

    func testInvalidRequestsAndUnknownItemsHaveNoPlaybackOrPersistenceSideEffects() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()], position: 12))
        let controller = CompanionPlaybackController(model: context.model)
        let queue = try page("queue", on: controller)
        let root = try page("root", on: controller)
        let bytes = try savedBytes(context)
        let requests: [CompanionRequest] = [
            .init(version: 1, action: .next), .init(version: 3, action: .next), .init(version: 1, action: .setSuperLiked(true)),
            .init(action: .play, expectedTrackID: ""),
            .init(action: .play, expectedTrackID: String(repeating: "x", count: 70_000)),
            .init(action: .seek(.nan)), .init(action: .seek(.infinity)), .init(action: .seek(-.infinity)),
            .init(action: .seek(-1)), .init(action: .seek(Double.greatestFiniteMagnitude)),
            .init(action: .browse("")), .init(action: .browse("not-a-page")),
            .init(action: .playItem(location: "queue", itemID: "item:-1", revision: queue.revision)),
            .init(action: .playItem(location: "queue", itemID: "item:1", revision: queue.revision)),
            .init(action: .playItem(location: "queue", itemID: "item:0", revision: "")),
            .init(action: .playItem(location: "root", itemID: "favorites", revision: root.revision)),
        ]
        for request in requests {
            let response = controller.handle(request)
            XCTAssertFalse(response.accepted)
            XCTAssertNotNil(response.error)
        }
        XCTAssertEqual(context.player.position, 12)
        XCTAssertEqual(context.player.queue.count, 1)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertTrue(context.library.superLikedIDs.isEmpty)
        XCTAssertEqual(try savedBytes(context), bytes)
    }

    func testEmptyLibraryHasFoldersButTrackActionsCannotStartPlayback() async throws {
        let context = try makeContext()
        let controller = CompanionPlaybackController(model: context.model)
        XCTAssertNil(controller.snapshot.nowPlaying)
        for action in [CompanionAction.play, .pause, .next, .previous, .seek(0), .setFavorite(true), .setSuperLiked(true)] {
            XCTAssertFalse(controller.handle(.init(action: action)).accepted)
        }
        for location in ["favorites", "recent", "playlists", "queue"] {
            let result = try page(location, on: controller)
            XCTAssertTrue(result.items.isEmpty)
            XCTAssertFalse(result.isTruncated)
        }
        XCTAssertEqual(try page("root", on: controller).items.map(\.destination), ["favorites", "recent", "playlists", "queue"])
        let requests = await context.streams.streams.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBrowseProjectsExistingFavoritesRecentsPlaylistsAndQueueOrder() throws {
        let a = libraryTestTrack("a", artist: "First artist")
        let b = libraryTestTrack("b", artist: "Second artist")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [a, a, b]))
        context.library.toggleFavorite(a)
        context.library.toggleFavorite(b)
        context.library.recordRecent(track: a, position: 5)
        context.library.recordRecent(track: b, position: 9)
        let playlist = context.library.createPlaylist(name: "Night drive")
        context.library.add(a, to: playlist)
        context.library.add(b, to: playlist)
        context.library.moveTracks(in: playlist, from: IndexSet(integer: 1), to: 0)
        let controller = CompanionPlaybackController(model: context.model)
        let root = try page("root", on: controller)
        XCTAssertEqual(root.items.map(\.title), ["Favorites", "Recently played", "Playlists", "Queue"])
        for location in ["favorites", "recent", "playlist:\(playlist.uuidString)"] {
            let result = try page(location, on: controller)
            XCTAssertEqual(result.items.map(\.title), [b.title, a.title])
            XCTAssertEqual(result.items.map(\.subtitle), [b.artistName, a.artistName])
            XCTAssertTrue(result.items.allSatisfy { $0.destination == nil })
        }
        let playlists = try page("playlists", on: controller)
        XCTAssertEqual(playlists.items[0].title, "Night drive")
        XCTAssertEqual(playlists.items[0].subtitle, "2 songs")
        XCTAssertEqual(playlists.items[0].destination, "playlist:\(playlist.uuidString)")
        let queue = try page("queue", on: controller)
        XCTAssertEqual(queue.items.map(\.title), [a.title, a.title, b.title])
        XCTAssertEqual(Set(queue.items.map(\.id)).count, 3)
    }

    func testPageLimitIsTruthfulAndSelectionsCannotAddressOmittedRows() throws {
        let songs = (0..<41).map { libraryTestTrack("song-\($0)") }
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs))
        let controller = CompanionPlaybackController(model: context.model)
        let truncated = try page("queue", on: controller)
        XCTAssertEqual(truncated.items.count, 40)
        XCTAssertTrue(truncated.isTruncated)
        XCTAssertFalse(controller.handle(.init(action: .playItem(location: "queue", itemID: "item:40", revision: truncated.revision))).accepted)
        context.player.removeFromQueue(at: 40)
        let complete = try page("queue", on: controller)
        XCTAssertEqual(complete.items.count, 40)
        XCTAssertFalse(complete.isTruncated)
        XCTAssertNotEqual(complete.revision, truncated.revision)
        XCTAssertLessThanOrEqual(try CompanionWire.encode(complete).count, CompanionWire.maximumMessageBytes)
    }

    func testPageRevisionIncludesUnshownTailOrderButNotPlaybackPosition() throws {
        let songs = (0..<42).map { libraryTestTrack("song-\($0)") }
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs))
        let controller = CompanionPlaybackController(model: context.model)
        let original = try page("queue", on: controller)
        context.player.seek(to: 5)
        XCTAssertEqual(try page("queue", on: controller).revision, original.revision)
        context.player.moveQueue(from: IndexSet(integer: 41), to: 40)
        let changed = try page("queue", on: controller)
        XCTAssertEqual(changed.items, original.items)
        XCTAssertNotEqual(changed.revision, original.revision)
        let stale = controller.handle(.init(action: .playItem(location: "queue", itemID: original.items[0].id, revision: original.revision)))
        XCTAssertFalse(stale.accepted)
        XCTAssertEqual(context.player.position, 5)
        XCTAssertFalse(context.player.isLoading)
    }

    func testPageRevisionIncludesMetadataBeyondTheTruncatedDisplayText() throws {
        var song = libraryTestTrack()
        song.title = String(repeating: "Long title ", count: 100) + "first"
        let context = try makeContext()
        context.library.toggleFavorite(song)
        let controller = CompanionPlaybackController(model: context.model)
        let original = try page("favorites", on: controller)
        context.library.toggleFavorite(song)
        song.title = String(repeating: "Long title ", count: 100) + "second"
        context.library.toggleFavorite(song)
        let changed = try page("favorites", on: controller)
        XCTAssertEqual(changed.items, original.items)
        XCTAssertNotEqual(changed.revision, original.revision)
        XCTAssertFalse(controller.handle(.init(action: .playItem(location: "favorites", itemID: original.items[0].id,
                                                                revision: original.revision))).accepted)
        XCTAssertNil(context.player.currentTrack)
    }

    func testDuplicateQueueRowsSelectTheExactOccurrenceAndRejectShiftedIndices() throws {
        let a = libraryTestTrack("a")
        let b = libraryTestTrack("b")
        var duplicate = a
        duplicate.title = "Second occurrence metadata"
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [a, b, duplicate]))
        let controller = CompanionPlaybackController(model: context.model)
        let original = try page("queue", on: controller)
        XCTAssertNotEqual(original.items[0].id, original.items[2].id)
        let selected = controller.handle(.init(action: .playItem(location: "queue", itemID: original.items[2].id,
                                                                revision: original.revision)))
        XCTAssertTrue(selected.accepted)
        XCTAssertEqual(context.player.currentIndex, 2)
        XCTAssertEqual(context.player.currentTrack, duplicate)
        XCTAssertEqual(context.library.playback.currentIndex, 2)
        context.player.pause()
        context.player.removeFromQueue(at: 0)
        XCTAssertFalse(controller.handle(.init(action: .playItem(location: "queue", itemID: original.items[2].id,
                                                                revision: original.revision))).accepted)
        XCTAssertEqual(context.player.currentTrack, duplicate)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertFalse(context.player.isLoading)
    }

    func testRemovedFavoritesAndDeletedPlaylistsCannotPlayFromAnOldPage() throws {
        let song = libraryTestTrack()
        let context = try makeContext()
        context.library.toggleFavorite(song)
        let playlist = context.library.createPlaylist(name: "Temporary")
        context.library.add(song, to: playlist)
        let controller = CompanionPlaybackController(model: context.model)
        let favorites = try page("favorites", on: controller)
        let savedPlaylist = try page("playlist:\(playlist.uuidString)", on: controller)
        context.library.toggleFavorite(song)
        context.library.deletePlaylist(id: playlist)
        for old in [favorites, savedPlaylist] {
            XCTAssertFalse(controller.handle(.init(action: .playItem(location: old.location, itemID: old.items[0].id,
                                                                    revision: old.revision))).accepted)
        }
        XCTAssertNil(context.player.currentTrack)
        XCTAssertTrue(context.player.queue.isEmpty)
    }

    func testAControllerSessionRejectsPagesFromAPreviousRuntime() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()]))
        let first = CompanionPlaybackController(model: context.model)
        let old = try page("queue", on: first)
        let second = CompanionPlaybackController(model: context.model)
        XCTAssertNotEqual(first.snapshot.sessionID, second.snapshot.sessionID)
        XCTAssertFalse(second.handle(.init(action: .playItem(location: "queue", itemID: old.items[0].id, revision: old.revision))).accepted)
        XCTAssertFalse(context.player.isLoading)
    }

    func testFavoriteSelectionCancelsPendingRadioBeforeLateStartupResultsArrive() async throws {
        let context = try makeContext()
        let f = ExperienceRadioFixtures.self
        let pending = context.model.startRadio(f.melancholy)
        try await f.answerSearches(context, from: 0, with: f.melancholySearches)
        _ = try await context.catalog.autoplayRadios.request(at: 1)
        let explicit = libraryTestTrack("explicit")
        context.library.toggleFavorite(explicit)
        let controller = CompanionPlaybackController(model: context.model)
        let favorites = try page("favorites", on: controller)
        XCTAssertTrue(controller.handle(.init(action: .playItem(location: favorites.location, itemID: favorites.items[0].id,
                                                               revision: favorites.revision))).accepted)
        XCTAssertFalse(context.model.isLoadingRadio)
        try await f.answerRadios(context, from: 0, with: f.melancholyRadios)
        await pending.value
        XCTAssertEqual(context.player.queue, [explicit])
        XCTAssertFalse(context.player.isRadioSession)
        XCTAssertNil(context.model.activeRadioExperience)
        XCTAssertNil(context.model.radioError)
    }

    func testQueueSelectionPreservesActiveRadioAndCancelsANewerPendingStation() async throws {
        let context = try makeContext(languages: [.hindi, .english])
        try await startRadio(in: context)
        let f = ExperienceRadioFixtures.self
        let controller = CompanionPlaybackController(model: context.model)
        let queue = try page("queue", on: controller)
        let tracks = context.player.queue
        let wording = Set(f.gym.selection(for: context.model.listeningLanguageProfile).styleQueries)
        let pending = context.model.startRadio(f.gym)
        _ = try await context.catalog.searches.request(at: 4)
        XCTAssertTrue(controller.handle(.init(action: .playItem(location: "queue", itemID: queue.items[1].id, revision: queue.revision))).accepted)
        try await f.answerStyleSearches(context, from: 2, count: 3, songs: [f.zinda, f.goat, f.sultan, f.punjabi], expecting: wording)
        await pending.value
        XCTAssertEqual(context.player.queue, tracks)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertTrue(context.player.isRadioSession)
        XCTAssertEqual(context.model.activeRadioExperience, f.melancholy)
        XCTAssertEqual(context.model.selectedRadioExperience, f.melancholy)
        XCTAssertFalse(context.model.isLoadingRadio)
        XCTAssertNil(context.model.radioError)
        let searches = await context.catalog.searches.requests
        let radios = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(searches.count, 5)
        XCTAssertEqual(radios.count, 2, "Late style results cannot start the superseded station")
        try await AppModelFixtures.eventually { await context.catalog.searches.cancellations.isSuperset(of: [2, 3, 4]) }
    }

    func testLibrarySelectionRetiresAnOldRadioContinuationGeneration() async throws {
        let context = try makeContext()
        try await startRadio(in: context)
        let f = ExperienceRadioFixtures.self
        let callback = try XCTUnwrap(context.player.onQueueExhausted)
        let continuation = Task { await callback(f.alt) }
        defer { continuation.cancel() }
        _ = try await context.catalog.autoplayRadios.request(at: 3)
        let explicit = libraryTestTrack("explicit")
        let playlistID = context.library.createPlaylist(name: "Explicit playlist")
        context.library.add(explicit, to: playlistID)
        let controller = CompanionPlaybackController(model: context.model)
        let playlist = try page("playlist:\(playlistID.uuidString)", on: controller)
        XCTAssertTrue(controller.handle(.init(action: .playItem(location: playlist.location, itemID: playlist.items[0].id,
                                                               revision: playlist.revision))).accepted)
        let late = RecommendationFixtures.track("late-neighbor")
        try await f.answerRadios(context, from: 2, with: [f.cas.id: [late], f.alt.id: [late]])
        let additions = await continuation.value
        XCTAssertTrue(additions.isEmpty)
        XCTAssertEqual(context.player.queue, [explicit])
        XCTAssertFalse(context.player.isRadioSession)
        XCTAssertFalse(context.model.isContinuingRadio)
        XCTAssertNil(context.model.radioContinuationError)
    }

    func testSelectionAcceptancePrecedesAudioAndLateResolutionCannotOverwriteTheNewTrackError() async throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs))
        let controller = CompanionPlaybackController(model: context.model)
        let queue = try page("queue", on: controller)
        let firstResponse = controller.handle(.init(action: .playItem(location: "queue", itemID: queue.items[0].id, revision: queue.revision)))
        XCTAssertTrue(firstResponse.accepted)
        XCTAssertEqual(firstResponse.snapshot.nowPlaying?.isLoading, true)
        XCTAssertEqual(firstResponse.snapshot.nowPlaying?.isPlaying, false)
        let first = try await context.streams.streams.request(at: 0)
        let secondResponse = controller.handle(.init(action: .playItem(location: "queue", itemID: queue.items[1].id, revision: queue.revision)))
        XCTAssertTrue(secondResponse.accepted)
        let second = try await context.streams.streams.request(at: 1)
        try await context.streams.streams.complete(second, with: .failure(MusicServiceError.unavailable("Current failure")))
        try await AppModelFixtures.eventually { controller.snapshot.nowPlaying?.errorMessage != nil }
        let displayedError = controller.snapshot.nowPlaying?.errorMessage
        XCTAssertEqual(context.player.errorMessage, "Current failure")
        try await AppModelFixtures.eventually { await context.streams.streams.cancellations.contains(first.id) }
        try await context.streams.streams.complete(first, with: .failure(MusicServiceError.unavailable("Obsolete failure")))
        await Task.yield()
        XCTAssertEqual(context.player.currentTrack, songs[1])
        XCTAssertEqual(controller.snapshot.nowPlaying?.trackID, songs[1].id)
        XCTAssertEqual(context.player.errorMessage, "Current failure")
        XCTAssertEqual(controller.snapshot.nowPlaying?.errorMessage, displayedError)
        XCTAssertEqual(controller.snapshot.nowPlaying?.isLoading, false)
        XCTAssertEqual(controller.snapshot.nowPlaying?.isPlaying, false)
    }

    func testTransportProjectionOmitsMediaURLsCookiesAndPrivateErrorDetails() async throws {
        let secret = "private-test-credential"
        var song = libraryTestTrack()
        song.artworkURL = URL(string: "file:///private/companion-fixture/art?token=\(secret)")
        song.albumID = "album-private-field"
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song]))
        let controller = CompanionPlaybackController(model: context.model)
        XCTAssertTrue(controller.handle(.init(action: .play)).accepted)
        let request = try await context.streams.streams.request(at: 0)
        try await context.streams.streams.complete(request, with: .failure(MusicServiceError.unavailable(
            "https://audio.googlevideo.com/stream?signature=\(secret) Cookie: SAPISID=\(secret)")))
        try await AppModelFixtures.eventually { controller.snapshot.nowPlaying?.errorMessage != nil }
        let response = controller.handle(.init(action: .browse("queue")))
        let json = String(decoding: try CompanionWire.encode(response), as: UTF8.self)
        for privateValue in [secret, "googlevideo", "artworkURL", "album-private-field", "currentStreamURL", "Cookie", "SAPISID"] {
            XCTAssertFalse(json.contains(privateValue), privateValue)
        }
        XCTAssertEqual(response.snapshot.nowPlaying?.title, song.title)
        XCTAssertEqual(response.snapshot.nowPlaying?.artist, song.artistName)
        XCTAssertNotNil(response.snapshot.nowPlaying?.errorMessage)
        XCTAssertEqual(response.snapshot.nowPlaying?.isLoading, false)
    }

    func testSnapshotPositionIsClampedWithoutRewritingRestoredResumeState() throws {
        let song = libraryTestTrack(duration: 100)
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song], position: 130))
        let controller = CompanionPlaybackController(model: context.model)
        XCTAssertEqual(controller.snapshot.nowPlaying?.position, 100)
        XCTAssertEqual(controller.snapshot.nowPlaying?.duration, 100)
        XCTAssertEqual(context.player.position, 130)
        XCTAssertEqual(context.library.playback.position, 130)
    }

    func testObservationRegistrationDoesNotRetainAnUnusedController() async throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()]))
        var controller: CompanionPlaybackController? = CompanionPlaybackController(model: context.model)
        weak var released = controller
        _ = controller?.observe { _ in }
        controller = nil
        XCTAssertNil(released)
        context.player.seek(to: 20)
        await Task.yield()
        XCTAssertEqual(context.library.playback.position, 20)
    }

    func testExecutionLeaseAcceptsOnlyItsSixSecondMonotonicWindow() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()]))
        let issuedAt = ContinuousClock.now
        var now = issuedAt
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let preflight = controller.handle(.init(action: .snapshot))
        let lease = try XCTUnwrap(preflight.executionLease)
        XCTAssertEqual(lease.sessionID, controller.snapshot.sessionID)

        now = issuedAt.advanced(by: .milliseconds(5_999))
        XCTAssertTrue(controller.handle(.init(action: .seek(42), executionLease: lease)).accepted)
        XCTAssertEqual(context.player.position, 42)
        let bytes = try savedBytes(context)
        now = issuedAt.advanced(by: .seconds(6))
        let expired = controller.handle(.init(action: .seek(99), executionLease: lease))
        XCTAssertFalse(expired.accepted)
        XCTAssertNotNil(expired.error)
        XCTAssertEqual(context.player.position, 42)
        XCTAssertEqual(try savedBytes(context), bytes)

        now = issuedAt.advanced(by: .seconds(-1))
        XCTAssertFalse(controller.handle(.init(action: .seek(99), executionLease: lease)).accepted)
        XCTAssertEqual(context.player.position, 42)
        XCTAssertEqual(try savedBytes(context), bytes)
    }

    func testDelayedFirstDeliveryAfterClientTimeoutCannotMutate() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs, position: 17))
        var now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let preflight = controller.handle(.init(action: .snapshot))
        let command = CompanionRequest(action: .next, expectedTrackID: songs[0].id,
                                       executionLease: try XCTUnwrap(preflight.executionLease))
        let bytes = try savedBytes(context)
        now = now.advanced(by: .milliseconds(8_001))
        let response = controller.handle(command)
        XCTAssertFalse(response.accepted)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.position, 17)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertEqual(try savedBytes(context), bytes)
    }

    func testExpiredLeaseRejectsEveryMutatingActionBeforeAnyStateChange() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs, position: 17))
        var now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let browse = controller.handle(.init(action: .browse("queue")))
        let queue = try XCTUnwrap(browse.page)
        let lease = try XCTUnwrap(browse.executionLease)
        now = now.advanced(by: .seconds(6))
        let bytes = try savedBytes(context)
        let snapshot = controller.snapshot
        let actions: [CompanionAction] = [
            .play, .pause, .next, .previous, .seek(99), .setFavorite(true), .setSuperLiked(true), .setShuffle(true),
            .setRepeatMode(.one), .playItem(location: "queue", itemID: queue.items[1].id, revision: queue.revision),
        ]
        for action in actions {
            let response = controller.handle(.init(action: action, expectedTrackID: songs[0].id, executionLease: lease))
            XCTAssertFalse(response.accepted)
            XCTAssertNotNil(response.error)
            XCTAssertNotNil(response.executionLease)
            XCTAssertEqual(response.snapshot, snapshot)
            XCTAssertEqual(try savedBytes(context), bytes)
        }
        XCTAssertEqual(context.player.queue, songs)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.position, 17)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertFalse(context.player.shuffleEnabled)
        XCTAssertEqual(context.player.repeatMode, .off)
        XCTAssertTrue(context.library.favorites.isEmpty)
        XCTAssertTrue(context.library.superLikedIDs.isEmpty)
    }

    func testUnknownWrongSessionAndForeignControllerLeasesCannotMutate() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs))
        let now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let issued = try XCTUnwrap(controller.handle(.init(action: .snapshot)).executionLease)
        let other = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let foreign = try XCTUnwrap(other.handle(.init(action: .snapshot)).executionLease)
        let bytes = try savedBytes(context)
        let invalid = [
            CompanionExecutionLease(id: UUID(), sessionID: issued.sessionID),
            CompanionExecutionLease(id: issued.id, sessionID: UUID()),
            foreign,
        ]
        for lease in invalid {
            XCTAssertFalse(controller.handle(.init(action: .next, executionLease: lease)).accepted)
            XCTAssertEqual(context.player.currentIndex, 0)
            XCTAssertEqual(try savedBytes(context), bytes)
        }
        XCTAssertTrue(controller.handle(.init(action: .next, executionLease: issued)).accepted)
        XCTAssertEqual(context.player.currentIndex, 1)
    }

    func testExecutionLeaseIsRecheckedAfterPageValidationBeforeSelection() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack("a"), libraryTestTrack("b")]))
        let issuedAt = ContinuousClock.now
        let expiredAt = issuedAt.advanced(by: .seconds(6))
        var readings = [issuedAt]
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: {
            readings.isEmpty ? expiredAt : readings.removeFirst()
        })
        let browse = controller.handle(.init(action: .browse("queue")))
        let queue = try XCTUnwrap(browse.page)
        let lease = try XCTUnwrap(browse.executionLease)
        let bytes = try savedBytes(context)
        readings = [issuedAt, expiredAt]
        let response = controller.handle(.init(action: .playItem(location: "queue", itemID: queue.items[1].id,
                                                                revision: queue.revision), executionLease: lease))
        XCTAssertFalse(response.accepted)
        XCTAssertTrue(readings.isEmpty)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertEqual(try savedBytes(context), bytes)
    }

    func testExecutionLeaseWindowRetainsOnly128IssuedLeases() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()]))
        let now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let leases = try (0..<129).map { _ in
            try XCTUnwrap(controller.handle(.init(action: .snapshot)).executionLease)
        }
        XCTAssertEqual(Set(leases.map(\.id)).count, 129)
        XCTAssertTrue(controller.handle(.init(action: .seek(17), executionLease: leases[1])).accepted)
        XCTAssertFalse(controller.handle(.init(action: .seek(99), executionLease: leases[0])).accepted)
        XCTAssertEqual(context.player.position, 17)
    }

    func testReplayedCommandKeepsItsReceiptAcrossExpiredAndRenewedLeases() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b"), libraryTestTrack("c")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs))
        var now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let lease = try XCTUnwrap(controller.handle(.init(action: .snapshot)).executionLease)
        let request = CompanionRequest(action: .next, expectedTrackID: songs[0].id, executionLease: lease)
        let accepted = controller.handle(request)
        XCTAssertTrue(accepted.accepted)
        context.player.seek(to: 17)
        assertSameReceipt(controller.handle(request), accepted)
        now = now.advanced(by: .seconds(9))
        assertSameReceipt(controller.handle(request), accepted)

        let renewal = controller.handle(.init(action: .snapshot))
        let newLease = try XCTUnwrap(renewal.executionLease)
        let renewedRequest = CompanionRequest(id: request.id, action: request.action, expectedTrackID: request.expectedTrackID,
                                              executionLease: newLease)
        assertSameReceipt(controller.handle(renewedRequest), accepted)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.position, 17)
        XCTAssertFalse(controller.handle(.init(id: request.id, action: .seek(99), executionLease: newLease)).accepted)
        XCTAssertEqual(context.player.position, 17)

        let seek = CompanionRequest(action: .seek(42), executionLease: newLease)
        let seekReceipt = controller.handle(seek)
        XCTAssertTrue(seekReceipt.accepted)
        context.player.seek(to: 55)
        let anotherLease = try XCTUnwrap(seekReceipt.executionLease)
        assertSameReceipt(controller.handle(.init(id: seek.id, action: seek.action, executionLease: anotherLease)), seekReceipt)
        XCTAssertEqual(context.player.position, 55)
    }

    func testRejectedExpiredCommandCannotBecomeAMutationWithANewLease() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs))
        var now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let lease = try XCTUnwrap(controller.handle(.init(action: .snapshot)).executionLease)
        let request = CompanionRequest(action: .next, executionLease: lease)
        now = now.advanced(by: .seconds(6))
        let rejected = controller.handle(request)
        XCTAssertFalse(rejected.accepted)
        let freshLease = try XCTUnwrap(controller.handle(.init(action: .snapshot)).executionLease)
        assertSameReceipt(controller.handle(.init(id: request.id, action: .next, executionLease: freshLease)), rejected)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertTrue(controller.handle(.init(action: .next, executionLease: freshLease)).accepted)
        XCTAssertEqual(context.player.currentIndex, 1)
    }

    func testReadOnlyPreflightAndLocalCommandsRemainAvailableWithoutAValidLease() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b")]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: songs))
        var now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let request = CompanionRequest(action: .snapshot)
        let first = controller.handle(request)
        let expiredLease = try XCTUnwrap(first.executionLease)
        now = now.advanced(by: .seconds(9))
        let replayedPreflight = controller.handle(request)
        assertSameReceipt(replayedPreflight, first)
        let renewed = controller.handle(.init(action: .snapshot, executionLease: expiredLease))
        XCTAssertTrue(renewed.accepted)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertTrue(controller.handle(.init(action: .seek(12), executionLease: try XCTUnwrap(replayedPreflight.executionLease))).accepted)
        XCTAssertTrue(controller.handle(.init(action: .next)).accepted)
        XCTAssertEqual(context.player.currentIndex, 1)
    }

    func testLeasedRepeatChangeRejectsNewerPhoneRepeatSelection() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()]))
        let now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let preflight = controller.handle(.init(action: .snapshot))
        XCTAssertEqual(preflight.snapshot.nowPlaying?.repeatMode, .off)
        let lease = try XCTUnwrap(preflight.executionLease)
        XCTAssertTrue(controller.handle(.init(action: .setRepeatMode(.one))).accepted)
        let bytes = try savedBytes(context)

        let request = CompanionRequest(action: .setRepeatMode(.all), executionLease: lease)
        let rejected = controller.handle(request)
        XCTAssertFalse(rejected.accepted)
        XCTAssertNotNil(rejected.error)
        XCTAssertEqual(rejected.snapshot.nowPlaying?.repeatMode, .one)
        XCTAssertEqual(context.player.repeatMode, .one)
        XCTAssertEqual(context.library.playback.repeatMode, .one)
        XCTAssertEqual(try savedBytes(context), bytes)

        let freshLease = try XCTUnwrap(rejected.executionLease)
        assertSameReceipt(controller.handle(.init(id: request.id, action: request.action, executionLease: freshLease)), rejected)
        XCTAssertEqual(context.player.repeatMode, .one)
        XCTAssertTrue(controller.handle(.init(action: .setRepeatMode(.all), executionLease: freshLease)).accepted)
        XCTAssertEqual(context.player.repeatMode, .all)
        XCTAssertEqual(context.library.playback.repeatMode, .all)
    }

    func testLeasedRepeatNoOpIsIdempotentButStillRequiresUnexpiredLease() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()]))
        var now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let lease = try XCTUnwrap(controller.handle(.init(action: .snapshot)).executionLease)
        XCTAssertTrue(controller.handle(.init(action: .setRepeatMode(.all))).accepted)
        let bytes = try savedBytes(context)
        XCTAssertTrue(controller.handle(.init(action: .setRepeatMode(.all), executionLease: lease)).accepted)
        XCTAssertEqual(try savedBytes(context), bytes)
        now = now.advanced(by: .seconds(6))
        XCTAssertFalse(controller.handle(.init(action: .setRepeatMode(.all), executionLease: lease)).accepted)
        XCTAssertEqual(context.player.repeatMode, .all)
        XCTAssertEqual(try savedBytes(context), bytes)
    }

    func testLeasedRepeatReceiptReplayPreservesNewerPhoneMode() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()]))
        let now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let lease = try XCTUnwrap(controller.handle(.init(action: .snapshot)).executionLease)
        let request = CompanionRequest(action: .setRepeatMode(.all), executionLease: lease)
        let accepted = controller.handle(request)
        XCTAssertTrue(accepted.accepted)
        XCTAssertTrue(controller.handle(.init(action: .setRepeatMode(.one))).accepted)
        let bytes = try savedBytes(context)
        assertSameReceipt(controller.handle(request), accepted)
        let renewal = try XCTUnwrap(controller.handle(.init(action: .snapshot)).executionLease)
        assertSameReceipt(controller.handle(.init(id: request.id, action: request.action, executionLease: renewal)), accepted)
        XCTAssertEqual(context.player.repeatMode, .one)
        XCTAssertEqual(try savedBytes(context), bytes)
    }

    func testRepeatLeaseFromCachedSnapshotCannotOverwriteNewerPhoneMode() throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()]))
        let now = ContinuousClock.now
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { now })
        let preflight = CompanionRequest(action: .snapshot)
        _ = controller.handle(preflight)
        XCTAssertTrue(controller.handle(.init(action: .setRepeatMode(.one))).accepted)
        let cached = controller.handle(preflight)
        XCTAssertEqual(cached.snapshot.nowPlaying?.repeatMode, .off)
        XCTAssertFalse(controller.handle(.init(action: .setRepeatMode(.all), executionLease: try XCTUnwrap(cached.executionLease))).accepted)
        XCTAssertEqual(context.player.repeatMode, .one)
        XCTAssertEqual(context.library.playback.repeatMode, .one)
    }

    func testFailedLibraryWriteWhileAudioIsActiveDoesNotBecomeAPlaybackError() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 20)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resolver = PlaybackFileResolver(url: url, duration: 20)
        let song = libraryTestTrack(duration: 20)
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song]), resolver: resolver)
        context.model.updatePreferences { $0.autoplay = false; $0.gaplessPlayback = false; $0.automix = false; $0.crossfadeSeconds = 0 }
        let controller = CompanionPlaybackController(model: context.model)
        XCTAssertTrue(controller.handle(.init(action: .play)).accepted)
        try await PlaybackTestSupport.waitUntil { controller.snapshot.nowPlaying?.isPlaying == true }

        let playing = controller.snapshot
        XCTAssertNil(playing.libraryError)
        LibraryStore(directory: context.directory).toggleFavorite(libraryTestTrack("external-library-change"))
        let response = controller.handle(.init(action: .setFavorite(true), expectedTrackID: song.id))
        XCTAssertFalse(response.accepted)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.snapshot.libraryError, response.error)
        XCTAssertEqual(response.snapshot.nowPlaying, playing.nowPlaying)
        XCTAssertEqual(response.snapshot.nowPlaying?.isPlaying, true)
        XCTAssertNil(response.snapshot.nowPlaying?.errorMessage)
        XCTAssertGreaterThan(response.snapshot.sequence, playing.sequence)
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertNil(context.player.errorMessage)

        let position = context.player.position
        try await PlaybackTestSupport.waitUntil { context.player.position > position + 0.5 }
        XCTAssertEqual(controller.snapshot.nowPlaying?.isPlaying, true)
        XCTAssertNil(controller.snapshot.nowPlaying?.errorMessage)
        XCTAssertNotNil(controller.snapshot.libraryError)
    }

    func testLibraryErrorObservesFailureAndRecoveryWithoutANowPlayingTrack() async throws {
        let context = try makeContext()
        let controller = CompanionPlaybackController(model: context.model)
        var received: [CompanionSnapshot] = []
        let observation = controller.observe { received.append($0) }
        defer { controller.removeObserver(observation) }
        let initial = controller.snapshot
        LibraryStore(directory: context.directory).toggleFavorite(libraryTestTrack("external-library-change"))
        context.library.toggleFavorite(libraryTestTrack("rejected-change"))
        try await AppModelFixtures.eventually { received.last?.libraryError != nil }
        XCTAssertNil(controller.snapshot.nowPlaying)
        XCTAssertGreaterThan(controller.snapshot.sequence, initial.sequence)
        let failedSequence = controller.snapshot.sequence
        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        try await AppModelFixtures.eventually { received.last?.libraryError == nil }
        XCTAssertNil(controller.snapshot.nowPlaying)
        XCTAssertGreaterThan(controller.snapshot.sequence, failedSequence)
    }

    private func assertSameReceipt(_ response: CompanionResponse, _ original: CompanionResponse,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.id, original.id, file: file, line: line)
        XCTAssertEqual(response.accepted, original.accepted, file: file, line: line)
        XCTAssertEqual(response.snapshot, original.snapshot, file: file, line: line)
        XCTAssertEqual(response.page, original.page, file: file, line: line)
        XCTAssertEqual(response.error, original.error, file: file, line: line)
        XCTAssertNotNil(response.executionLease, file: file, line: line)
        XCTAssertEqual(response.executionLease?.sessionID, response.snapshot.sessionID, file: file, line: line)
        XCTAssertNotEqual(response.executionLease?.id, original.executionLease?.id, file: file, line: line)
    }

    func testEveryAppAccentProjectsToTheSameCompanionRawValue() {
        XCTAssertEqual(AppAccent.allCases.map(\.companionAccent), CompanionAccent.allCases)
        for accent in AppAccent.allCases { XCTAssertEqual(accent.companionAccent.rawValue, accent.rawValue) }
    }

    func testAccentPreferenceChangePublishesANewSnapshotWithoutOtherPreferenceChurn() async throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [libraryTestTrack()]))
        let controller = CompanionPlaybackController(model: context.model)
        var received: [CompanionSnapshot] = []
        let observation = controller.observe { received.append($0) }
        defer { controller.removeObserver(observation) }
        XCTAssertEqual(received.last?.accent, context.library.preferences.accent.companionAccent)
        let target: AppAccent = context.library.preferences.accent == .ocean ? .amber : .ocean
        context.model.updatePreferences { $0.accent = target }
        try await AppModelFixtures.eventually { received.last?.accent == target.companionAccent }
        let sequence = try XCTUnwrap(received.last).sequence
        XCTAssertEqual(controller.handle(.init(action: .snapshot)).snapshot.accent, target.companionAccent)

        context.model.updatePreferences { $0.autoplay.toggle() }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(received.last?.sequence, sequence, "Unrelated preferences do not produce a companion snapshot")
    }

    private func makeContext(languages: Set<MusicLanguage> = [.english], snapshot: PlaybackSnapshot = PlaybackSnapshot(),
                             resolver: (any StreamResolving)? = nil) throws -> AppModelTestContext {
        let context = try AppModelTestContext(languages: languages, snapshot: snapshot, resolver: resolver)
        addTeardownBlock { @MainActor in
            context.model.cancelPendingRadio()
            try await context.close()
        }
        return context
    }

    private func page(_ location: String, on controller: CompanionPlaybackController) throws -> CompanionPage {
        let response = controller.handle(.init(action: .browse(location)))
        XCTAssertTrue(response.accepted, response.error ?? "Browse was rejected")
        return try XCTUnwrap(response.page)
    }

    private func savedBytes(_ context: AppModelTestContext) throws -> Data {
        try Data(contentsOf: context.directory.appendingPathComponent(LibraryPersistence.fileName))
    }

    private func startRadio(in context: AppModelTestContext) async throws {
        let f = ExperienceRadioFixtures.self
        let task = context.model.startRadio(f.melancholy)
        try await f.answerSearches(context, from: 0, with: f.melancholySearches)
        try await f.answerRadios(context, from: 0, with: f.melancholyRadios)
        await task.value
        XCTAssertTrue(context.player.isRadioSession)
    }
}
