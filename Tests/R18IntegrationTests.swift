import AVFoundation
import ImageIO
import MediaToolbox
import UIKit
import UniformTypeIdentifiers
import XCTest
import YouTubeKit
@testable import GanaBajana

@MainActor
final class R18IntegrationTests: XCTestCase {
    private typealias F = DebugR18Fixture

    func testLiveSelectionRetiresPendingGeneratedRadioWithoutSongHistoryOrNavigation() async throws {
        let catalog = AppModelCatalogProvider()
        let music = PlaybackResolutionGate()
        let live = LiveRadioResolutionGate()
        addTeardownBlock { await catalog.close(); await music.cancelRemaining(); await live.cancelRemaining() }
        let player = PlayerController(resolver: music, liveRadioResolver: live)
        let model = context(player: player, catalog: catalog).model
        let saved = model.library.playback
        let pending = model.startRadio(try XCTUnwrap(RadioExperience.stations.first), languages: [.english])
        let search = try await catalog.searches.request(at: 0)
        XCTAssertTrue(model.playLiveRadio(F.stations[0]))
        try await catalog.searches.complete(search, with: .success(CatalogPage(tracks: F.tracks)))
        await catalog.close()
        await pending.value
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        player.handleLifecycleCheckpoint()
        await player.waitForListeningCheckpointDelivery()

        XCTAssertEqual(player.liveStation, F.stations[0])
        XCTAssertNil(player.currentTrack)
        XCTAssertFalse(player.isRadioSession)
        XCTAssertFalse(model.isLoadingRadio)
        XCTAssertNil(model.radioError)
        XCTAssertFalse(model.isPlayerPresented, "A directory selection must leave presentation to the mini-player tap")
        XCTAssertTrue(model.library.events.isEmpty)
        XCTAssertTrue(model.library.recentlyPlayed.isEmpty)
        XCTAssertEqual(model.library.lifetimeListeningSummary.seconds, 0)
        XCTAssertEqual(model.library.playback.queue, saved.queue)
        XCTAssertEqual(model.library.playback.position, saved.position)
        let requests = await music.requests
        XCTAssertTrue(requests.isEmpty)
        player.stopLiveRadio()
        XCTAssertEqual(player.currentTrack, saved.queue.first)
        XCTAssertEqual(player.position, 12)
        XCTAssertFalse(player.isPlaying)
    }

    func testNewMusicSelectionRejectsLateLiveConnectionThroughIntegratedModel() async throws {
        let music = PlaybackResolutionGate()
        let live = LiveRadioResolutionGate()
        addTeardownBlock { await music.cancelRemaining(); await live.cancelRemaining() }
        let player = PlayerController(resolver: music, liveRadioResolver: live)
        let model = context(player: player).model
        XCTAssertTrue(model.playLiveRadio(F.stations[0]))
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        let pending = await live.requests[0]
        XCTAssertTrue(model.play(F.tracks[1], in: F.tracks))
        let request = try await PlaybackTestSupport.waitForRequests(1, on: music)[0]
        await music.finish(request, with: .failure(MusicServiceError.unavailable("Selected fixture song failed")))
        try await PlaybackTestSupport.waitUntil { player.errorMessage == "Selected fixture song failed" }
        await live.finish(pending, result: .success(LiveRadioConnection(station: F.stations[0], streamingURL: F.stations[0].streamingURL)))
        await Task.yield()
        XCTAssertNil(player.liveStation)
        XCTAssertEqual(player.currentTrack, F.tracks[1])
        XCTAssertNil(player.currentStreamURL)
        XCTAssertEqual(player.errorMessage, "Selected fixture song failed")
        XCTAssertTrue(model.library.events.isEmpty)
    }

    func testDirectoryNPRFiltersAndDurableFavoritesNeverBecomeLocalSongLikes() async throws {
        let context = context(player: PlayerController(resolver: PlaybackResolutionGate()))
        let model = context.model
        await model.liveRadio.search(.npr, isOffline: false)
        XCTAssertNil(model.liveRadio.errorMessage)
        XCTAssertEqual(model.liveRadio.stations, [F.stations[0]], "NPR tag matching must find the affiliate without NPR in its name")
        XCTAssertTrue(model.liveRadio.favorites.toggle(F.stations[0]))
        let reopened = LiveRadioFavorites(url: context.root.appendingPathComponent("live-radio-favorites.json"))
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.stations, [F.stations[0]])
        XCTAssertTrue(model.library.favorites.isEmpty)
        XCTAssertTrue(model.library.events.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        await model.liveRadio.search(LiveRadioFilter(name: "Jazz", countryCode: "GB", language: "english", tags: "jazz"), isOffline: false)
        XCTAssertNil(model.liveRadio.errorMessage)
        XCTAssertEqual(model.liveRadio.stations, [F.stations[1]])
        await model.liveRadio.search(LiveRadioFilter(name: "Jazz", countryCode: "GB", language: "english", tags: "jazz"), isOffline: true)
        XCTAssertTrue(model.liveRadio.favorites.contains(F.stations[0]))
    }

