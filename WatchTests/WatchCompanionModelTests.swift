import XCTest
@testable import GanaBajanaWatch

@MainActor
final class WatchCompanionModelTests: XCTestCase {
    func testDisconnectedCachedPlaybackHasNoLiveControlsOrAdvancingClock() throws {
        let transport = WatchTestTransport()
        transport.state = .ready(reachable: false, installed: true, needsUnlock: false)
        var uptime: TimeInterval = 100
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport), uptime: { uptime })
        model.setForeground(true)
        transport.onEvent?(.applicationContext(try CompanionWire.encode(WatchTestSupport.snapshot())))
        uptime = 120
        XCTAssertNotNil(model.nowPlaying)
        XCTAssertFalse(model.canControl)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.position, 42)
        XCTAssertTrue(transport.messages.isEmpty)
        model.setForeground(false)
    }

    func testForegroundRefreshesReadOnlyAndRestoredPausedSnapshotStaysPaused() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { WatchTestSupport.response(for: $0, snapshot: WatchTestSupport.snapshot(playing: false)) }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot])
        model.setForeground(false)
        XCTAssertFalse(model.canControl)
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { transport.messages.count == 2 && model.isCurrent }
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot, .snapshot])
        XCTAssertFalse(model.isPlaying)
        model.setForeground(false)
    }

    func testPlayWaitsForAcknowledgementAndUsesDisplayedTrackGuard() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { request in
            request.action == .snapshot ? WatchTestSupport.response(for: request, snapshot: WatchTestSupport.snapshot(playing: false)) : nil
        }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        let play = Task { await model.command(.play, displayed: displayed) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 3 }
        XCTAssertFalse(model.isPlaying)
        XCTAssertNotNil(model.pendingCommand)
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(transport.requests[2].expectedTrackID, "watch-test-track")
        XCTAssertNotNil(transport.requests[2].executionLease)
        try transport.reply(at: 2, snapshot: WatchTestSupport.snapshot(sequence: 2, playing: true))
        let accepted = await play.value
        XCTAssertTrue(accepted)
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(model.pendingCommand)
        model.setForeground(false)
    }

    func testSuperLikeCommandWaitsForAcknowledgementAndShowsThePromotedTier() async throws {
        let transport = WatchTestTransport()
        let liked = WatchTestSupport.snapshot(playing: false, favorite: true)
        transport.automaticResponse = { request in
            request.action == .snapshot ? WatchTestSupport.response(for: request, snapshot: liked) : nil
        }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        XCTAssertEqual(displayed.nowPlaying?.isFavorite, true)
        XCTAssertEqual(displayed.nowPlaying?.isSuperLiked, false)
        let promote = Task { await model.command(.setSuperLiked(true), displayed: displayed) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 3 }
        XCTAssertNotNil(model.pendingCommand)
        XCTAssertEqual(transport.requests[2].action, .setSuperLiked(true))
        XCTAssertEqual(transport.requests[2].expectedTrackID, "watch-test-track")
        XCTAssertEqual(transport.requests[2].version, 2)
        XCTAssertNotNil(transport.requests[2].executionLease)
        XCTAssertEqual(model.nowPlaying?.isSuperLiked, false)
        try transport.reply(at: 2, snapshot: WatchTestSupport.snapshot(sequence: 2, playing: false, favorite: true, superLiked: true))
        let accepted = await promote.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.nowPlaying?.isFavorite, true)
        XCTAssertEqual(model.nowPlaying?.isSuperLiked, true)
        XCTAssertNil(model.pendingCommand)
        model.setForeground(false)
    }

    func testRapidNextTapsSendOneIntent() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { request in
            request.action == .snapshot ? WatchTestSupport.response(for: request) : nil
        }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        let first = Task { await model.command(.next, displayed: displayed) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 3 }
        let secondAccepted = await model.command(.next, displayed: displayed)
        XCTAssertFalse(secondAccepted)
        XCTAssertEqual(transport.requests.filter { $0.action == .next }.count, 1)
        try transport.reply(at: 2, snapshot: WatchTestSupport.snapshot(sequence: 2, trackID: "next-song"))
        let firstAccepted = await first.value
        XCTAssertTrue(firstAccepted)
        XCTAssertEqual(model.nowPlaying?.trackID, "next-song")
        model.setForeground(false)
    }

    func testBrowseSelectionCarriesExactOccurrenceAndRevisionAndShowsRejection() async throws {
        let transport = WatchTestTransport()
        let page = CompanionPage(location: "queue", title: "Queue", revision: "queue-revision", items: [
            CompanionItem(id: "item:1", title: "Second occurrence", subtitle: "Breezy Sessions")
        ], isTruncated: false)
        transport.automaticResponse = { request in
            switch request.action {
            case .browse:
                return WatchTestSupport.response(for: request, page: page)
            case .playItem:
                return WatchTestSupport.response(for: request, snapshot: WatchTestSupport.snapshot(sequence: 2), accepted: false,
                                                 error: "This list has changed. Refresh it before choosing a song.")
            default:
                return WatchTestSupport.response(for: request)
            }
        }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        await model.loadPage("queue")
        XCTAssertEqual(model.pages["queue"], page)
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        let accepted = await model.command(.playItem(location: page.location, itemID: page.items[0].id, revision: page.revision), displayed: displayed)
        XCTAssertFalse(accepted)
        XCTAssertEqual(transport.requests.last?.action, .playItem(location: "queue", itemID: "item:1", revision: "queue-revision"))
        XCTAssertEqual(transport.requests.last?.expectedTrackID, displayed.nowPlaying?.trackID)
        XCTAssertEqual(model.notice, "This list has changed. Refresh it before choosing a song.")
        XCTAssertFalse(model.needsReconciliation)
        model.setForeground(false)
    }

    func testTimedOutCommandOnlySchedulesFreshSnapshotAndIgnoresLateSuccess() async throws {
        let transport = WatchTestTransport()
        let deadline = WatchTestDeadline()
        transport.automaticResponse = { request in
            WatchTestSupport.response(for: request, snapshot: WatchTestSupport.snapshot(playing: false))
        }
        let client = WatchRequestClient(transport: transport, waitForDeadline: { try await deadline.wait() })
        let model = WatchCompanionModel(client: client)
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        transport.automaticResponse = nil
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        let command = Task { await model.command(.next, displayed: displayed) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 2 }
        try transport.reply(at: 1, snapshot: displayed)
        try await WatchTestSupport.waitUntil { transport.messages.count == 3 }
        try await WatchTestSupport.waitForDeadline(deadline, startedCount: 3)
        await deadline.fire()
        let accepted = await command.value
        XCTAssertFalse(accepted)
        try await WatchTestSupport.waitUntil { transport.messages.count == 4 }
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot, .snapshot, .next, .snapshot])
        XCTAssertTrue(model.needsReconciliation)
        XCTAssertFalse(model.canControl)
        try transport.reply(at: 2, snapshot: WatchTestSupport.snapshot(sequence: 99, trackID: "late-reply"))
        try transport.reply(at: 3, snapshot: WatchTestSupport.snapshot(sequence: 2, playing: false, trackID: "fresh-state"))
        try await WatchTestSupport.waitUntil { model.isCurrent }
        XCTAssertEqual(model.nowPlaying?.trackID, "fresh-state")
        XCTAssertFalse(model.needsReconciliation)
        XCTAssertEqual(transport.requests.filter { $0.action == .next }.count, 1)
        XCTAssertNotNil(model.notice)
        model.setForeground(false)
    }

    func testAmbiguousCommandRetiresReadStartedBeforeTheFailure() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { WatchTestSupport.response(for: $0) }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        transport.automaticResponse = nil
        let earlierBrowse = Task { await model.loadPage("favorites") }
        try await WatchTestSupport.waitUntil { transport.messages.count == 2 }
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        let next = Task { await model.command(.next, displayed: displayed) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 3 }
        try transport.reply(at: 2, snapshot: displayed)
        try await WatchTestSupport.waitUntil { transport.messages.count == 4 }
        transport.messages[3].completion(.failure(.deliveryFailed))
        _ = await next.value
        await earlierBrowse.value
        try await WatchTestSupport.waitUntil { transport.messages.count == 5 }
        let stalePage = CompanionPage(location: "favorites", title: "Favorites", revision: "old", items: [], isTruncated: false)
        try transport.reply(at: 1, snapshot: WatchTestSupport.snapshot(sequence: 80), page: stalePage)
        await Task.yield()
        XCTAssertTrue(model.needsReconciliation)
        XCTAssertNil(model.pages["favorites"])
        XCTAssertFalse(model.canControl)
        try transport.reply(at: 4, snapshot: WatchTestSupport.snapshot(sequence: 2))
        try await WatchTestSupport.waitUntil { model.isCurrent }
        XCTAssertEqual(model.timeline.snapshot?.sequence, 2)
        model.setForeground(false)
    }

    func testBackgroundCancellationDoesNotReplayWhenForegroundReturns() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { request in
            request.action == .snapshot ? WatchTestSupport.response(for: request, snapshot: WatchTestSupport.snapshot(playing: false)) : nil
        }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        let next = Task { await model.command(.next, displayed: displayed) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 3 }
        model.setForeground(false)
        let accepted = await next.value
        XCTAssertFalse(accepted)
        try transport.reply(at: 2, snapshot: WatchTestSupport.snapshot(sequence: 3, playing: true))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot, .snapshot, .next, .snapshot])
        model.setForeground(false)
    }

    func testEmptyConnectedPlayerCanBrowseAndStartAnExplicitItem() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { request in
            if case .playItem = request.action {
                return WatchTestSupport.response(for: request, snapshot: WatchTestSupport.snapshot(sequence: 2))
            }
            return WatchTestSupport.response(for: request, snapshot: WatchTestSupport.snapshot(empty: true))
        }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        XCTAssertNil(model.nowPlaying)
        XCTAssertFalse(model.canControl)
        XCTAssertTrue(model.canChooseItem)
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        let accepted = await model.command(.playItem(location: "favorites", itemID: "item:0", revision: "revision"), displayed: displayed)
        XCTAssertTrue(accepted)
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(transport.requests.last?.expectedTrackID)
        model.setForeground(false)
    }

    func testWrongLocationPageIsNotDisplayed() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { request in
            WatchTestSupport.response(for: request, page: CompanionPage(location: "recent", title: "Recent", revision: "revision", items: [], isTruncated: false))
        }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        await model.loadPage("favorites")
        XCTAssertNil(model.pages["favorites"])
        XCTAssertNotNil(model.pageErrors["favorites"])
        model.setForeground(false)
    }

    func testPreflightValidationFailureDoesNotClaimCommandWasDispatched() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { WatchTestSupport.response(for: $0) }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        let accepted = await model.command(.seek(-1), displayed: displayed)
        XCTAssertFalse(accepted)
        XCTAssertFalse(model.needsReconciliation)
        XCTAssertTrue(model.canControl)
        XCTAssertEqual(model.notice, "Choose a valid playback position.")
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot])
        model.setForeground(false)
    }

    func testRenderedTrackARemainsCapturedWhenTrackBWinsBeforeTaskRuns() async throws {
        let transport = WatchTestTransport()
        let a = WatchTestSupport.snapshot(playing: false, trackID: "song-a")
        transport.automaticResponse = { WatchTestSupport.response(for: $0, snapshot: a) }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        defer { model.setForeground(false) }
        try await WatchTestSupport.waitUntil { model.isCurrent }
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        let action = CompanionAction.play
        let tap = Task { await model.command(action, displayed: displayed) }
        let b = WatchTestSupport.snapshot(sequence: 2, playing: false, trackID: "song-b")
        transport.onEvent?(.applicationContext(try CompanionWire.encode(b)))
        let accepted = await tap.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.nowPlaying?.trackID, "song-b")
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot])
        XCTAssertFalse(model.needsReconciliation)
    }

    func testRenderedValuesCannotOverwriteNewerPlayFavoriteShuffleOrRepeatState() async throws {
        let paused = WatchTestSupport.snapshot(playing: false)
        let playing = WatchTestSupport.snapshot(playing: true)
        let liked = WatchTestSupport.snapshot(playing: false, favorite: true)
        let superLiked = WatchTestSupport.snapshot(playing: false, favorite: true, superLiked: true)
        let changes: [(CompanionAction, CompanionSnapshot, CompanionSnapshot)] = [
            (.play, paused, WatchTestSupport.snapshot(sequence: 2, playing: true)),
            (.pause, playing, WatchTestSupport.snapshot(sequence: 2, playing: false)),
            (.pause, WatchTestSupport.snapshot(playing: false, loading: true), WatchTestSupport.snapshot(sequence: 2, playing: false)),
            (.setFavorite(true), paused, WatchTestSupport.snapshot(sequence: 2, playing: false, favorite: true)),
            (.setSuperLiked(true), paused, WatchTestSupport.snapshot(sequence: 2, playing: false, favorite: true, superLiked: true)),
            (.setSuperLiked(true), liked, WatchTestSupport.snapshot(sequence: 2, playing: false, favorite: true, superLiked: true)),
            (.setFavorite(false), liked, WatchTestSupport.snapshot(sequence: 2, playing: false, favorite: true, superLiked: true)),
            (.setSuperLiked(false), superLiked, WatchTestSupport.snapshot(sequence: 2, playing: false, favorite: true)),
            (.setShuffle(true), paused, WatchTestSupport.snapshot(sequence: 2, playing: false, shuffle: true)),
            (.setRepeatMode(.all), paused, WatchTestSupport.snapshot(sequence: 2, playing: false, repeatMode: .one))
        ]
        for (action, displayed, current) in changes {
            let transport = WatchTestTransport()
            transport.automaticResponse = { WatchTestSupport.response(for: $0, snapshot: displayed) }
            let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
            model.setForeground(true)
            try await WatchTestSupport.waitUntil { model.isCurrent }
            let tap = Task { await model.command(action, displayed: displayed) }
            transport.onEvent?(.applicationContext(try CompanionWire.encode(current)))
            let accepted = await tap.value
            XCTAssertFalse(accepted, "\(action)")
            XCTAssertEqual(transport.requests.map(\.action), [.snapshot])
            XCTAssertEqual(model.nowPlaying, current.nowPlaying)
            model.setForeground(false)
        }
    }

    func testNewerContextDuringPreflightPreventsMutationDispatch() async throws {
        let transport = WatchTestTransport()
        let displayed = WatchTestSupport.snapshot(trackID: "song-a")
        transport.automaticResponse = { WatchTestSupport.response(for: $0, snapshot: displayed) }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        defer { model.setForeground(false) }
        try await WatchTestSupport.waitUntil { model.isCurrent }
        transport.automaticResponse = nil
        let tap = Task { await model.command(.next, displayed: displayed) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 2 }
        let newer = WatchTestSupport.snapshot(sequence: 2, trackID: "song-b")
        transport.onEvent?(.applicationContext(try CompanionWire.encode(newer)))
        try transport.reply(at: 1, snapshot: displayed)
        let accepted = await tap.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(transport.requests.allSatisfy { WatchActionPolicy.isReadOnly($0.action) })
        XCTAssertEqual(model.nowPlaying?.trackID, "song-b")
        XCTAssertFalse(model.needsReconciliation)
    }

    func testBackgroundDuringPreflightCancelsWithoutCommandAmbiguity() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { WatchTestSupport.response(for: $0) }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        let displayed = try XCTUnwrap(model.timeline.snapshot)
        transport.automaticResponse = nil
        let tap = Task { await model.command(.next, displayed: displayed) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 2 }
        model.setForeground(false)
        let accepted = await tap.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(model.needsReconciliation)
        try transport.reply(at: 1, snapshot: displayed)
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot, .snapshot])
    }

    func testLibraryFailureIsSeparateWhilePlayingClockAndTransportRemainLive() async throws {
        let transport = WatchTestTransport()
        let error = "Open Breezy on iPhone to check or recover your library."
        transport.automaticResponse = { WatchTestSupport.response(for: $0, snapshot: WatchTestSupport.snapshot(libraryError: error)) }
        var clock: TimeInterval = 100
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport), uptime: { clock })
        model.setForeground(true)
        defer { model.setForeground(false) }
        try await WatchTestSupport.waitUntil { model.isCurrent }
        clock = 105
        XCTAssertEqual(model.libraryError, error)
        XCTAssertNil(model.nowPlaying?.errorMessage)
        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(model.canControl)
        XCTAssertEqual(model.position, 47)
    }

    func testLibraryFailureWithoutTrackRemainsDistinctFromEmptyPlayer() async throws {
        let transport = WatchTestTransport()
        let error = "Open Breezy on iPhone to check or recover your library."
        transport.automaticResponse = {
            WatchTestSupport.response(for: $0, snapshot: WatchTestSupport.snapshot(empty: true, libraryError: error))
        }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
        model.setForeground(true)
        defer { model.setForeground(false) }
        try await WatchTestSupport.waitUntil { model.isCurrent }
        XCTAssertNil(model.nowPlaying)
        XCTAssertEqual(model.libraryError, error)
        XCTAssertFalse(model.canControl)
        XCTAssertFalse(model.isPlaying)
    }
}
