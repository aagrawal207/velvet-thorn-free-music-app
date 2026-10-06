import XCTest
@testable import GanaBajana

@MainActor
final class AudioQualityPreferenceTests: XCTestCase {
    private let track = Track(id: "fsiPzT50ZiM", title: "Quality preference fixture", duration: 8)
    private let aac48 = SourceAudioQuality(codec: .heAAC, bitRate: 48_000, sampleRate: 22_050, channels: 2)
    private let aac128 = SourceAudioQuality(codec: .aac, bitRate: 128_000, sampleRate: 44_100, channels: 2)
    private let aac256 = SourceAudioQuality(codec: .aac, bitRate: 256_000, sampleRate: 44_100, channels: 2)
    private let aac320 = SourceAudioQuality(codec: .aac, bitRate: 320_000, sampleRate: 44_100, channels: 2)
    private let opus160 = SourceAudioQuality(codec: .opus, bitRate: 160_000, sampleRate: 48_000, channels: 2)
    private let opus256 = SourceAudioQuality(codec: .opus, bitRate: 256_000, sampleRate: 48_000, channels: 2)
    private let url48 = URL(string: "https://audio.googlevideo.com/videoplayback?itag=139&dur=8&expire=4000000000")!
    private let url128 = URL(string: "https://audio.googlevideo.com/videoplayback?itag=140&dur=8&expire=4000000000")!
    private let url256 = URL(string: "https://audio.googlevideo.com/videoplayback?itag=141&dur=8&expire=4000000000")!
    private let opusURL160 = URL(string: "https://audio.googlevideo.com/videoplayback?itag=251&dur=8&expire=4000000000")!
    private let opusURL256 = URL(string: "https://audio.googlevideo.com/videoplayback?itag=774&dur=8&expire=4000000000")!

    // MARK: Shared selection helper

    func testRankedKeepsFittingFormatsFirstThenTheClosestHigherOnesThenUnknownBitrates() {
        let unknown = SourceAudioQuality(codec: .aac)
        let offered: [SourceAudioQuality?] = [aac128, opus160, unknown, aac256, aac48]
        XCTAssertEqual(rank(offered, cap: nil), [aac256, opus160, aac128, aac48, unknown], "Best keeps today's order")
        XCTAssertEqual(rank(offered, cap: AudioQualityPreference.balanced.maximumBitRate), [opus160, aac128, aac48, aac256, unknown])
        XCTAssertEqual(rank(offered, cap: AudioQualityPreference.dataSaver.maximumBitRate), [aac48, aac128, opus160, aac256, unknown])
        XCTAssertEqual(rank([aac256, aac128], cap: 64_000), [aac128, aac256], "Nothing fits: the lowest offered plays first")
        let opus128 = SourceAudioQuality(codec: .opus, bitRate: 128_000)
        XCTAssertEqual(rank([opus128, aac128], cap: 64_000), [aac128, opus128], "AAC still beats Opus on ties above the ceiling")
        XCTAssertEqual(rank([opus128, aac128], cap: 160_000), [aac128, opus128])
        XCTAssertEqual(rank([unknown, aac48], cap: 64_000), [aac48, unknown], "An unknown bitrate cannot prove it fits")
        XCTAssertEqual(rank([], cap: 64_000), [])
    }

    func testFitsTreatsMissingCeilingsAndUnknownBitratesAsAllowed() {
        XCTAssertTrue(SourceAudioQuality.fits(aac320, maximumBitRate: nil))
        XCTAssertTrue(SourceAudioQuality.fits(nil, maximumBitRate: 64_000))
        XCTAssertTrue(SourceAudioQuality.fits(SourceAudioQuality(codec: .aac), maximumBitRate: 64_000))
        XCTAssertTrue(SourceAudioQuality.fits(aac48, maximumBitRate: 64_000))
        XCTAssertFalse(SourceAudioQuality.fits(aac128, maximumBitRate: 64_000))
        XCTAssertTrue(SourceAudioQuality.fits(opus160, maximumBitRate: 160_000))
    }

