import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class SeedRadioModelTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures

    func testSongStartsImmediatelyThenRefillsFromOriginalSeedAndTunesWithoutLosingManualDuplicates() async throws {
        let context = try makeContext()
        let seed = Fixtures.track("saavn:chosen", title: "Chosen Recording", artist: "Seed Artist", language: .english)
        let familiar = Fixtures.track("familiar", artist: "Familiar Artist", language: .english)
        let fresh = Fixtures.track("fresh", artist: "Fresh Artist", language: .english)
        let familiarHindi = Fixtures.track("familiar-hindi", artist: "Known Hindi Artist", language: .hindi)
        let freshHindi = Fixtures.track("fresh-hindi", artist: "New Hindi Artist", language: .hindi)
        context.seedHistory(familiar)
        context.seedHistory(familiarHindi)
        context.model.updatePreferences { $0.autoplay = false }

        await context.model.startRadio(seed: .song(seed), tuning: RadioTuning(familiarity: .familiar)).value
        XCTAssertEqual(context.player.queue.map(\.id), ["saavn:chosen"])
        XCTAssertEqual(context.player.currentTrack, seed)
        XCTAssertEqual(context.model.activeRadioSeed, .song(seed))
        XCTAssertEqual(context.model.radioSessionLabel, "Chosen Recording Radio")
        XCTAssertFalse(context.model.isStartingSeedRadio)
        XCTAssertNil(context.model.seedRadioError)
        let initialRequests = await context.catalog.autoplayRadios.requests
        XCTAssertTrue(initialRequests.isEmpty, "Accepting the exact seed must not wait for recommendations.")
        let stream = try await context.streams.streams.request(at: 0)
        XCTAssertEqual(stream.input.track, seed)
        context.player.pause()
        try await context.streams.streams.complete(stream, with: .failure(CancellationError()))
        context.player.seek(to: 37)
        let session = try XCTUnwrap(context.model.seedRadioSessionID)
        let callback = try XCTUnwrap(context.player.onQueueExhausted)

        var firstBatch: [Track] = []
        let firstRefill = context.start { _ in firstBatch = await callback(seed) }
        let firstRequest = try await context.catalog.autoplayRadios.request(at: 0)
        XCTAssertEqual(firstRequest.input.id, "saavn:chosen")
        try await context.catalog.autoplayRadios.complete(firstRequest, with: .success([fresh, familiar]))
        await firstRefill.value
        XCTAssertEqual(firstBatch.map(\.id), ["familiar", "fresh"])
        context.player.appendAutoplay(firstBatch)

        var staleBatch: [Track] = []
        let staleRefill = context.start { _ in staleBatch = await callback(fresh) }
        let staleRequest = try await context.catalog.autoplayRadios.request(at: 1)
        let tuning = RadioTuning(familiarity: .newMusic, language: .hindi)
        context.model.tuneRadio(tuning)
        XCTAssertEqual(context.player.queue.map(\.id), ["saavn:chosen", "familiar", "fresh"])
        XCTAssertEqual(context.player.position, 37)
        XCTAssertEqual(context.model.seedRadioSessionID, session)
        XCTAssertEqual(context.model.radioTuning, tuning)

        var tunedBatch: [Track] = []
        let tunedRefill = context.start { _ in tunedBatch = await callback(fresh) }
        let tunedRequest = try await context.catalog.autoplayRadios.request(at: 2)
        context.player.enqueue(familiar)
        try await context.catalog.autoplayRadios.complete(staleRequest, with: .success([
            Fixtures.track("stale-english", artist: "Stale Artist", language: .english),
        ]))
        await staleRefill.value
        XCTAssertTrue(staleBatch.isEmpty)
        XCTAssertTrue(context.model.isContinuingRadio, "The retired response must not end the newer refill.")
        try await context.catalog.autoplayRadios.complete(tunedRequest, with: .success([
            Fixtures.track("new-english", artist: "English Artist", language: .english), familiarHindi, freshHindi,
        ]))
        await tunedRefill.value
        XCTAssertEqual(tunedBatch.map(\.id), ["fresh-hindi", "familiar-hindi"])
        context.player.appendAutoplay(tunedBatch)
        XCTAssertEqual(context.player.queue.map(\.id), ["saavn:chosen", "familiar", "fresh", "familiar", "fresh-hindi", "familiar-hindi"])
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.position, 37)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.settings.autoplay)
        XCTAssertEqual(context.model.activeRadioSeed, .song(seed))
        XCTAssertEqual(context.model.seedRadioSessionID, session)
        XCTAssertNil(context.model.radioContinuationError)
        XCTAssertEqual(context.model.seedRadioHistory.entries.map(\.id), ["song:saavn:chosen"])
        XCTAssertEqual(context.model.seedRadioHistory.entries.first?.tuning, tuning)
        let requests = await context.catalog.radioRefreshRequests
        XCTAssertEqual(requests.map(\.seed.id), ["saavn:chosen", "saavn:chosen", "saavn:chosen"])
        XCTAssertEqual(requests.map(\.forceRefresh), [false, false, false])
        XCTAssertEqual(LibraryStore(directory: context.directory).playback.queue.map(\.id),
                       ["saavn:chosen", "familiar", "fresh", "familiar", "fresh-hindi", "familiar-hindi"])
    }

    func testPendingArtistKeepsOldQueueAndPauseExplicitPlayOrCancelRejectsLateStart() async throws {
        for action in ["accept", "pause", "play", "cancel"] {
            let old = Fixtures.track("old-song")
            let upcoming = Fixtures.track("old-upcoming")
            let context = try makeContext(snapshot: PlaybackSnapshot(queue: [old, upcoming], position: 42))
            let artist = ArtistCredit(name: "Chosen Artist", id: "saavn:artist:chosen")
            let anchor = Fixtures.track("saavn:artist-song", artist: "Chosen Artist", artistID: "saavn:artist:chosen")
            let pending = context.model.startRadio(seed: .artist(artist))
            defer { pending.cancel() }
            let request = try await context.catalog.artists.request(at: 0)
            XCTAssertEqual(request.input, "saavn:artist:chosen")
            XCTAssertTrue(context.model.isStartingSeedRadio)
            XCTAssertEqual(context.player.queue.map(\.id), ["old-song", "old-upcoming"])
            XCTAssertEqual(context.player.position, 42)
            XCTAssertNil(context.model.activeRadioSeed)
            XCTAssertTrue(context.model.seedRadioHistory.entries.isEmpty)

            let explicit = Fixtures.track("explicit-song")
            switch action {
            case "pause": context.player.pause()
            case "play": XCTAssertTrue(context.model.play(explicit))
            case "cancel": context.model.cancelSeedRadioStart()
            default: break
            }
            try await context.catalog.artists.complete(request, with: .success(
                ArtistPage(id: "saavn:artist:chosen", name: "Chosen Artist", topSongs: [anchor])))
            await pending.value
            XCTAssertFalse(context.model.isStartingSeedRadio, action)
            XCTAssertNil(context.model.seedRadioError, action)
            if action == "accept" {
                XCTAssertEqual(context.player.queue.map(\.id), ["saavn:artist-song"])
                XCTAssertEqual(context.model.activeRadioSeed, .artist(artist))
                XCTAssertNotNil(context.model.seedRadioSessionID)
                XCTAssertEqual(context.model.seedRadioHistory.entries.map(\.id), ["artist:saavn:artist:chosen"])
            } else {
                XCTAssertEqual(context.player.queue.map(\.id), action == "play" ? ["explicit-song"] : ["old-song", "old-upcoming"], action)
                XCTAssertEqual(context.player.position, action == "play" ? 0 : 42, action)
                XCTAssertNil(context.model.activeRadioSeed, action)
                XCTAssertNil(context.model.seedRadioSessionID, action)
                XCTAssertFalse(context.player.isRadioSession, action)
                XCTAssertTrue(context.model.seedRadioHistory.entries.isEmpty, action)
            }
            context.player.pause()
            let radios = await context.catalog.autoplayRadios.requests
            XCTAssertTrue(radios.isEmpty, action)
        }
    }

    func testReselectingCurrentSongPreservesSelectedDuplicatePositionAndQueue() async throws {
        let seed = Fixtures.track("current-song")
        let manual = Fixtures.track("manual-song")
        let context = try makeContext(snapshot: PlaybackSnapshot(
            queue: [seed, manual, seed, manual], currentIndex: 2, position: 53, repeatMode: .all))
        let control = context.player.controlRevision
        await context.model.startRadio(seed: .song(seed)).value
        XCTAssertNotNil(context.model.seedRadioSessionID)
        await context.model.startRadio(seed: .song(seed), tuning: RadioTuning(familiarity: .newMusic)).value
        XCTAssertEqual(context.player.queue.map(\.id), ["current-song", "manual-song", "current-song", "manual-song"])
        XCTAssertEqual(context.player.currentIndex, 2)
        XCTAssertEqual(context.player.currentTrack, seed)
        XCTAssertEqual(context.player.position, 53)
        XCTAssertEqual(context.player.controlRevision, control)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertEqual(context.player.repeatMode, .off)
        XCTAssertTrue(context.player.isRadioSession)
        XCTAssertEqual(context.model.radioTuning, RadioTuning(familiarity: .newMusic))
        XCTAssertEqual(context.model.seedRadioHistory.entries.map(\.id), ["song:current-song"])
        let streams = await context.streams.streams.requests
        XCTAssertTrue(streams.isEmpty, "Attaching or reselecting radio must not resolve the current recording again.")
        let saved = LibraryStore(directory: context.directory).playback
        XCTAssertEqual(saved.queue.map(\.id), ["current-song", "manual-song", "current-song", "manual-song"])
        XCTAssertEqual(saved.currentIndex, 2)
        XCTAssertEqual(saved.position, 53)
    }

    func testHistoryOffAndClearRemoveListenAgainAndFenceLateArtistAndRefillResults() async throws {
        for disable in [true, false] {
            let seed = Fixtures.track("history-seed")
            let context = try makeContext(snapshot: PlaybackSnapshot(queue: [seed], position: 29))
            await context.model.startRadio(seed: .song(seed)).value
            let session = try XCTUnwrap(context.model.seedRadioSessionID)
            XCTAssertEqual(context.model.seedRadioHistory.entries.map(\.id), ["song:history-seed"])
            let callback = try XCTUnwrap(context.player.onQueueExhausted)
            var additions: [Track] = []
            let refill = context.start { _ in additions = await callback(seed) }
            let radioRequest = try await context.catalog.autoplayRadios.request(at: 0)
            let artist = ArtistCredit(name: "Late Artist", id: "late-artist")
            let pending = context.model.startRadio(seed: .artist(artist))
            defer { pending.cancel() }
            let artistRequest = try await context.catalog.artists.request(at: 0)
            let epoch = context.library.listeningHistoryEpoch

            if disable { context.model.updatePreferences { $0.saveListeningHistory = false } }
            else { context.library.clearHistory() }
            XCTAssertEqual(context.library.preferences.saveListeningHistory, !disable)
            if !disable { XCTAssertNotEqual(context.library.listeningHistoryEpoch, epoch) }
            XCTAssertTrue(context.model.seedRadioHistory.entries.isEmpty)
            XCTAssertFalse(context.model.isStartingSeedRadio)
            XCTAssertFalse(context.model.isContinuingRadio)
            let late = Fixtures.track("late-artist-song", artist: "Late Artist", artistID: "late-artist")
            try await context.catalog.artists.complete(artistRequest, with: .success(
                ArtistPage(id: "late-artist", name: "Late Artist", topSongs: [late])))
            try await context.catalog.autoplayRadios.complete(radioRequest, with: .success([late]))
            await pending.value
            await refill.value
            XCTAssertTrue(additions.isEmpty)
            XCTAssertEqual(context.player.queue.map(\.id), ["history-seed"])
            XCTAssertEqual(context.player.position, 29)
            XCTAssertEqual(context.model.seedRadioSessionID, session)
            XCTAssertNil(context.model.seedRadioError)
            XCTAssertNil(context.model.radioContinuationError)
            XCTAssertTrue(context.model.seedRadioHistory.entries.isEmpty)

            if disable {
                await context.model.startRadio(seed: .song(seed), tuning: RadioTuning(familiarity: .familiar)).value
                XCTAssertEqual(context.model.activeRadioSeed, .song(seed))
                XCTAssertTrue(context.model.seedRadioHistory.entries.isEmpty, "Radio remains usable with history disabled.")
                context.model.updatePreferences { $0.saveListeningHistory = true }
            }
            context.model.seedRadioHistory.reload(historyEpoch: context.library.listeningHistoryEpoch, enabled: true)
            XCTAssertTrue(context.model.seedRadioHistory.entries.isEmpty, "Re-enabling or reloading must not restore erased Listen Again entries.")
            XCTAssertNil(context.model.seedRadioHistory.errorMessage)
            XCTAssertNil(context.library.errorMessage)
        }
    }

    func testFailedRefillReportsContinuationErrorAndExplicitRetryAppendsWithoutRestart() async throws {
        let seed = Fixtures.track("retry-seed")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [seed], position: 41))
        await context.model.startRadio(seed: .song(seed)).value
        let session = try XCTUnwrap(context.model.seedRadioSessionID)
        let control = context.player.controlRevision
        let callback = try XCTUnwrap(context.player.onQueueExhausted)
        var failedBatch: [Track] = []
        let refill = context.start { _ in failedBatch = await callback(seed) }
        let failed = try await context.catalog.autoplayRadios.request(at: 0)
        try await context.catalog.autoplayRadios.complete(failed, with: .failure(MusicServiceError.network("Refill unavailable")))
        await refill.value
        XCTAssertTrue(failedBatch.isEmpty)
        XCTAssertNotNil(context.model.radioContinuationError)
        XCTAssertNil(context.model.seedRadioError)
        XCTAssertFalse(context.model.isContinuingRadio)
        XCTAssertEqual(context.player.queue.map(\.id), ["retry-seed"])
        XCTAssertEqual(context.player.position, 41)

        context.model.tuneRadio(RadioTuning(familiarity: .newMusic))
        XCTAssertNotNil(context.model.radioContinuationError, "Tune must keep an explicit recovery action for a stopped radio")
        XCTAssertFalse(context.player.isPlaying)
        context.model.retryRadioContinuation()
        let retry = try await context.catalog.autoplayRadios.request(at: 1)
        XCTAssertTrue(context.model.isContinuingRadio)
        XCTAssertNil(context.model.radioContinuationError)
        XCTAssertEqual(context.player.queue.map(\.id), ["retry-seed"])
        let next = Fixtures.track("retry-next", artist: "Next Artist")
        try await context.catalog.autoplayRadios.complete(retry, with: .success([next]))
        try await AppModelFixtures.eventually { context.player.queue.count == 2 && !context.model.isContinuingRadio }
        XCTAssertEqual(context.player.queue.map(\.id), ["retry-seed", "retry-next"])
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.currentTrack, seed)
        XCTAssertEqual(context.player.position, 41)
        XCTAssertEqual(context.player.controlRevision, control)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertEqual(context.model.seedRadioSessionID, session)
        XCTAssertEqual(context.model.activeRadioSeed, .song(seed))
        XCTAssertNil(context.model.radioContinuationError)
        let requests = await context.catalog.radioRefreshRequests
        XCTAssertEqual(requests.map(\.seed.id), ["retry-seed", "retry-seed"])
        XCTAssertEqual(requests.map(\.forceRefresh), [false, true])
        let streams = await context.streams.streams.requests
        XCTAssertTrue(streams.isEmpty)
    }

    func testAutoplayOffStillInvokesInstalledQueueExhaustedCallbackForSeedRadio() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 60)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = try makeContext(resolver: PlaybackFileResolver(url: url, duration: 60))
        context.model.updatePreferences { $0.autoplay = false }
        let callback = try XCTUnwrap(context.player.onQueueExhausted)
        var exhausted: [String] = []
        context.player.onQueueExhausted = { track in
            exhausted.append(track.id)
            return await callback(track)
        }
        context.player.onQueueEnded = { _ in
            XCTFail("Seed radio must use its regular refill callback, not ordinary Autoplay's final retry.")
            return []
        }
        let seed = Fixtures.track("native-seed", duration: 60)
        await context.model.startRadio(seed: .song(seed)).value
        try await PlaybackTestSupport.eventually { await context.catalog.autoplayRadios.requests.count == 1 }
        let request = try await context.catalog.autoplayRadios.request(at: 0)
        XCTAssertEqual(exhausted, ["native-seed"])
        XCTAssertEqual(request.input.id, "native-seed")
        let next = (1...4).map { Fixtures.track("native-next-\($0)", artist: "Artist \($0)", duration: 60) }
        try await context.catalog.autoplayRadios.complete(request, with: .success(next))
        try await PlaybackTestSupport.waitUntil { context.player.queue.count == 5 }
        context.player.pause()
        XCTAssertEqual(context.player.queue.map(\.id), ["native-seed", "native-next-1", "native-next-2", "native-next-3", "native-next-4"])
        XCTAssertEqual(context.player.currentTrack, seed)
        XCTAssertFalse(context.library.preferences.autoplay)
        XCTAssertFalse(context.player.settings.autoplay)
        XCTAssertTrue(context.player.isRadioSession)
        XCTAssertEqual(context.model.activeRadioSeed, .song(seed))
        XCTAssertNil(context.model.radioContinuationError)
    }

    func testOrdinaryPlayEndsSeededContextAndRejectsLateRefill() async throws {
        let seed = Fixtures.track("retired-seed")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [seed], position: 18))
        await context.model.startRadio(seed: .song(seed)).value
        let callback = try XCTUnwrap(context.player.onQueueExhausted)
        var lateBatch: [Track] = []
        let refill = context.start { _ in lateBatch = await callback(seed) }
        let request = try await context.catalog.autoplayRadios.request(at: 0)
        let explicit = Fixtures.track("ordinary-song")
        XCTAssertTrue(context.model.play(explicit))
        context.player.pause()
        try await context.catalog.autoplayRadios.complete(request, with: .success([Fixtures.track("retired-addition")]))
        await refill.value
        XCTAssertTrue(lateBatch.isEmpty)
        XCTAssertEqual(context.player.queue.map(\.id), ["ordinary-song"])
        XCTAssertFalse(context.player.isRadioSession)
        XCTAssertNil(context.model.activeRadioSeed)
        XCTAssertNil(context.model.seedRadioSessionID)
        XCTAssertNil(context.model.radioSessionLabel)
        XCTAssertNil(context.model.radioContinuationError)
        XCTAssertFalse(context.model.isContinuingRadio)

        await context.catalog.autoplayRadios.enqueue(.success([Fixtures.track("ordinary-next")]))
        let ordinary = await callback(explicit)
        XCTAssertEqual(ordinary.map(\.id), ["ordinary-next"])
        let calls = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(calls.map(\.input.id), ["retired-seed", "ordinary-song"])
    }

    func testLiveRadioEndsSeededContextAndReturningToMusicDoesNotRestoreIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeedRadioLiveModelTests-\(UUID())")
        let library = LibraryStore(directory: directory)
        library.preferences.useEncryptedDNS = false
        let seed = Fixtures.track("live-retired-seed")
        library.updatePlayback(PlaybackSnapshot(queue: [seed], position: 26))
        let catalog = AppModelCatalogProvider()
        let charts = AppModelChartsProvider()
        let lyrics = AppModelLyricsProvider()
        let streams = AppModelStreamResolver()
        let live = LiveRadioResolutionGate()
        let player = PlayerController(resolver: streams, liveRadioResolver: live)
        let model = MusicAppModel(library: library, player: player, catalog: catalog, charts: charts, lyrics: lyrics,
            account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()), generatesMixes: false)
        addTeardownBlock { @MainActor in
            model.cancelSeedRadioStart()
            model.deactivateDeviceServices()
            player.onQueueExhausted = nil
            player.onQueueEnded = nil
            player.pause()
            await catalog.close()
            await charts.charts.close()
            await streams.streams.close()
            await live.cancelRemaining()
            await model.languageDiscovery.waitForChecks()
            try FileManager.default.removeItem(at: directory)
        }
        await model.startRadio(seed: .song(seed)).value
        let callback = try XCTUnwrap(player.onQueueExhausted)
        let pending = Task { await callback(seed) }
        addTeardownBlock { @MainActor in
            pending.cancel()
            await catalog.close()
            _ = await pending.value
        }
        let request = try await catalog.autoplayRadios.request(at: 0)
        XCTAssertTrue(model.playLiveRadio(LiveRadioTestSupport.station))
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        XCTAssertTrue(player.isLiveRadio)
        XCTAssertNil(player.currentTrack)
        XCTAssertFalse(player.isRadioSession)
        XCTAssertNil(model.activeRadioSeed)
        XCTAssertNil(model.seedRadioSessionID)
        XCTAssertNil(model.radioSessionLabel)
        try await catalog.autoplayRadios.complete(request, with: .success([Fixtures.track("late-live-addition")]))
        let additions = await pending.value
        XCTAssertTrue(additions.isEmpty)
        XCTAssertNil(model.radioContinuationError)
        XCTAssertFalse(model.isContinuingRadio)
        player.stopLiveRadio()
        XCTAssertEqual(player.queue.map(\.id), ["live-retired-seed"])
        XCTAssertEqual(player.position, 26)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isRadioSession)
        XCTAssertNil(model.activeRadioSeed)
        XCTAssertNil(model.seedRadioSessionID)
    }

    func testTunedHistoryRestartsItsOriginalSeedAndUsesCurrentLanguageCorrectionsForAdditions() async throws {
        let seed = Fixtures.track("language-seed", title: "Original English Song", language: .english)
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [seed], position: 29))
        let tuning = RadioTuning(familiarity: .newMusic, language: .hindi)
        await context.model.startRadio(seed: .song(seed), tuning: tuning).value
        XCTAssertEqual(context.model.activeRadioSeed, .song(seed), "Language tuning governs additions, not the explicit seed")
        XCTAssertNil(context.model.seedRadioError)
        let entry = try XCTUnwrap(context.model.seedRadioHistory.entries.first)
        await context.model.startRadio(seed: entry.seed, tuning: entry.tuning).value
        XCTAssertEqual(context.player.position, 29)
        XCTAssertEqual(context.model.radioTuning, tuning)

        let corrected = Fixtures.track("language-corrected", artist: "Corrected Artist", language: .english)
        context.library.setRecordingLanguageOverride("hi", for: corrected.id)
        await context.catalog.autoplayRadios.enqueue(.success([corrected, Fixtures.track("still-english", language: .english)]))
        let additions = await context.player.onQueueExhausted?(seed)
        XCTAssertEqual(additions?.map(\.id), [corrected.id], "Corrections made during the session must affect both selection passes")
    }

    func testUnreadableLibraryPreservesRadioHistoryUntilSuccessfulReload() async throws {
        let context = try makeContext()
        context.library.clearHistory()
        let seed = Fixtures.track("saavn:saved-radio", language: .english)
        await context.model.startRadio(seed: .song(seed)).value
        context.player.pause()
        let libraryURL = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let historyURL = context.directory.appendingPathComponent("radio-history.json")
        let savedLibrary = try Data(contentsOf: libraryURL)
        let savedHistory = try Data(contentsOf: historyURL)
        try Data("broken".utf8).write(to: libraryURL, options: .atomic)
        let unreadable = LibraryStore(directory: context.directory)
        XCTAssertFalse(unreadable.hasLoadedDocument)
        let player = PlayerController(resolver: context.streams)
        let recovering = MusicAppModel(library: unreadable, player: player, catalog: context.catalog,
            charts: AppModelChartsProvider(), lyrics: AppModelLyricsProvider(),
            account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()), generatesMixes: false)
        defer { player.pause(); player.onQueueExhausted = nil; player.onQueueEnded = nil }
        XCTAssertEqual(try Data(contentsOf: historyURL), savedHistory)
        await recovering.startRadio(seed: .song(seed)).value
        XCTAssertNotNil(recovering.seedRadioError)
        XCTAssertEqual(try Data(contentsOf: historyURL), savedHistory)
        try savedLibrary.write(to: libraryURL, options: .atomic)
        _ = recovering.reloadSavedLibrary()
        XCTAssertTrue(unreadable.hasLoadedDocument)
        XCTAssertEqual(recovering.seedRadioHistory.entries.map(\.id), ["song:saavn:saved-radio"])
        XCTAssertEqual(try Data(contentsOf: historyURL), savedHistory)
    }

    private func makeContext(snapshot: PlaybackSnapshot = PlaybackSnapshot(),
                             resolver: (any StreamResolving)? = nil) throws -> AppModelTestContext {
        let context = try AppModelTestContext(snapshot: snapshot, resolver: resolver)
        addTeardownBlock { @MainActor in
            context.model.cancelSeedRadioStart()
            context.player.onQueueExhausted = nil
            context.player.onQueueEnded = nil
            try await context.close()
        }
        return context
    }
}
