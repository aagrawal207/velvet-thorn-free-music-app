import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class R17IntegrationTests: XCTestCase {
    private typealias F = DebugR17Fixture
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testSavedLanguageCorrectionAndUnclassifiedControlPhoneAndTVScriptLabels() async throws {
        let model = try makeContext().model
        let track = F.tracks[0]
        try await load(track, in: model)
        XCTAssertTrue(model.tvLyrics.start())
        for code in ["hi", "und", "pa-Guru"] {
            XCTAssertTrue(model.library.setRecordingLanguageOverride(code, for: track.id))
            try await PlaybackTestSupport.waitUntil {
                model.lyricsSelection.recordingLanguage == code && !model.lyricsSelection.isDiscoveringVariants
                    && model.tvLyrics.document != nil
            }
            XCTAssertEqual(model.lyricsSelection.recordingLanguage, code)
            XCTAssertEqual(model.tvLyrics.selectionLabel?.contains("Original Script"), code == "pa-Guru")
        }
    }

    func testCorrectionDuringMetadataLookupRetiresTheProviderLanguageResult() async throws {
        let model = try makeContext().model
        let requests = AppModelRequestGate<Track, String>()
        addTeardownBlock { await requests.close() }
        model.lyricLanguageLookup = { try await requests.receive($0) }
        let track = F.tracks[0]
        model.loadSelectedLyrics(for: track)
        let pending = try XCTUnwrap(model.lyricsSelectionTask)
        let request = try await requests.request(at: 0)
        XCTAssertTrue(model.library.setRecordingLanguageOverride("und", for: track.id))
        try await PlaybackTestSupport.waitUntil {
            model.lyricsSelection.recordingLanguage == "und" && model.lyricsSelection.selectedDocument != nil
        }
        try await requests.complete(request, with: .success("pa-Guru"))
        await pending.value
        XCTAssertEqual(model.lyricsSelection.recordingLanguage, "und")
        XCTAssertFalse(model.tvLyrics.selectionLabel?.contains("Original Script") ?? true)
    }

    func testModelSelectedLyricsAndTVUseTheSamePublishedVariantAcrossTracks() async throws {
        let context = try makeContext()
        let model = context.model
        let a = F.tracks[0], b = F.tracks[1]
        try await load(a, in: model)
        XCTAssertEqual(model.lyricsSelection.variants.count, 2)
        XCTAssertEqual(model.tvLyrics.document?.selectionID, F.documents(for: a)[0].selectionID)
        XCTAssertTrue(model.tvLyrics.selectionLabel?.contains("Original Script · Gurmukhi") == true)

        let latin = F.documents(for: a)[1]
        model.lyricsSelection.selectVariant(id: latin.selectionID, for: a)
        XCTAssertEqual(model.lyricsSelection.selectedDocument?.selectionID, latin.selectionID)
        XCTAssertEqual(model.tvLyrics.document?.selectionID, latin.selectionID)
        XCTAssertEqual(model.tvLyrics.lineWindow.current?.text, F.latin[0])
        XCTAssertEqual(model.tvLyrics.document?.attributionText, F.attribution)
        XCTAssertTrue(model.tvLyrics.start())

        model.player.restore(PlaybackSnapshot(queue: [b], position: 32))
        XCTAssertNil(model.tvLyrics.document, "The live identity fence applies before the observation hop")
        try await PlaybackTestSupport.waitUntil { model.lyricsSelection.selectedDocument?.trackID == b.id }
        XCTAssertEqual(model.tvLyrics.document?.selectionID, F.documents(for: b)[0].selectionID)
        model.lyricsSelection.selectVariant(id: F.documents(for: b)[1].selectionID, for: a)
        XCTAssertEqual(model.tvLyrics.document?.selectionID, F.documents(for: b)[0].selectionID,
                       "A retired sheet cannot choose the new recording's variant")

        model.lyricsSelection.selectVariant(id: F.documents(for: b)[1].selectionID, for: b)
        XCTAssertEqual(model.tvLyrics.document?.selectionID, model.lyricsSelection.selectedDocument?.selectionID)
        model.tvLyrics.stop()
        XCTAssertFalse(model.tvLyrics.isPhonePresented)
        XCTAssertNil(model.tvLyrics.document)
        model.prepareTVLyrics()
        XCTAssertEqual(model.tvLyrics.document?.selectionID, F.documents(for: b)[1].selectionID,
                       "Reopening TV uses the model's selected text")
    }

    func testLateLyricsFailureForADoesNotReplaceBOrItsTVSelection() async throws {
        let provider = HeldLyrics()
        addTeardownBlock { await provider.requests.close() }
        let context = try makeContext(lyrics: provider)
        let model = context.model
        model.loadSelectedLyrics(for: F.tracks[0], recordingLanguage: "pa-Guru")
        let pendingA = try XCTUnwrap(model.lyricsSelectionTask)
        let requestA = try await provider.requests.request(at: 0)
        XCTAssertTrue(model.tvLyrics.start())
        model.player.restore(PlaybackSnapshot(queue: [F.tracks[1]], position: 32))
        let requestB = try await provider.requests.request(at: 1)
        XCTAssertEqual(requestB.input.id, F.tracks[1].id)
        try await provider.requests.complete(requestB, with: .success(F.documents(for: F.tracks[1])[0]))
        try await PlaybackTestSupport.waitUntil { model.lyricsSelection.variants.count == 2 }
        let selected = F.documents(for: F.tracks[1])[1]
        model.lyricsSelection.selectVariant(id: selected.selectionID, for: F.tracks[1])
        try await provider.requests.complete(requestA, with: .failure(MusicServiceError.network("Retired A request")))
        await pendingA.value

        XCTAssertEqual(model.lyricsSelection.selectedDocument?.selectionID, selected.selectionID)
        XCTAssertEqual(model.tvLyrics.document?.selectionID, selected.selectionID)
        XCTAssertNil(model.lyricsSelection.variantMessage)
        XCTAssertFalse(model.lyricsSelection.isDiscoveringVariants)
    }

    func testHistoryDisableClearAndSignOutRetirePendingLyricsAndTV() async throws {
        for boundary in ["disable", "clear", "signOut"] {
            let provider = HeldLyrics()
            addTeardownBlock { await provider.requests.close() }
            let context = try makeContext(lyrics: provider)
            let model = context.model
            model.loadSelectedLyrics(for: F.tracks[0], recordingLanguage: "pa-Guru")
            let pending = try XCTUnwrap(model.lyricsSelectionTask)
            let request = try await provider.requests.request(at: 0)
            XCTAssertTrue(model.tvLyrics.start())
            switch boundary {
            case "disable": model.updatePreferences { $0.saveListeningHistory = false }
            case "clear": model.library.clearHistory()
            default: model.stopTVLyricsForSignOut()
            }
            XCTAssertNil(model.library.errorMessage)
            XCTAssertFalse(model.tvLyrics.isEnabled, boundary)
            XCTAssertFalse(model.tvLyrics.isPhonePresented, boundary)
            XCTAssertNil(model.lyricsSelection.selectedDocument, boundary)
            let response: Result<LyricsDocument, any Error> = boundary == "signOut"
                ? .failure(MusicServiceError.network("Retired sign-out request"))
                : .success(F.documents(for: F.tracks[0])[0])
            try await provider.requests.complete(request, with: response)
            await pending.value
            XCTAssertNil(model.tvLyrics.document, boundary)
            XCTAssertNil(model.lyricsSelection.selectedDocument, boundary)
            XCTAssertNil(model.lyricsSelection.variantMessage, boundary)
            guard case .loading = model.lyricsSelection.state else {
                XCTFail("\(boundary) must retire late successes and errors")
                continue
            }
        }
    }

    func testAsyncPlayerCheckpointLearnsMomentsOnlyAfterLibraryDurability() async throws {
        let gate = AsyncListeningCheckpointGate()
        addTeardownBlock { await gate.release() }
        let context = try makeContext(gate: gate)
        let model = context.model, player = model.player
        XCTAssertNotNil(player.onListeningCheckpoint)
        player.onListeningProgress = { _, _, _, _ in
            XCTFail("The integration must exercise the asynchronous model callback")
            return false
        }
        let events = F.recurringEvents(now: now)
        for event in events { XCTAssertTrue(player.enqueueListeningCheckpoint(event)) }
        player.flushListeningProgress()
        await gate.waitForEntry()
        XCTAssertTrue(model.library.events.isEmpty)
        XCTAssertTrue(model.momentMixes.store.snapshot.evidence.isEmpty)
        XCTAssertTrue(model.momentMixes.collections.isEmpty)

        await gate.release()
        await player.waitForListeningCheckpointDelivery()
        await model.momentMixes.waitForPendingPreparation()
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertEqual(Set(model.momentMixes.store.snapshot.evidence.map(\.eventID)), Set(events.map(\.id)))
        XCTAssertEqual(model.momentMixes.summaries.first?.days, 3)
        XCTAssertEqual(model.momentMixes.collections.first?.id, "moment.weekday.morning.general")
        XCTAssertEqual(Set(model.momentMixes.collections.first?.tracks.map(\.id) ?? []), Set(F.tracks.map(\.id)))
        let reopened = LibraryStore(directory: context.directory, now: { [now] in now })
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(Set(reopened.events.map(\.id)), Set(events.map(\.id)))
        XCTAssertEqual(reopened.lifetimeListeningSummary.seconds, 1_080)
        let savedMoments = MomentMixStore(persistence: MomentMixFilePersistence(url: context.momentsURL), now: now)
        XCTAssertEqual(savedMoments.snapshot.evidence, model.momentMixes.store.snapshot.evidence)

        player.flushListeningProgress()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertEqual(model.library.lifetimeListeningSummary.seconds, 1_080)
        XCTAssertEqual(model.momentMixes.store.snapshot.evidence.count, 3, "An unchanged flush cannot learn another session")
    }

    func testClearDuringAsyncCheckpointCannotRestoreMomentEvidenceOrLifetimeTime() async throws {
        let gate = AsyncListeningCheckpointGate()
        addTeardownBlock { await gate.release() }
        let context = try makeContext(gate: gate)
        let model = context.model
        for event in F.recurringEvents(now: now) { XCTAssertTrue(model.player.enqueueListeningCheckpoint(event)) }
        model.player.flushListeningProgress()
        await gate.waitForEntry()
        model.library.clearHistory()
        XCTAssertNil(model.library.errorMessage)
        await gate.release()
        await model.player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(model.player.pendingListeningCheckpoints.isEmpty)
        XCTAssertTrue(model.library.events.isEmpty)
        XCTAssertEqual(model.library.lifetimeListeningSummary.seconds, 0)
        XCTAssertTrue(model.momentMixes.store.snapshot.evidence.isEmpty)
        XCTAssertTrue(model.momentMixes.collections.isEmpty)
        let reopened = MomentMixStore(persistence: MomentMixFilePersistence(url: context.momentsURL), now: now)
        XCTAssertTrue(reopened.snapshot.evidence.isEmpty)
        XCTAssertEqual(reopened.snapshot.historyEpoch, model.library.listeningHistoryEpoch)
    }

    func testHistoryOffAcknowledgesWithoutLearningAndEnableDoesNotBackfill() async throws {
        let context = try makeContext()
        let model = context.model
        model.updatePreferences { $0.saveListeningHistory = false }
        for event in F.recurringEvents(now: now) { XCTAssertTrue(model.player.enqueueListeningCheckpoint(event)) }
        model.player.flushListeningProgress()
        await model.player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(model.player.pendingListeningCheckpoints.isEmpty)
        XCTAssertTrue(model.library.events.isEmpty)
        XCTAssertEqual(model.library.lifetimeListeningSummary.seconds, 0)
        XCTAssertFalse(model.momentMixes.store.canLearn)
        XCTAssertTrue(model.momentMixes.collections.isEmpty)

        model.updatePreferences { $0.saveListeningHistory = true }
        model.player.flushListeningProgress()
        await model.player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(model.momentMixes.store.canLearn)
        XCTAssertTrue(model.momentMixes.store.snapshot.evidence.isEmpty)
        XCTAssertTrue(model.momentMixes.collections.isEmpty)
        XCTAssertEqual(model.momentMixes.store.snapshot.learningSince, now)
    }

    func testLifetimeReceiptsFeedTheShareTotalWhileChartsAndMomentsUseRetainedEvents() async throws {
        let context = try makeContext()
        let model = context.model
        for index in 0..<40 {
            XCTAssertTrue(model.library.recordListening(track: F.expiredTrack, sessionID: UUID(),
                startedAt: now.addingTimeInterval(-500 * 86_400 + Double(index * 600)), seconds: 360))
        }
        for event in F.recurringEvents(now: now) { XCTAssertTrue(model.player.enqueueListeningCheckpoint(event)) }
        model.player.flushListeningProgress()
        await model.player.waitForListeningCheckpointDelivery()
        let reopened = LibraryStore(directory: context.directory, now: { [now] in now })
        let detail = ListeningAnalytics.allAvailableSummary(events: reopened.events, now: now, calendar: F.calendar)
        XCTAssertEqual(reopened.lifetimeListeningSummary.seconds, 15_480)
        XCTAssertEqual(reopened.lifetimeListeningSummary.plays, 43)
        XCTAssertEqual(detail.seconds, 1_080)
        XCTAssertEqual(Set(detail.topTracks.map { $0.track.id }), Set(F.tracks.map(\.id)))
        XCTAssertFalse(model.momentMixes.store.snapshot.evidence.contains { $0.trackID == F.expiredTrack.id })
        let card = RecapShareCardContent(summary: detail, window: .year, now: now,
            genres: ListeningGenreSummary(), languages: ListeningLanguageSummary(), allTime: true,
            lifetime: reopened.lifetimeListeningSummary)
        XCTAssertEqual(card.totalValue, "258")
        XCTAssertEqual(Set(card.songs.map(\.id)), Set(F.tracks.map(\.id)))
        XCTAssertTrue(card.rankingsUseRetainedHistory)
        XCTAssertEqual(card.coverageNote, RecapText.lifetimeDetailNote)
    }

    func testR17AudioFixturePublishesThreeVerifiedDownloadsAndReopensWithoutReplacingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("R17AudioIntegration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = DebugR17AudioResolver(directory: directory)
        async let first: Void = resolver.prepare()
        async let concurrent: Void = resolver.prepare()
        _ = try await (first, concurrent)
        let inventory = try await resolver.audioCacheSnapshot()
        let snapshot = try XCTUnwrap(inventory)
        XCTAssertEqual(snapshot.usage.downloadedSongCount, 3)
        XCTAssertEqual(snapshot.usage.songCount, 0)
        XCTAssertEqual(Set(snapshot.songs.map(\.id)), Set(F.tracks.map(\.id)))
        var originalBytes: [URL: Data] = [:]
        for track in F.tracks {
            let song = try XCTUnwrap(snapshot.songs.first { $0.id == track.id })
            let audio = try XCTUnwrap(song.preferredAudio)
            XCTAssertTrue(song.isDownloaded)
            XCTAssertTrue(song.isPlayable)
            XCTAssertTrue(audio.isDownloaded)
            XCTAssertEqual(audio.track, track)
            XCTAssertEqual(audio.quality?.codec, .aac)
            XCTAssertEqual(audio.url.deletingLastPathComponent().standardizedFileURL.path, resolver.cache.downloadsDirectory.path)
            let bytes = try Data(contentsOf: audio.url)
            XCTAssertEqual(Int64(bytes.count), audio.bytes)
            XCTAssertGreaterThan(audio.bytes, 0)
            let inspection = try await NativeAudioExport.inspect(audio.url)
            XCTAssertTrue(inspection.isAAC)
            XCTAssertEqual(inspection.duration, 360, accuracy: 1)
            originalBytes[audio.url] = bytes
        }
        let reopened = DebugR17AudioResolver(directory: directory)
        try await reopened.prepare()
        let reopenedInventory = try await reopened.audioCacheSnapshot()
        XCTAssertEqual(reopenedInventory?.usage.downloadedSongCount, 3)
        for (url, bytes) in originalBytes { XCTAssertEqual(try Data(contentsOf: url), bytes) }
    }

    private func load(_ track: Track, in model: MusicAppModel) async throws {
        model.loadSelectedLyrics(for: track, recordingLanguage: "pa-Guru")
        let task = try XCTUnwrap(model.lyricsSelectionTask)
        await task.value
        XCTAssertEqual(model.lyricsSelection.selectedDocument?.trackID, track.id)
    }

    private func makeContext(lyrics: any LyricsProviding = DebugR17Provider(), gate: AsyncListeningCheckpointGate? = nil)
        throws -> (model: MusicAppModel, directory: URL, momentsURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("R17Integration-\(UUID().uuidString)")
        let now = now
        let library = LibraryStore(directory: directory, now: { now }, beforeListeningCheckpointPreparation: {
            await gate?.enter(wasMainThread: checkpointPreparationIsOnMainThread())
        })
        library.preferences.useEncryptedDNS = false
        library.preferences.allowRemoteFallback = false
        library.preferences.autoplay = false
        library.updatePlayback(PlaybackSnapshot(queue: F.tracks, position: 32))
        let momentsURL = directory.appendingPathComponent("Moments/moments.json")
        let floor = try XCTUnwrap(F.recurringEvents(now: now).first).startedAt.addingTimeInterval(-1)
        let store = MomentMixStore(persistence: MomentMixFilePersistence(url: momentsURL), now: floor)
        XCTAssertTrue(store.synchronizePrivacy(historyEnabled: true, historyEpoch: library.listeningHistoryEpoch, now: floor))
        let moments = MomentMixController(store: store, now: { now }, calendar: { F.calendar })
        let resolver = AppModelStreamResolver()
        let player = PlayerController(resolver: resolver)
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let account = YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry())
        let model = MusicAppModel(library: library, player: player, catalog: DebugR17Provider(),
            charts: DebugR17Provider(), lyrics: lyrics, account: account, appIcons: AppIconController(enabled: false),
            recordingLanguageService: ArtistSpotlightLanguageService(provider: lyrics),
            songDetails: DebugTrackDetailsFixture.store(connectivity: connectivity), genreEvidence: GenreEvidenceStore(url: nil),
            connectivity: connectivity,
            youTubeImport: DebugYouTubeImportFixtureClient.makeImporter(library: library, account: account,
                directory: directory, fixture: true, seedLedger: false),
            momentMixes: moments, generatesMixes: false, asynchronousListeningCheckpoints: true)
        model.lyricLanguageLookup = { _ in "pa-Guru" }
        model.tvLyrics = TVLyricsController(track: { player.currentTrack }, position: { player.position },
            duration: { player.duration }, lyricsOffset: { library.lyricsOffset(for: $0) },
            idleTimer: TVLyricsIdleTimer(read: { false }, write: { _ in }))
        model.tvLyrics.setPhoneSceneActive(true)
        addTeardownBlock { @MainActor in
            await gate?.release()
            model.clearSelectedLyrics(reason: .privacy)
            stopAsyncCheckpointPlayer(player)
            await player.waitForListeningCheckpointDelivery()
            let requests = await resolver.streams.requests
            XCTAssertTrue(requests.isEmpty, "Model-only integration must never start audio extraction")
            await resolver.streams.close()
            try FileManager.default.removeItem(at: directory)
        }
        XCTAssertNil(library.errorMessage)
        return (model, directory, momentsURL)
    }

    private struct HeldLyrics: LyricsVariantsProviding {
        let requests = AppModelRequestGate<Track, LyricsDocument>()
        func lyrics(for track: Track) async throws -> LyricsDocument { try await requests.receive(track) }
        func lyricVariants(for track: Track) async throws -> [LyricsDocument] { F.documents(for: track) }
    }
}