    func test256KilobitFormatsAreValidAndPreferredUnderBestWithAACAheadOfOpusOnTies() throws {
        XCTAssertEqual(SourceAudioQuality.validBitRate(256_000), 256_000)
        XCTAssertEqual(SourceAudioQuality.preferredBitRate(average: 262_144, advertised: 271_000), 262_144)
        XCTAssertEqual(SourceAudioQuality(codec: .opus, bitRate: 262_144).summary, "262 kbps Opus")
        XCTAssertTrue(SourceAudioQuality.prefers(aac256, over: opus160))
        XCTAssertTrue(SourceAudioQuality.prefers(opus256, over: opus160))
        XCTAssertTrue(SourceAudioQuality.prefers(aac256, over: opus256))
        XCTAssertEqual(rank([opus160, aac128, opus256, aac256], cap: nil), [aac256, opus256, opus160, aac128])
        let formats = [format(url: url128, quality: aac128), format(url: opusURL160, quality: opus160),
                       format(url: opusURL256, quality: opus256), format(url: url256, quality: aac256)]
        let best = try YouTubeAudioFastPath.audioResult(in: payload(formats), videoID: track.id, allowOpus: true)
        XCTAssertEqual(best.urls, [url256])
        XCTAssertEqual(best.qualityByURL[url256], aac256)
        XCTAssertEqual(best.aacFallbacks.map(\.url), [url256])
        let opusOnly = try YouTubeAudioFastPath.audioResult(
            in: payload([format(url: url128, quality: aac128), format(url: opusURL256, quality: opus256)]),
            videoID: track.id, allowOpus: true)
        XCTAssertEqual(opusOnly.urls, [opusURL256], "A Premium Opus tier wins when no equal AAC exists")
        XCTAssertEqual(opusOnly.aacFallbacks.map(\.url), [url128])
    }

    // MARK: Fast path

    func testFastPathBestTierIsTheBestFormatUnderTheCeilingForOpusAndAAC() throws {
        let formats = [format(url: url48, quality: aac48), format(url: url128, quality: aac128),
                       format(url: opusURL160, quality: opus160), format(url: url256, quality: aac256)]
        let data = try payload(formats)
        let best = try YouTubeAudioFastPath.audioResult(in: data, videoID: track.id, allowOpus: true)
        XCTAssertEqual(best.urls, [url256])
        let balanced = try YouTubeAudioFastPath.audioResult(in: data, videoID: track.id, allowOpus: true, maximumBitRate: 160_000)
        XCTAssertEqual(balanced.urls, [opusURL160])
        XCTAssertEqual(balanced.streams.first?.quality, opus160)
        XCTAssertEqual(balanced.aacFallbacks.map(\.url), [url128], "The AAC fallback is also the best AAC under the ceiling")
        let balancedAAC = try YouTubeAudioFastPath.audioResult(in: data, videoID: track.id, allowOpus: false, maximumBitRate: 160_000)
        XCTAssertEqual(balancedAAC.urls, [url128])
        let saver = try YouTubeAudioFastPath.audioResult(in: data, videoID: track.id, allowOpus: true, maximumBitRate: 64_000)
        XCTAssertEqual(saver.urls, [url48])
        XCTAssertEqual(saver.qualityByURL[url48], aac48)
        XCTAssertEqual(saver.aacFallbacks.map(\.url), [url48])
        XCTAssertEqual(saver.loudnessDb, 2.5)
        XCTAssertEqual(saver.viewCount, 42)
    }

