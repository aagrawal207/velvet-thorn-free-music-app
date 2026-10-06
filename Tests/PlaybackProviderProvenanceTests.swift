import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackProviderProvenanceTests: XCTestCase {
    nonisolated private static let gaana = Track(id: "gaana:944286", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Mithoon")], duration: 261)
    nonisolated private static let youtube = Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Mithoon")], duration: 261)
    nonisolated private static let quality = SourceAudioQuality(codec: .aac, bitRate: 128_000)
    nonisolated private static let remote = URL(string: "https://audio.googlevideo.com/file.wav?signature=PROVENANCE_SECRET&expire=4000000000")!

    func testSummaryUsesAcquisitionProviderWithoutChangingEncodingOrCatalogIdentity() {
        for source in MusicSource.allCases {
            let summary = SourceAudioQuality.playbackSummary(quality: Self.quality, catalogSource: .gaana, playbackSource: source)
            XCTAssertEqual(summary, "128 kbps AAC · " + (source == .gaana ? "Gaana" : "via \(source.title)"))
            XCTAssertFalse(summary.contains("lossless"))
        }
        XCTAssertEqual(SourceAudioQuality.playbackSummary(quality: nil, catalogSource: .gaana, playbackSource: nil),
                       "Quality information unavailable · Playback source unknown")
        XCTAssertEqual(SourceAudioQuality.playbackSummary(quality: Self.quality, catalogSource: .jioSaavn, playbackSource: .jioSaavn),
                       "128 kbps AAC · JioSaavn")
        XCTAssertEqual(Self.gaana.source, .gaana)
        XCTAssertEqual(Self.gaana.providerID, "944286")
        XCTAssertNil(ResolvedStream(url: Self.remote).playbackSource, "A signed URL host is not provenance")
    }

    func testNativeGaanaAndItsURLCacheReportGaana() async throws {
        let mock = GaanaTests.mock()
        defer { mock.close() }
        let resolver = GaanaStreamResolver(catalog: GaanaCatalogService(session: mock.session), probe: { _ in },
                                          now: { Date(timeIntervalSince1970: 1_790_420_000) })
        for _ in 0..<2 {
            let stream = try await resolver.resolve(track: Self.gaana, forceRefresh: false)
            XCTAssertEqual(stream.playbackSource, .gaana)
            XCTAssertEqual(stream.quality?.bitRate, 128_000)
            XCTAssertFalse(CompositeStreamResolver.isCacheable(stream))
        }
        XCTAssertEqual(mock.state.requests.count, 1)
    }

    func testGaanaFallbackRecordsOnlyTheAnsweringBranchAfterMissOrFailure() async throws {
        let mock = GaanaTests.mock(details: "gaana-song-detail-missing")
        defer { mock.close() }
        for firstFails in [false, true] {
            let calls = CatalogTestRecorder<MusicSource>()
            let first = ProvenanceFallback(source: .jioSaavn) {
                calls.record(.jioSaavn)
                if firstFails { throw PlaybackStreamError.noAudio }
                return nil
            }
            let second = ProvenanceFallback(source: .youTubeMusic) {
                calls.record(.youTubeMusic)
                return ResolvedStream(url: Self.remote, quality: Self.quality)
            }
            let resolver = GaanaStreamResolver(catalog: GaanaCatalogService(session: mock.session), fallbacks: [first, second])
            for _ in 0..<2 {
                let stream = try await resolver.resolve(track: Self.gaana, forceRefresh: false)
                XCTAssertEqual(stream.playbackSource, .youTubeMusic)
                XCTAssertEqual(stream.duration, 261)
                XCTAssertNil(stream.viewCount, "Gaana catalog counts must not fill fallback upload metadata")
                XCTAssertNil(stream.loudnessDb)
            }
            XCTAssertEqual(calls.values, [.jioSaavn, .youTubeMusic])
        }
        let calls = CatalogTestRecorder<MusicSource>()
        let resolver = GaanaStreamResolver(catalog: GaanaCatalogService(session: mock.session), fallbacks: [
            ProvenanceFallback(source: .jioSaavn) { calls.record(.jioSaavn); return ResolvedStream(url: Self.remote) },
            ProvenanceFallback(source: .youTubeMusic) { calls.record(.youTubeMusic); return nil },
        ])
        let stream = try await resolver.resolve(track: Self.gaana, forceRefresh: false)
        XCTAssertEqual(stream.playbackSource, .jioSaavn, "The answering branch wins even with a YouTube-looking URL")
        XCTAssertEqual(calls.values, [.jioSaavn])
    }

    func testLocalFallbackPreservesKnownSourceAndDoesNotInventLegacySource() async throws {
        let mock = GaanaTests.mock(details: "gaana-song-detail-missing")
        defer { mock.close() }
        for source in [nil, .youTubeMusic, .jioSaavn] as [MusicSource?] {
            let fallback = ProvenanceFallback(source: .youTubeMusic) {
                ResolvedStream(url: URL(fileURLWithPath: "/fixture/gaana~944286.m4a"), playbackSource: source)
            }
            let resolver = GaanaStreamResolver(catalog: GaanaCatalogService(session: mock.session), fallbacks: [fallback])
            let stream = try await resolver.resolve(track: Self.gaana, forceRefresh: false)
            XCTAssertEqual(stream.playbackSource, source)
        }
    }

    func testNormalSaavnAndYouTubePathsPopulateProvenance() async throws {
        let saavnMock = Self.saavnMock()
        defer { saavnMock.close() }
        let saavn = JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: saavnMock.session), probe: { _ in })
        for _ in 0..<2 {
            let stream = try await saavn.resolve(track: Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho"), forceRefresh: false)
            XCTAssertEqual(stream.playbackSource, .jioSaavn)
        }
        for fast in [false, true] {
            let fastExtract: YouTubeStreamResolver.FastExtraction? = fast ? { @Sendable _ in FastPathResult(urls: [Self.remote]) } : nil
            let resolver = YouTubeStreamResolver(extract: { _, _ in [Self.remote] }, validate: { _ in },
                                                 fastExtract: fastExtract)
            for _ in 0..<2 {
                let stream = try await resolver.resolve(track: Self.youtube, forceRefresh: false)
                XCTAssertEqual(stream.playbackSource, .youTubeMusic)
            }
            let plan = try await resolver.backgroundDownloadPlan(for: Self.youtube)
            XCTAssertEqual(plan.metadata.playbackSource, .youTubeMusic)
        }
        let remoteOnly = YouTubeStreamResolver(allowRemoteFallback: true, extract: { _, remote in
            if !remote { throw PlaybackStreamError.noAudio }
            return [Self.remote]
        }, validate: { _ in })
        let remoteStream = try await remoteOnly.resolve(track: Self.youtube, forceRefresh: false)
        XCTAssertEqual(remoteStream.playbackSource, .youTubeMusic)
    }

    func testProductionFallbackAdaptersPreserveResolverProvenance() async throws {
        let saavnMock = Self.saavnMock()
        defer { saavnMock.close() }
        let catalog = JioSaavnCatalogService(session: saavnMock.session)
        let saavn = JioSaavnStreamFallback(catalog: catalog, resolver: JioSaavnStreamResolver(catalog: catalog, probe: { _ in }))
        let live = try await saavn.resolve(matching: Self.gaana, forceRefresh: false)
        XCTAssertEqual(live?.playbackSource, .jioSaavn)
        for source in [nil, .youTubeMusic] as [MusicSource?] {
            let f = try CacheManagementFixture()
            addTeardownBlock { try await f.close() }
            let cache = Self.cache(root: f.root, session: f.mock.session)
            let stream = ResolvedStream(url: Self.remote, duration: 261, viewCount: 42, playbackSource: source)
            _ = try await cache.store(trackID: Self.youtube.id, from: stream.url, stream: stream, track: Self.youtube)
            let search = AppModelCatalogProvider()
            addTeardownBlock { await search.close() }
            await search.searches.enqueue(.success(CatalogPage(tracks: [Self.youtube])))
            let resolver = YouTubeStreamResolver(extract: { _, _ in XCTFail("The cache must answer"); return [] },
                                                 validate: { _ in }, audioCache: cache)
            let fallback = YouTubeStreamFallback(catalog: search, resolver: resolver)
            let cached = try await fallback.resolve(matching: Self.gaana, forceRefresh: false)
            XCTAssertEqual(cached?.playbackSource, source)
            XCTAssertEqual(cached?.viewCount, 42)
            XCTAssertEqual(cached?.url.isFileURL, true)
        }
    }

    func testSidecarDecodesLegacyNullUnknownAndMalformedSourceWithoutLosingOtherMetadata() throws {
        let sidecar = AudioCache.Sidecar(duration: 261, loudnessDb: 2, viewCount: 42, bytes: 128, storedAt: Date(), quality: Self.quality)
        let data = try JSONEncoder().encode(sidecar)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["playbackSource"])
        for value in [NSNull(), "futureProvider", 7, ["source": "youtube"]] as [Any] {
            json["playbackSource"] = value
            let decoded = try JSONDecoder().decode(AudioCache.Sidecar.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertNil(decoded.playbackSource)
            XCTAssertEqual(decoded.quality, Self.quality)
            XCTAssertEqual(decoded.viewCount, 42)
            XCTAssertEqual(decoded.loudnessDb, 2)
        }
        XCTAssertNil(try JSONDecoder().decode(AudioCache.Sidecar.self, from: data).playbackSource)
    }

    func testFallbackDownloadSurvivesRelaunchPromotionDemotionAndOfflineCompositeReaders() async throws {
        for source in [MusicSource.jioSaavn, .youTubeMusic] {
            let f = try CacheManagementFixture()
            addTeardownBlock { try await f.close() }
            let cache = Self.cache(root: f.root, session: f.mock.session)
            let gaanaMock = GaanaTests.mock(details: "gaana-song-detail-missing")
            let saavnMock = Self.saavnMock()
            defer { gaanaMock.close(); saavnMock.close() }
            let gaana = GaanaStreamResolver(catalog: GaanaCatalogService(session: gaanaMock.session), fallbacks: [
                ProvenanceFallback(source: source) { ResolvedStream(url: Self.remote, duration: 261, quality: Self.quality) },
            ])
            let composite = Self.composite(cache: cache, saavnMock: saavnMock, gaana: gaana)
            let plan = try await composite.backgroundDownloadPlan(for: Self.gaana)
            XCTAssertEqual(plan.stream.playbackSource, source)
            XCTAssertEqual(plan.metadata.playbackSource, source)
            let stored = try await composite.download(Self.gaana)
            XCTAssertEqual(stored.playbackSource, source)
            XCTAssertEqual(AudioCache.logicalTrackID(for: stored.url), Self.gaana.id)
            XCTAssertNil(stored.viewCount)
            let relaunched = Self.cache(root: f.root, session: f.mock.session)
            _ = try await relaunched.promoteToDownloads(Self.gaana.id)
            let downloaded = await relaunched.entry(for: Self.gaana.id)
            XCTAssertEqual(downloaded?.playbackSource, source)
            XCTAssertEqual(downloaded?.track?.id, Self.gaana.id)
            XCTAssertEqual(downloaded?.isDownloaded, true)
            let offline = Self.composite(cache: relaunched, saavnMock: saavnMock)
            await offline.setNetworkOffline(true)
            await offline.setAudioQualityPreference(.dataSaver)
            let played = try await offline.resolve(track: Self.gaana, forceRefresh: true)
            XCTAssertEqual(played.playbackSource, source)
            XCTAssertEqual(played.quality, Self.quality, "A ceiling must not relabel or downgrade saved bytes")
            let refreshed = try await offline.refreshQuality(track: Self.gaana)
            let reused = try await offline.download(Self.gaana)
            XCTAssertEqual(refreshed.playbackSource, source)
            XCTAssertEqual(reused.playbackSource, source)
            await relaunched.pin(Self.gaana.id)
            _ = try await relaunched.deleteDownload(Self.gaana.id)
            await relaunched.unpin(Self.gaana.id)
            let finalCache = Self.cache(root: f.root, session: f.mock.session)
            let demoted = await finalCache.entry(for: Self.gaana.id)
            XCTAssertEqual(demoted?.playbackSource, source)
            XCTAssertEqual(demoted?.isDownloaded, false)
            XCTAssertEqual(f.mock.state.requests.count, 1)
        }
    }

    func testLegacyCacheAndMissingDurationCopyKeepUnknownAndRejectUnrelatedDisplayMetadata() async throws {
        let f = try CacheManagementFixture()
        addTeardownBlock { try await f.close() }
        let cache = Self.cache(root: f.root, session: f.mock.session)
        let mismatched = Track(id: "saavn:other", title: "Unrelated", playCount: 999)
        let cases: [(String, MusicSource?)] = [(Self.gaana.id, nil), (Self.youtube.id, .youTubeMusic)]
        for (id, source) in cases {
            try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
            let key = AudioCache.storageKey(for: id)
            let data = PlaybackTestSupport.audioData(seconds: 1)
            try data.write(to: cache.directory.appendingPathComponent(key + ".wav"))
            let sidecar = AudioCache.Sidecar(bytes: Int64(data.count), storedAt: Date(), fileExtension: "wav",
                                            track: mismatched, playbackSource: source)
            try JSONEncoder().encode(sidecar).write(to: cache.directory.appendingPathComponent(key + ".json"))
            let prepared = try await cache.preparedEntry(for: id)
            XCTAssertEqual(prepared?.playbackSource, source)
            XCTAssertEqual(prepared?.stream.playbackSource, source)
            XCTAssertEqual(prepared?.duration, 1)
            XCTAssertNil(prepared?.track)
            XCTAssertNil(prepared?.viewCount)
            _ = try await cache.promoteToDownloads(id)
            _ = try await cache.demoteToCache(id)
        }
        let saavnMock = Self.saavnMock()
        defer { saavnMock.close() }
        let composite = Self.composite(cache: cache, saavnMock: saavnMock)
        await composite.setNetworkOffline(true)
        let legacy = try await composite.resolve(track: Self.gaana, forceRefresh: false)
        XCTAssertNil(legacy.playbackSource)
        let known = try await composite.resolve(track: Self.youtube, forceRefresh: false)
        XCTAssertEqual(known.playbackSource, .youTubeMusic)
        let unlabelled = Track(id: "NJAv_7lHUIU", title: "Legacy YouTube")
        let data = PlaybackTestSupport.audioData(seconds: 1)
        try data.write(to: cache.directory.appendingPathComponent(unlabelled.id + ".wav"))
        let sidecar = AudioCache.Sidecar(duration: 1, bytes: Int64(data.count), storedAt: Date(), fileExtension: "wav")
        try JSONEncoder().encode(sidecar).write(to: cache.directory.appendingPathComponent(unlabelled.id + ".json"))
        let unknownYouTube = try await composite.resolve(track: unlabelled, forceRefresh: false)
        XCTAssertNil(unknownYouTube.playbackSource, "Routing through YouTube cannot prove the source of old bytes")
    }

    func testBackgroundPlanQueueAndPublicationPreserveProviderAcrossRelaunch() async throws {
        for source in [nil, .jioSaavn, .youTubeMusic] as [MusicSource?] {
            let f = try CacheManagementFixture()
            addTeardownBlock { try await f.close() }
            let cache = Self.cache(root: f.root, session: f.mock.session)
            let plan = try BackgroundDownloadPlan(stream: ResolvedStream(url: Self.remote, duration: 1, playbackSource: source))
            var pending = BackgroundPendingDownload(id: Self.gaana.id)
            pending.phase = .staged
            pending.metadata = plan.metadata
            var queue = DownloadQueueRecord(trackIDs: [Self.gaana.id])
            queue.version = 2
            queue.pending = [pending]
            let file = f.root.appendingPathComponent("queue.json")
            try queue.save(to: file)
            let saved = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(saved.contains("PROVENANCE_SECRET"))
            XCTAssertFalse(saved.contains("googlevideo"))
            XCTAssertFalse(saved.contains("Tum Hi Ho"))
            let restored = try DownloadQueueRecord.read(from: file)
            let metadata = try XCTUnwrap(restored.pending?.first?.metadata)
            XCTAssertEqual(metadata.playbackSource, source)
            let staging = BackgroundDownloadStaging(directory: f.root.appendingPathComponent("Staging"))
            let payload = PlaybackTestSupport.audioData(seconds: 1)
            let input = f.root.appendingPathComponent("delivery.wav")
            try payload.write(to: input)
            let response = HTTPURLResponse(url: Self.remote, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"])!
            try staging.receive(input, token: pending.token, response: response, declaredBytes: nil)
            XCTAssertNil(try staging.load(pending.token)?.playbackSource, "Transport receipts do not infer the provider from the host")
            let publications = CatalogTestRecorder<MusicSource?>()
            let engine = BackgroundDownloadEngine(store: cache,
                planner: { _ in XCTFail("A staged delivery must not resolve again"); throw PlaybackStreamError.noAudio },
                publication: { track, part, metadata, fence in
                    publications.record(metadata.playbackSource)
                    try await cache.publishBackgroundDownload(track: track, part: part, metadata: metadata, fence: fence)
                }, promotion: { try await cache.promoteToDownloads($0, fence: $1) },
                session: ProvenanceRestoredSession(), staging: staging, queueFile: file,
                connectivity: ConnectivityMonitor(initialStatus: .online, monitorsSystem: false))
            addTeardownBlock { await engine.cancelAll() }
            await engine.restore { _ in [Self.gaana] }
            await engine.setForeground(true)
            for _ in 0..<300 {
                if await engine.items.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let remaining = await engine.items
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertEqual(publications.values, [source])
            let relaunched = Self.cache(root: f.root, session: f.mock.session)
            let audio = await relaunched.entry(for: Self.gaana.id)
            XCTAssertEqual(audio?.playbackSource, source)
            XCTAssertEqual(audio?.stream.playbackSource, source)
            XCTAssertEqual(audio?.isDownloaded, true)
            _ = try await relaunched.demoteToCache(Self.gaana.id)
            let demoted = await relaunched.entry(for: Self.gaana.id)
            XCTAssertEqual(demoted?.playbackSource, source)
        }
    }

    func testOpusForegroundUpgradeAndBackgroundPublicationKeepSource() async throws {
        let f = try CacheManagementFixture(handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"], data: OpusTestSupport.webM)
        })
        addTeardownBlock { try await f.close() }
        let cache = Self.cache(root: f.root, session: f.mock.session)
        let youtube = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in FastPathResult(urls: [OpusTestSupport.opusURL], qualityByURL: [OpusTestSupport.opusURL: OpusTestSupport.opusQuality]) },
            audioCache: cache, opusEnabled: true)
        let primary = try await youtube.resolve(track: Track(id: "NJAv_7lHUIU", title: "Native Opus", duration: 8), forceRefresh: false)
        XCTAssertEqual(primary.playbackSource, .youTubeMusic)
        XCTAssertTrue(primary.url.isFileURL)
        var stream = OpusTestSupport.source()
        stream.playbackSource = .youTubeMusic
        let permit = try await cache.writePermit()
        let first = try await cache.storeOpus(trackID: Self.gaana.id, stream: stream, permit: permit, foreground: true, track: Self.gaana)
        XCTAssertEqual(first.stream.playbackSource, .youTubeMusic)
        _ = try await cache.promoteToDownloads(Self.gaana.id)
        stream.quality = SourceAudioQuality(codec: .opus, bitRate: 256_000)
        stream.playbackSource = .jioSaavn
        let upgrade = try await cache.storeOpus(trackID: Self.gaana.id, stream: stream, permit: permit, foreground: true, track: Self.gaana)
        XCTAssertEqual(upgrade.playbackSource, .jioSaavn, "Adopting a new download encoding must carry its own provenance")
        XCTAssertTrue(upgrade.isDownloaded)
        let relaunched = Self.cache(root: f.root, session: f.mock.session)
        let saved = await relaunched.entry(for: Self.gaana.id)
        XCTAssertEqual(saved?.playbackSource, .jioSaavn)
        let partURL = f.root.appendingPathComponent("background.webm")
        try OpusTestSupport.webM.write(to: partURL)
        let part = AudioDownloader.Part(url: partURL, bytes: Int64(OpusTestSupport.webM.count), fileExtension: "webm")
        let metadata = AudioCache.Sidecar(duration: 8, bytes: part.bytes, storedAt: Date(), fileExtension: "webm",
                                          quality: OpusTestSupport.opusQuality, playbackSource: .youTubeMusic)
        try await relaunched.publishBackgroundDownload(track: Self.youtube, part: part, metadata: metadata, fence: DownloadPublicationFence())
        let background = await relaunched.entry(for: Self.youtube.id)
        XCTAssertEqual(background?.playbackSource, .youTubeMusic)
        XCTAssertEqual(background?.opusPreparationVersion, 1)
    }

    func testYouTubeDeferredOpusUpgradeCarriesAcquisitionProvider() async throws {
        let f = try CacheManagementFixture(handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"], data: OpusTestSupport.webM)
        })
        addTeardownBlock { try await f.close() }
        let cache = Self.cache(root: f.root, session: f.mock.session)
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in OpusTestSupport.fast() }, audioCache: cache, opusEnabled: true)
        let first = try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: false)
        XCTAssertEqual(first.quality?.codec, .aac)
        XCTAssertEqual(first.playbackSource, .youTubeMusic)
        let upgraded = try await resolver.download(OpusTestSupport.track)
        XCTAssertEqual(upgraded.quality?.codec, .opus)
        XCTAssertEqual(upgraded.playbackSource, .youTubeMusic)
        let relaunched = Self.cache(root: f.root, session: f.mock.session)
        let saved = await relaunched.entry(for: OpusTestSupport.track.id)
        XCTAssertEqual(saved?.playbackSource, .youTubeMusic)
    }

    func testKeepingAnExistingCopyDoesNotLeakFreshProviderOrDiagnosticMetadata() async throws {
        let f = try CacheManagementFixture()
        addTeardownBlock { try await f.close() }
        let cache = Self.cache(root: f.root, session: f.mock.session)
        let original = ResolvedStream(url: Self.remote, duration: 1, loudnessDb: 2, viewCount: 42,
                                      quality: SourceAudioQuality(codec: .aac, bitRate: 320_000), playbackSource: .jioSaavn)
        _ = try await cache.store(trackID: Self.gaana.id, from: original.url, stream: original, track: Self.gaana)
        let fresh = ResolvedStream(url: Self.remote, duration: 1, loudnessDb: 9, viewCount: 999,
                                   quality: Self.quality, playbackSource: .youTubeMusic)
        let mock = GaanaTests.mock(details: "gaana-song-detail-missing")
        let saavnMock = Self.saavnMock()
        defer { mock.close(); saavnMock.close() }
        let gaana = GaanaStreamResolver(catalog: GaanaCatalogService(session: mock.session), fallbacks: [
            ProvenanceFallback(source: .youTubeMusic) { fresh },
        ])
        let resolver = Self.composite(cache: cache, saavnMock: saavnMock, gaana: gaana)
        let refreshed = try await resolver.refreshQuality(track: Self.gaana)
        XCTAssertEqual(refreshed.playbackSource, .jioSaavn)
        XCTAssertEqual(refreshed.quality, original.quality)
        XCTAssertEqual(refreshed.viewCount, 42)
        XCTAssertEqual(refreshed.loudnessDb, 2)
        let partURL = f.root.appendingPathComponent("duplicate.wav")
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        try payload.write(to: partURL)
        let part = AudioDownloader.Part(url: partURL, bytes: Int64(payload.count), fileExtension: "wav")
        let metadata = try BackgroundDownloadPlan(stream: fresh).metadata
        try await cache.publishBackgroundDownload(track: Self.gaana, part: part, metadata: metadata, fence: DownloadPublicationFence())
        let kept = await cache.entry(for: Self.gaana.id)
        XCTAssertEqual(kept?.playbackSource, .jioSaavn)
        XCTAssertEqual(kept?.viewCount, 42)
        XCTAssertEqual(kept?.loudnessDb, 2)
        XCTAssertEqual(kept?.isDownloaded, true)
    }

    nonisolated private static func cache(root: URL, session: URLSession) -> AudioCache {
        AudioCache(directory: root.appendingPathComponent("ProvenanceAudio"), downloadsDirectory: root.appendingPathComponent("Downloads"),
                   session: session, opusPreparation: { try await OpusTestSupport.prepare(input: $0, output: $1) }, localDurationLoader: { _ in 1 })
    }

    nonisolated private static func composite(cache: AudioCache, saavnMock: CatalogMockSession, gaana: GaanaStreamResolver? = nil) -> CompositeStreamResolver {
        let youtube = YouTubeStreamResolver(extract: { _, _ in XCTFail("Unexpected extraction"); return [] }, validate: { _ in }, audioCache: cache)
        let saavn = JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: saavnMock.session), probe: { _ in })
        return CompositeStreamResolver(youTube: youtube, saavn: saavn, gaana: gaana, audioCache: cache)
    }

    nonisolated private static func saavnMock() -> CatalogMockSession {
        CatalogMockSession { request in
            let call = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "__call" }?.value
            let file = call == "search.getResults" ? "saavn-search-songs" : "saavn-song-details"
            let bundle = Bundle(for: PlaybackProviderProvenanceTests.self)
            let url = try XCTUnwrap(bundle.url(forResource: file, withExtension: "json")
                ?? bundle.url(forResource: file, withExtension: "json", subdirectory: "Fixtures"))
            return CatalogStub(data: try Data(contentsOf: url))
        }
    }
}

private struct ProvenanceFallback: CrossSourceStreamFallback {
    let source: MusicSource
    let answer: @Sendable () throws -> ResolvedStream?
    func resolve(matching track: Track, forceRefresh: Bool) async throws -> ResolvedStream? { try answer() }
}

private struct ProvenanceRestoredSession: BackgroundDownloadSession {
    let events = AsyncStream<BackgroundDownloadEvent> { $0.finish() }
    func allTasks() async -> [BackgroundDownloadTask] { [] }
    func create(_ request: URLRequest, token: UUID) -> Int { XCTFail("Staged bytes require no new transfer"); return -1 }
    func resume(_ id: Int) { XCTFail("No task to resume") }
    func cancel(_ id: Int) { }
}