    func testAccountDefaultOffExplicitLikeReceiptAndReconnectNeverChangeLocalHeart() async throws {
        let account = YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry())
        let client = DebugR18WriteClient()
        let model = context(player: PlayerController(resolver: PlaybackResolutionGate()), account: account, client: client).model
        let write = model.youTubeWrite
        XCTAssertFalse(write.canAuthorize)
        XCTAssertFalse(write.allowsChanges)
        write.perform(.like, track: F.tracks[1], context: write.context)
        var calls = await client.actions
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        let firstBinding = try XCTUnwrap(account.session?.writeSessionID)
        XCTAssertTrue(write.canAuthorize)
        XCTAssertFalse(write.allowsChanges)
        let oldContext = write.context
        write.setAllowsChanges(true)
        write.perform(.like, track: F.tracks[1], context: oldContext)
        calls = await client.actions
        XCTAssertTrue(calls.isEmpty, "An old page cannot borrow permission from a later opt-in")
        write.perform(.like, track: F.tracks[0], context: write.context)
        calls = await client.actions
        XCTAssertTrue(calls.isEmpty, "A fallback source cannot authorize a write for a Gaana catalog ID")
        write.perform(.like, track: F.tracks[1], context: write.context)
        try await PlaybackTestSupport.waitUntil { !write.isBusy && write.message == "Confirmed on YouTube." }
        calls = await client.actions
        XCTAssertEqual(calls, [.like])
        let targets = await client.targets
        XCTAssertEqual(targets, [F.tracks[1].id])
        XCTAssertFalse(model.library.isFavorite(F.tracks[1]))
        XCTAssertTrue(model.library.events.isEmpty)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        XCTAssertNotEqual(account.session?.writeSessionID, firstBinding)
        XCTAssertFalse(write.allowsChanges)
        XCTAssertFalse(model.library.isFavorite(F.tracks[1]))
    }

    func testCurrentAndStandbyKeepTheirOwnProvenanceAndNativeNormalizationAcrossPreferenceEdits() async throws {
        let root = directory()
        let firstURL = root.appendingPathComponent("first.wav"), secondURL = root.appendingPathComponent("second.wav")
        try PlaybackTestSupport.audioData(seconds: 15).write(to: firstURL)
        try PlaybackTestSupport.audioData(seconds: 15).write(to: secondURL)
        let resolver = PlaybackResolutionGate()
        addTeardownBlock { await resolver.cancelRemaining() }
        var standbyPlayer: AVPlayer?
        var standbyItem: AVPlayerItem?
        let player = PlayerController(resolver: resolver, standbyPreroll: { native, completion in
            standbyPlayer = native
            standbyItem = native.currentItem
            completion(true)
        })
        let model = context(player: player).model
        model.updatePreferences {
            $0.gaplessPlayback = true
            $0.crossfadeSeconds = 0
            $0.automix = false
            $0.normalizeVolume = true
        }
        XCTAssertTrue(model.play(F.tracks[0], in: F.tracks))
        let first = try await PlaybackTestSupport.waitForRequests(1, on: resolver)[0]
        await resolver.finish(first, with: .success(ResolvedStream(url: firstURL, duration: 15, loudnessDb: -3, playbackSource: .jioSaavn)))
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.equalizerStatus.normalizationFrames > 0 }
        XCTAssertEqual(player.playbackSource, .jioSaavn)
        XCTAssertEqual(player.normalizationGain, 1.4125375, accuracy: 0.000001)
        XCTAssertFalse(player.equalizerSettings.isEnabled)
        let second = try await PlaybackTestSupport.waitForRequests(2, on: resolver)[1]
        XCTAssertEqual(second.trackID, F.tracks[1].id)
        await resolver.finish(second, with: .success(ResolvedStream(url: secondURL, duration: 15, loudnessDb: -6, playbackSource: .youTubeMusic)))
        try await PlaybackTestSupport.waitUntil { player.isStandbyReady && player.equalizerStatus.attached == 2 }
        let incoming = try XCTUnwrap(standbyPlayer)
        let item = try XCTUnwrap(standbyItem)
        let tap = try XCTUnwrap(item.audioMix?.inputParameters.first?.audioTapProcessor)
        let processor = Unmanaged<EqualizerProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        model.updatePreferences { $0.normalizeVolume = false }
        XCTAssertEqual(player.normalizationGain, 1)
        model.updatePreferences { $0.normalizeVolume = true }
        XCTAssertEqual(player.normalizationGain, 1.4125375, accuracy: 0.000001)
        XCTAssertTrue(player.isStandbyReady)
        XCTAssertTrue(incoming.currentItem === item)
        XCTAssertEqual(player.duration, 15, accuracy: 0.01)
        // With Crossfade off, manual Next resolves again; the native end-of-item path adopts the gapless deck.
        player.seek(to: player.duration - 2)
        try await PlaybackTestSupport.waitUntil {
            player.currentTrack == F.tracks[1] && player.isPlaying && processor.normalizationFrames.load(ordering: .relaxed) > 0
        }
        let requests = await resolver.requests
        XCTAssertEqual(requests.map(\.trackID), [F.tracks[0].id, F.tracks[1].id], "Gapless adoption must not resolve the prepared song again")
        XCTAssertEqual(player.activePlayerIdentity, ObjectIdentifier(incoming))
        XCTAssertTrue(incoming.currentItem === item)
        XCTAssertEqual(incoming.volume, 1, "The tap owns gain-up; AVPlayer receives attenuation only")
        XCTAssertNil(player.crossfadeState)
        XCTAssertEqual(player.playbackSource, .youTubeMusic)
        XCTAssertEqual(player.normalizationGain, 1.9952623, accuracy: 0.000001)
        XCTAssertEqual(processor.renderedNormalizationGainDb.load(ordering: .relaxed), 6, accuracy: 0.01)
        XCTAssertTrue(item.audioMix?.inputParameters.first?.audioTapProcessor === tap)
        XCTAssertNil(player.errorMessage)
    }

    func testCachedAACCannotConfirmStagedExtractorRulesAndRelaunchRecoversBundled() async throws {
        let context = context()
        let model = context.model
        let resolver = try XCTUnwrap(model.player.resolver as? DebugR18AudioResolver)
        try await resolver.prepare()
        let center = model.extractorUpdates
        center.start()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let file = context.root.appendingPathComponent("candidate.json")
        try F.manualPackage().write(to: file)
        await center.prepareImport(from: file)
        let candidate = try XCTUnwrap(center.pendingID)
        XCTAssertFalse(center.pendingPublisherVerified)
        center.activatePending(id: candidate, trustingManualSource: false)
        XCTAssertNil(center.activeRevision)
        center.activatePending(id: candidate, trustingManualSource: true)
        XCTAssertEqual(center.activeRevision, 1)
        XCTAssertNotNil(model.player.onFreshExtractionPlayed)
        let cached = try await resolver.resolve(track: F.tracks[1], forceRefresh: false)
        XCTAssertNil(cached.extractionGeneration)
        XCTAssertTrue(model.play(F.tracks[1], in: [F.tracks[1]]))
        try await PlaybackTestSupport.waitUntil { model.player.isPlaying && model.player.position > 1 }
        XCTAssertTrue(center.needsPlaybackConfirmation, "Real local playback must not certify a candidate's extraction rules")
        model.player.pause()
        let reopened = ExtractorUpdateCenter(directory: context.root.appendingPathComponent("ExtractorUpdates"))
        reopened.start()
        XCTAssertNil(reopened.activeRevision)
        XCTAssertTrue(reopened.recoveredUnconfirmed)
        XCTAssertEqual(reopened.highestRevision, 1)
    }

    func testFallbackCacheReopensWithActualSourceQualityAndNilExtractionEvidence() async throws {
        let root = directory()
        let resolver = DebugR18AudioResolver(directory: root)
        let initial = try await resolver.resolve(track: F.tracks[0], forceRefresh: false)
        let bytes = try Data(contentsOf: initial.url)
        let reopened = DebugR18AudioResolver(directory: root)
        let saved = try await reopened.resolve(track: F.tracks[0], forceRefresh: true)
        XCTAssertEqual(saved.playbackSource, .jioSaavn)
        XCTAssertEqual(saved.quality, initial.quality)
        XCTAssertEqual(saved.quality?.codec, .aac)
        XCTAssertNil(saved.extractionGeneration)
        XCTAssertEqual(try Data(contentsOf: saved.url), bytes)
        XCTAssertEqual(F.tracks[0].source, .gaana)
        let inspection = try await NativeAudioExport.inspect(saved.url)
        XCTAssertTrue(inspection.isAAC)
        XCTAssertEqual(inspection.duration, 360, accuracy: 1)
    }

    func testPNGAndJPEGLoaderToAACExportPreserveEmbeddedCoverAndSharePreview() async throws {
        let root = directory()
        let input = root.appendingPathComponent("tone.wav")
        try PlaybackTestSupport.audioData(seconds: 2).write(to: input)
        let audio = try await DebugFixtureAudio.exportAAC(from: input, to: root.appendingPathComponent("source.m4a"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            UIColor.orange.setFill(); context.fill(CGRect(x: 16, y: 32, width: 64, height: 96))
        }
        for (mime, bytes) in [("image/png", try XCTUnwrap(image.pngData())), ("image/jpeg", try XCTUnwrap(image.jpegData(compressionQuality: 0.9)))] {
            let mock = CatalogMockSession { _ in CatalogStub(headers: ["Content-Type": mime], data: bytes) }
            let loader = ArtworkLoader(session: mock.session)
            addTeardownBlock { _ = await loader.clearCache(); mock.close() }
            var track = F.tracks[1]
            track.artworkURL = URL(string: "https://r18-artwork.invalid/cover")!
            let loaded = try await AudioExportArtworkResolver.resolve(for: track, loader: loader)
            let cover = try XCTUnwrap(loaded)
            let cachedCover = try await AudioExportArtworkResolver.resolve(for: track, loader: loader)
            XCTAssertEqual(cachedCover, cover)
            XCTAssertEqual(mock.state.requests.count, 1)
            let source = CachedAudio(trackID: track.id, url: audio.url, duration: audio.duration, loudnessDb: nil, viewCount: nil,
                bytes: AudioExporter.size(of: audio.url), storedAt: Date(), quality: audio.quality)
            let result = try await AudioExporter(directory: root.appendingPathComponent(UUID().uuidString))
                .export(track: track, source: source, artwork: cover)
            XCTAssertFalse(result.transcoded)
            let inspection = try await NativeAudioExport.inspect(result.url)
            XCTAssertTrue(inspection.isAAC)
            XCTAssertEqual(inspection.duration, 2, accuracy: 0.05)
            let metadata = try await AVURLAsset(url: result.url).load(.metadata)
            let item = try XCTUnwrap(AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataCoverArt).first)
            let embeddedValue = try await item.load(.dataValue)
            let embedded = try XCTUnwrap(embeddedValue)
            XCTAssertEqual(embedded, cover)
            XCTAssertEqual(result.artworkJPEG, embedded)
            let decoded = try XCTUnwrap(CGImageSourceCreateWithData(embedded as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(decoded) as String?, UTType.jpeg.identifier)
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
            let share = AudioExportShareSource(export: result, title: track.title)
            let controller = UIActivityViewController(activityItems: [share], applicationActivities: nil)
            XCTAssertEqual(share.activityViewController(controller, itemForActivityType: .mail) as? URL, result.url)
            let provider = try XCTUnwrap(share.activityViewControllerLinkMetadata(controller)?.imageProvider)
            let preview: Data = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? AudioExportError.invalidArtwork) }
                }
            }
            XCTAssertEqual(preview, embedded)
        }
    }

    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("R18Integration-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func context(player: PlayerController? = nil, account: YouTubeAccountStore? = nil,
                         client: DebugR18WriteClient = DebugR18WriteClient(), catalog: (any MusicCatalogProviding)? = nil)
        -> (model: MusicAppModel, root: URL) {
        let root = directory()
        let model = F.makeModel(directory: root, initializingStore: true, player: player, account: account,
                                writeClient: client, catalog: catalog)
        addTeardownBlock { @MainActor in
            model.youTubeWrite.shutdown()
            model.extractorUpdates.cancel()
            model.clearSelectedLyrics(reason: .privacy)
            model.player.stopLiveRadio()
            model.player.pause()
            await model.player.waitForListeningCheckpointDelivery()
            if let resolver = model.player.resolver as? DebugR18AudioResolver { await resolver.shutdown() }
        }
        XCTAssertNil(model.library.errorMessage)
        return (model, root)
    }
}