    func testFastPathWithNothingUnderTheCeilingTakesTheLowestOfferedFormat() throws {
        let data = try payload([format(url: url256, quality: aac256), format(url: url128, quality: aac128),
                                format(url: opusURL160, quality: opus160)])
        let saver = try YouTubeAudioFastPath.audioResult(in: data, videoID: track.id, allowOpus: true, maximumBitRate: 64_000)
        XCTAssertEqual(saver.urls, [url128])
        XCTAssertEqual(saver.aacFallbacks.map(\.url), [url128])
        let opusOnly = try payload([format(url: opusURL160, quality: opus160), format(url: url256, quality: aac256)])
        let result = try YouTubeAudioFastPath.audioResult(in: opusOnly, videoID: track.id, allowOpus: true, maximumBitRate: 64_000)
        XCTAssertEqual(result.urls, [opusURL160], "160 kbps Opus is the closest to a 64 kbps ceiling")
        XCTAssertEqual(result.aacFallbacks.map(\.url), [url256], "The AAC fallback is the lowest AAC offered")
    }

    func testFastPathDoesNotSwapAChallengedFittingFormatForAClearHigherOne() throws {
        var challenged = format(url: url48, quality: aac48)
        challenged["signatureCipher"] = "s=challenge"
        let data = try payload([challenged, format(url: url128, quality: aac128)])
        let saver = try YouTubeAudioFastPath.audioResult(in: data, videoID: track.id, maximumBitRate: 64_000)
        XCTAssertTrue(saver.urls.isEmpty, "Full extraction can solve the challenge and keep the ceiling")
        XCTAssertTrue(saver.aacFallbacks.isEmpty)
        let best = try YouTubeAudioFastPath.audioResult(in: data, videoID: track.id)
        XCTAssertEqual(best.urls, [url128], "Without a ceiling the clear 128 kbps format is the best tier")
    }

    // MARK: Resolver selection

    func testResolverPicksTheHighestFormatUnderTheCeilingAndBestKeepsTodaysChoice() async throws {
        let offered = [ResolvedStream(url: url256, quality: aac256), ResolvedStream(url: url48, quality: aac48),
                       ResolvedStream(url: url128, quality: aac128), ResolvedStream(url: opusURL160, quality: opus160)]
        let expectations: [(AudioQualityPreference, URL, SourceAudioQuality)] = [
            (.best, url256, aac256), (.balanced, url128, aac128), (.dataSaver, url48, aac48),
        ]
        for (preference, expectedURL, expectedQuality) in expectations {
            let validations = CatalogTestRecorder<URL>()
            let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { validations.record($0) },
                                                 qualityExtract: { _, _ in offered })
            await resolver.setAudioQualityPreference(preference)
            let resolved = try await resolver.resolve(track: track, forceRefresh: false)
            XCTAssertEqual(resolved.url, expectedURL, preference.rawValue)
            XCTAssertEqual(resolved.quality, expectedQuality, preference.rawValue)
            XCTAssertEqual(validations.values, [expectedURL], "Opus stays skipped without native support; only the pick is checked")
        }
    }

    func testResolverWithNothingUnderTheCeilingPlaysTheLowestAndClimbsWhenThatFails() async throws {
        let offered = [ResolvedStream(url: url256, quality: aac256), ResolvedStream(url: url128, quality: aac128)]
        let lowest = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in }, qualityExtract: { _, _ in offered })
        await lowest.setAudioQualityPreference(.dataSaver)
        let resolved = try await lowest.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(resolved.url, url128)

        let validations = CatalogTestRecorder<URL>()
        let broken = url48
        let withBroken = offered + [ResolvedStream(url: url48, quality: aac48)]
        let climbing = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { url in
            validations.record(url)
            if url == broken { throw PlaybackStreamError.invalidMedia }
        }, qualityExtract: { _, _ in withBroken })
        await climbing.setAudioQualityPreference(.dataSaver)
        let climbed = try await climbing.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(climbed.url, url128, "A broken fitting format yields to the next higher one rather than failing the song")
        XCTAssertEqual(validations.values, [url48, url128])
    }

    func testResolverAppliesTheCeilingToPrebuiltFastPathResults() async throws {
        let fast = FastPathResult(urls: [url256], loudnessDb: 2.5, viewCount: 42, qualityByURL: [url256: aac256],
                                  aacFallbacks: [ResolvedStream(url: url128, loudnessDb: 2.5, viewCount: 42, quality: aac128)])
        let validations = CatalogTestRecorder<URL>()
        let full = CatalogTestRecorder<Bool>()
        let resolver = YouTubeStreamResolver(extract: { _, remote in full.record(remote); return [] },
                                             validate: { validations.record($0) }, fastExtract: { _ in fast })
        await resolver.setAudioQualityPreference(.balanced)
        let resolved = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(resolved.url, url128)
        XCTAssertEqual(resolved.quality, aac128)
        XCTAssertEqual(resolved.loudnessDb, 2.5, "Fast-path metadata survives the capped pick")
        XCTAssertEqual(validations.values, [url128])
        XCTAssertTrue(full.values.isEmpty)
    }

    func testCompleteCachedCopyAboveTheCeilingStillPlaysWithoutAnyNetworkWork() async throws {
        let (fixture, data) = try cacheFixture()
        let cached = try await fixture.cache.store(trackID: track.id, from: url256,
                                                   stream: ResolvedStream(url: url256, quality: aac320))
        let calls = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { id, _ in calls.record(id); throw URLError(.notConnectedToInternet) },
                                             validate: { _ in calls.record("validation") }, audioCache: fixture.cache)
        await resolver.setAudioQualityPreference(.dataSaver)
        for forced in [false, true] {
            let result = try await resolver.resolve(track: track, forceRefresh: forced)
            XCTAssertEqual(result.url, cached.url)
            XCTAssertEqual(result.quality, aac320, "Bytes already on this device play whatever the ceiling")
        }
        let downloaded = try await resolver.download(track)
        XCTAssertEqual(downloaded.url, cached.url)
        XCTAssertEqual(try Data(contentsOf: cached.url), data)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testQualityReloadHonoursTheCeilingAndKeepsAHigherSavedCopy() async throws {
        let (fixture, _) = try cacheFixture()
        let cached = try await fixture.cache.store(trackID: track.id, from: url128,
                                                   stream: ResolvedStream(url: url128, quality: aac128))
        let validations = CatalogTestRecorder<URL>()
        let offered = [ResolvedStream(url: url256, quality: aac256), ResolvedStream(url: url48, quality: aac48)]
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { validations.record($0) },
                                             audioCache: fixture.cache, qualityExtract: { _, _ in offered })
        await resolver.setAudioQualityPreference(.dataSaver)
        let result = try await resolver.refreshQuality(track: track)
        XCTAssertEqual(result.url, cached.url, "The capped fresh pick is lower than the saved copy, so the copy stays")
        XCTAssertEqual(result.quality, aac128)
        XCTAssertEqual(validations.values, [url48], "The reload validated only the format under the ceiling")

        await resolver.setAudioQualityPreference(.best)
        let best = try await resolver.refreshQuality(track: track)
        XCTAssertEqual(best.url, url256, "Best available reloads to the highest offered format")
        XCTAssertEqual(best.quality, aac256)
        XCTAssertEqual(validations.values, [url48, url256])
    }

    func testQualityReloadReplacesALowerSavedCopyWithTheBestFormatUnderTheCeiling() async throws {
        let (fixture, data) = try cacheFixture()
        let cached = try await fixture.cache.store(trackID: track.id, from: url48,
                                                   stream: ResolvedStream(url: url48, quality: aac48))
        let validations = CatalogTestRecorder<URL>()
        let offered = [ResolvedStream(url: url256, quality: aac256), ResolvedStream(url: url128, quality: aac128)]
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { validations.record($0) },
                                             audioCache: fixture.cache, qualityExtract: { _, _ in offered })
        await resolver.setAudioQualityPreference(.balanced)
        let result = try await resolver.refreshQuality(track: track)
        XCTAssertEqual(result.url, url128)
        XCTAssertEqual(result.quality, aac128)
        XCTAssertEqual(validations.values, [url128])
        XCTAssertEqual(try Data(contentsOf: cached.url), data, "A reload never rewrites the saved file")
        let regular = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(regular.url, cached.url, "Ordinary playback stays cache-first")
    }

    // MARK: In-memory URL cache

    func testPreferenceChangeRetiresURLEntriesAboveTheNewCeilingOrChosenUnderATighterOne() async throws {
        let extractions = CatalogTestRecorder<String>()
        let offered = [ResolvedStream(url: url256, quality: aac256), ResolvedStream(url: url128, quality: aac128),
                       ResolvedStream(url: url48, quality: aac48)]
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
                                             qualityExtract: { id, _ in extractions.record(id); return offered })
        let best = try await resolvedURL(resolver)
        let reused = try await resolvedURL(resolver)
        XCTAssertEqual([best, reused], [url256, url256])
        XCTAssertEqual(extractions.values.count, 1, "An unexpired signed URL is reused under the same preference")

        await resolver.setAudioQualityPreference(.balanced)
        let balanced = try await resolvedURL(resolver)
        XCTAssertEqual(balanced, url128, "256 kbps exceeds the new ceiling")
        XCTAssertEqual(extractions.values.count, 2)

        await resolver.setAudioQualityPreference(.dataSaver)
        let saver = try await resolvedURL(resolver)
        XCTAssertEqual(saver, url48)
        XCTAssertEqual(extractions.values.count, 3)

        await resolver.setAudioQualityPreference(.balanced)
        let loosened = try await resolvedURL(resolver)
        XCTAssertEqual(loosened, url128, "An entry chosen under a tighter ceiling could hide a better format and is not reused")
        XCTAssertEqual(extractions.values.count, 4)

        await resolver.setAudioQualityPreference(.best)
        let bestAgain = try await resolvedURL(resolver)
        XCTAssertEqual(bestAgain, url256)
        XCTAssertEqual(extractions.values.count, 5)
        await resolver.setAudioQualityPreference(.best)
        let unchanged = try await resolvedURL(resolver)
        XCTAssertEqual(unchanged, url256)
        XCTAssertEqual(extractions.values.count, 5, "Re-applying the same preference keeps the cache")
    }

    func testPreferenceChangeKeepsURLEntriesThatStillFitAndWereChosenWithoutATighterCeiling() async throws {
        let extractions = CatalogTestRecorder<String>()
        let only128 = [ResolvedStream(url: url128, quality: aac128)]
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
                                             qualityExtract: { id, _ in extractions.record(id); return only128 })
        let best = try await resolvedURL(resolver)
        XCTAssertEqual(best, url128)
        await resolver.setAudioQualityPreference(.balanced)
        let balanced = try await resolvedURL(resolver)
        XCTAssertEqual(balanced, url128)
        XCTAssertEqual(extractions.values.count, 1, "A Best pick that fits the new ceiling is still the best choice under it")
        await resolver.setAudioQualityPreference(.dataSaver)
        let saver = try await resolvedURL(resolver)
        XCTAssertEqual(saver, url128, "Nothing lower exists, so the reload lands on the same format")
        XCTAssertEqual(extractions.values.count, 2)
        let reused = try await resolvedURL(resolver)
        XCTAssertEqual(reused, url128)
        XCTAssertEqual(extractions.values.count, 2, "The ceiling that produced a nothing-fits pick reuses its signed URL")
    }

    // MARK: Model fan-out

    func testPreferenceEditsAndSavedLibraryReloadsReachTheResolver() async throws {
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in })
        let context = try AppModelTestContext(resolver: resolver)
        addTeardownBlock { @MainActor in try await context.close() }
        let initial = await resolver.audioQualityPreference
        XCTAssertEqual(initial, .best)
        XCTAssertEqual(context.library.preferences.audioQuality, .best)

        context.model.updatePreferences { $0.audioQuality = .dataSaver }
        XCTAssertEqual(context.library.preferences.audioQuality, .dataSaver)
        try await PlaybackTestSupport.eventually { await resolver.audioQualityPreference == .dataSaver }

        let external = LibraryStore(directory: context.directory)
        var preferences = external.preferences
        preferences.audioQuality = .balanced
        external.preferences = preferences
        XCTAssertNil(external.errorMessage)
        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        XCTAssertEqual(context.library.preferences.audioQuality, .balanced)
        try await PlaybackTestSupport.eventually { await resolver.audioQualityPreference == .balanced }
    }

    func testStartupAppliesTheSavedPreferenceBeforeTheFirstResolution() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajana-AudioQualityPreference-\(UUID())", isDirectory: true)
        let seed = LibraryStore(directory: directory)
        var preferences = seed.preferences
        preferences.audioQuality = .dataSaver
        preferences.useEncryptedDNS = false
        seed.preferences = preferences
        XCTAssertNil(seed.errorMessage)

        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in })
        let library = LibraryStore(directory: directory)
        XCTAssertEqual(library.preferences.audioQuality, .dataSaver)
        let player = PlayerController(resolver: resolver)
        let catalog = AppModelCatalogProvider()
        let charts = AppModelChartsProvider()
        let lyrics = AppModelLyricsProvider()
        let languageService = ArtistSpotlightLanguageService(provider: lyrics)
        let model = MusicAppModel(library: library, player: player, catalog: catalog, charts: charts, lyrics: lyrics,
                                  account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                  recordingLanguageService: languageService,
                                  languageDiscovery: ListeningLanguageDiscovery(service: languageService), generatesMixes: false)
        addTeardownBlock { @MainActor in
            model.cancelPendingRadio()
            model.deactivateDeviceServices()
            player.pause()
            await catalog.close()
            await charts.charts.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try await PlaybackTestSupport.eventually { await resolver.audioQualityPreference == .dataSaver }
    }

    // MARK: Helpers

    private func resolvedURL(_ resolver: YouTubeStreamResolver) async throws -> URL {
        try await resolver.resolve(track: track, forceRefresh: false).url
    }

    private func rank(_ qualities: [SourceAudioQuality?], cap: Int?) -> [SourceAudioQuality?] {
        SourceAudioQuality.ranked(qualities, maximumBitRate: cap) { $0 }
    }

    private func format(url: URL, quality: SourceAudioQuality) -> [String: Any] {
        var value: [String: Any] = ["url": url.absoluteString, "bitrate": (quality.bitRate ?? 0) + 10_000,
                                    "averageBitrate": quality.bitRate ?? 0, "audioChannels": quality.channels ?? 2]
        value["mimeType"] = quality.codec == .opus ? "audio/webm; codecs=\"opus\"" : "audio/mp4; codecs=\"\(quality.codec.rawValue)\""
        if let sampleRate = quality.sampleRate { value["audioSampleRate"] = "\(sampleRate)" }
        return value
    }

    private func payload(_ formats: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "playabilityStatus": ["status": "OK"], "videoDetails": ["videoId": track.id, "viewCount": "42"],
            "playerConfig": ["audioConfig": ["loudnessDb": 2.5]], "streamingData": ["adaptiveFormats": formats],
        ])
    }

    private func cacheFixture() throws -> (CacheManagementFixture, Data) {
        // Storage tests need a recognizable container prefix, not an encoder or network recording.
        let data = Data([0, 0, 0, 24]) + Data("ftypdash".utf8) + Data(repeating: 7, count: 256)
        let fixture = try CacheManagementFixture(capacityBytes: 1 << 30, handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/mp4", "Content-Length": "\(data.count)"], data: data)
        }, localDurationLoader: { _ in 8 })
        addTeardownBlock { @MainActor in try await fixture.close() }
        return (fixture, data)
    }
}
