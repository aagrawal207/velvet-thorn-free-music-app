import XCTest
@testable import GanaBajana

@MainActor
final class AudioQualityTests: XCTestCase {
    private let track = Track(id: "fsiPzT50ZiM", title: "Quality fixture", duration: 8)
    private let lowQuality = SourceAudioQuality(codec: .heAAC, bitRate: 48_000, sampleRate: 22_050, channels: 2)
    private let highQuality = SourceAudioQuality(codec: .aac, bitRate: 128_000, sampleRate: 44_100, channels: 2)
    private let lowURL = URL(string: "https://audio.googlevideo.com/videoplayback?itag=139&dur=8&expire=4000000000")!
    private let highURL = URL(string: "https://audio.googlevideo.com/videoplayback?itag=140&dur=8&expire=4000000000")!

    func testValidAverageBitrateWinsAndInvalidValuesFallBackWithoutInventingQuality() throws {
        XCTAssertEqual(SourceAudioQuality.preferredBitRate(average: 128_000, advertised: 160_000), 128_000)
        let invalidRates: [Int?] = [nil, 0, -1, 1, Int.max]
        for invalid in invalidRates {
            XCTAssertEqual(SourceAudioQuality.preferredBitRate(average: invalid, advertised: 128_000), 128_000)
            XCTAssertNil(SourceAudioQuality.preferredBitRate(average: invalid, advertised: invalid))
        }
        let unknown = SourceAudioQuality(codec: .aac, bitRate: -1, sampleRate: 0, channels: 99)
        XCTAssertNil(unknown.bitRate)
        XCTAssertNil(unknown.sampleRate)
        XCTAssertNil(unknown.channels)
        XCTAssertEqual(unknown.summary, "AAC")
        XCTAssertTrue(highQuality.summary.contains("128 kbps AAC"))
        XCTAssertTrue(highQuality.summary.contains("Stereo"))
        XCTAssertTrue(lowQuality.summary.contains("48 kbps HE-AAC"))
        XCTAssertEqual(try JSONDecoder().decode(SourceAudioQuality.self, from: JSONEncoder().encode(highQuality)), highQuality)
        XCTAssertNil(ResolvedStream(url: highURL).quality)
        XCTAssertTrue(FastPathResult(urls: [highURL]).qualityByURL.isEmpty)
    }

    func testFastPathRanksAverageBitrateBeforePeakBitrate() throws {
        var misleadingPeak = format(url: lowURL, codec: .heAAC, bitRate: 200_000)
        misleadingPeak["averageBitrate"] = 48_000
        var best = format(url: highURL, bitRate: 140_000)
        best["averageBitrate"] = 128_000
        best["audioSampleRate"] = "44100"
        best["audioChannels"] = 2
        let result = try YouTubeAudioFastPath.audioResult(in: payload([misleadingPeak, best]), videoID: track.id)
        XCTAssertEqual(result.urls, [highURL])
        XCTAssertEqual(result.qualityByURL[highURL], highQuality)
        XCTAssertEqual(result.streams.first?.quality, highQuality)
    }

    func testChallengedBestAACNeverFallsBackToClearLowBitrateInTheFastPath() throws {
        let low = format(url: lowURL, codec: .heAAC, bitRate: 48_000)
        let best = format(url: highURL, bitRate: 128_000)
        var signature = best; signature["signatureCipher"] = "s=challenge"
        var cipher = best; cipher["cipher"] = "s=challenge"
        var n = best; n["url"] = highURL.absoluteString + "&n=challenge"
        var s = best; s["url"] = highURL.absoluteString + "&s=challenge"
        var missingURL = best; missingURL.removeValue(forKey: "url")
        var foreignHost = best; foreignHost["url"] = "https://example.invalid/audio?dur=8"
        var missingDuration = best; missingDuration["url"] = "https://audio.googlevideo.com/videoplayback"
        for unavailable in [signature, cipher, n, s, missingURL, foreignHost, missingDuration] {
            let result = try YouTubeAudioFastPath.audioResult(in: payload([low, unavailable]), videoID: track.id)
            XCTAssertTrue(result.urls.isEmpty, "A best-tier URL failure must reach the full extractor")
            XCTAssertTrue(result.qualityByURL.isEmpty)
        }
    }

    func testInvalidAverageFallsBackAnd256AACIsSelectedOnlyWhenAdvertised() throws {
        let available = URL(string: highURL.absoluteString + "&high=1")!
        let invalidAverages: [Any] = [0, -1, Int.max, "unknown"]
        for invalid in invalidAverages {
            var best = format(url: available, bitRate: 256_000)
            best["averageBitrate"] = invalid
            let result = try YouTubeAudioFastPath.audioResult(
                in: payload([format(url: highURL, bitRate: 128_000), best]), videoID: track.id)
            XCTAssertEqual(result.urls, [available])
            XCTAssertEqual(result.qualityByURL[available]?.bitRate, 256_000)
        }
        let ordinary = try YouTubeAudioFastPath.audioResult(
            in: payload([format(url: highURL, bitRate: 128_000)]), videoID: track.id)
        XCTAssertEqual(ordinary.qualityByURL[highURL]?.bitRate, 128_000)
    }

    func testOnlyOriginalAudioContributesToTheBestNativeTier() throws {
        let best = format(url: highURL, bitRate: 128_000)
        let other = format(url: lowURL, bitRate: 256_000)
        var video = other; video["mimeType"] = "video/mp4; codecs=\"avc1.64001f, mp4a.40.2\""
        var disguised = other; disguised["width"] = 1920
        var opus = other; opus["mimeType"] = "audio/webm; codecs=\"opus\""
        var foreign = other; foreign["audioTrack"] = ["displayName": "English", "audioIsDefault": true]
        var dubbed = other; dubbed["audioTrack"] = ["displayName": "English dubbed original"]
        var negative = other; negative["audioTrack"] = ["displayName": "not original"]
        var unknown = other; unknown["audioTrack"] = ["audioIsDefault": true]
        var malformed = other; malformed["audioTrack"] = "original"
        let result = try YouTubeAudioFastPath.audioResult(
            in: payload([video, disguised, opus, foreign, dubbed, negative, unknown, malformed, best]), videoID: track.id)
        XCTAssertEqual(result.urls, [highURL])
        for original in ["Hindi original", "Hindi (original)", "original"] {
            var named = best; named["audioTrack"] = ["displayName": original]
            XCTAssertEqual(try YouTubeAudioFastPath.audioURLs(in: payload([named]), videoID: track.id), [highURL])
        }
    }

    func testBestEquivalentURLsKeepTheirOwnMetadataAreDeduplicatedAndBounded() throws {
        var formats: [[String: Any]] = []
        for index in 0..<5 {
            let url = URL(string: highURL.absoluteString + "&variant=\(index)")!
            var value = format(url: url, bitRate: 128_000)
            value["audioSampleRate"] = index == 0 ? "44100" : "48000"
            value["audioChannels"] = index == 0 ? 1 : 2
            formats.append(value)
        }
        formats.insert(formats[0], at: 1)
        formats.append(format(url: lowURL, codec: .heAAC, bitRate: 48_000))
        let result = try YouTubeAudioFastPath.audioResult(in: payload(formats), videoID: track.id)
        XCTAssertEqual(result.urls.count, 3)
        XCTAssertEqual(Set(result.urls).count, 3)
        XCTAssertEqual(result.qualityByURL[result.urls[0]]?.sampleRate, 44_100)
        XCTAssertEqual(result.qualityByURL[result.urls[0]]?.channels, 1)
        XCTAssertEqual(result.qualityByURL[result.urls[1]]?.sampleRate, 48_000)
        XCTAssertEqual(result.qualityByURL[result.urls[1]]?.channels, 2)
        XCTAssertFalse(result.urls.contains(lowURL))
    }

    func testBestAvailable48AACStillWorksWhenNoHigherNativeTierIsAdvertised() throws {
        let result = try YouTubeAudioFastPath.audioResult(
            in: payload([format(url: lowURL, codec: .heAAC, bitRate: 48_000)]), videoID: track.id)
        XCTAssertEqual(result.urls, [lowURL])
        XCTAssertEqual(result.qualityByURL[lowURL]?.bitRate, 48_000)
        XCTAssertNil(result.qualityByURL[lowURL]?.sampleRate)
        XCTAssertNil(result.qualityByURL[lowURL]?.channels)
    }

    func testBlocked128AACInvokesFullExtractionAndPropagatesTheHigherQuality() async throws {
        var blocked = format(url: highURL, bitRate: 128_000)
        blocked["signatureCipher"] = "s=challenge"
        let fast = try YouTubeAudioFastPath.audioResult(
            in: payload([format(url: lowURL, codec: .heAAC, bitRate: 48_000), blocked]), videoID: track.id)
        let methods = CatalogTestRecorder<Bool>()
        let validations = CatalogTestRecorder<URL>()
        let fresh = ResolvedStream(url: highURL, quality: highQuality)
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { validations.record($0) },
            fastExtract: { _ in fast }, qualityExtract: { _, remote in methods.record(remote); return [fresh] })
        let resolved = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(methods.values, [false])
        XCTAssertEqual(validations.values, [highURL])
        XCTAssertEqual(resolved.url, highURL)
        XCTAssertEqual(resolved.quality, highQuality)
    }

    func testDirectBestTierCarriesQualityAndAvoidsFullExtraction() async throws {
        var best = format(url: highURL, bitRate: 128_000)
        best["audioSampleRate"] = "44100"
        best["audioChannels"] = 2
        let fast = try YouTubeAudioFastPath.audioResult(in: payload([best]), videoID: track.id)
        let full = CatalogTestRecorder<Bool>()
        let resolver = YouTubeStreamResolver(extract: { _, remote in full.record(remote); return [] }, validate: { _ in },
                                             fastExtract: { _ in fast })
        let resolved = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(resolved.quality, highQuality)
        XCTAssertEqual(resolved.loudnessDb, 2.5)
        XCTAssertEqual(resolved.viewCount, 42)
        XCTAssertTrue(full.values.isEmpty)
    }

    func testRejectedDirectBestTierDoesNotTryLowerDirectAAC() async throws {
        let fast = try YouTubeAudioFastPath.audioResult(
            in: payload([format(url: lowURL, codec: .heAAC, bitRate: 48_000), format(url: highURL, bitRate: 128_000)]), videoID: track.id)
        let resolvedURL = URL(string: highURL.absoluteString + "&resolved=1")!
        let fresh = ResolvedStream(url: resolvedURL, quality: highQuality)
        let rejected = highURL
        let validations = CatalogTestRecorder<URL>()
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { url in
            validations.record(url)
            if url == rejected { throw PlaybackStreamError.invalidMedia }
        }, fastExtract: { _ in fast }, qualityExtract: { _, _ in [fresh] })
        let result = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(result.url, resolvedURL)
        XCTAssertEqual(validations.values, [highURL, resolvedURL])
    }

    func testQualitySidecarRoundTripPreservesMediaBytesAndContainsNoSignedURL() async throws {
        let (fixture, data) = try cacheFixture()
        let source = ResolvedStream(url: highURL, duration: 8, quality: highQuality)
        let cached = try await fixture.cache.store(trackID: track.id, from: highURL, stream: source)
        XCTAssertEqual(try Data(contentsOf: cached.url), data)
        XCTAssertEqual(cached.quality, highQuality)
        XCTAssertEqual(cached.stream.quality, highQuality)
        let reopened = AudioCache(directory: fixture.cache.directory, session: fixture.mock.session)
        let entry = await reopened.entry(for: track.id)
        XCTAssertEqual(entry?.quality, highQuality)
        let sidecar = try Data(contentsOf: fixture.cache.directory.appendingPathComponent("\(track.id).json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecar) as? [String: Any])
        XCTAssertNotNil(json["quality"])
        XCTAssertFalse(String(decoding: sidecar, as: UTF8.self).contains("googlevideo"))
        XCTAssertFalse(String(decoding: sidecar, as: UTF8.self).contains("expire"))
        let usage = try await reopened.storageUsage()
        XCTAssertEqual(usage.bytes, Int64(data.count))
        XCTAssertEqual(usage.capacityBytes, 1 << 30)
    }

    func testLegacyAndMalformedOptionalQualityDoNotInvalidateWorkingCacheFiles() async throws {
        let (fixture, data) = try cacheFixture()
        let cached = try await fixture.cache.store(trackID: track.id, from: highURL, stream: ResolvedStream(url: highURL))
        let sidecarURL = fixture.cache.directory.appendingPathComponent("\(track.id).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
        XCTAssertNil(json["quality"])
        let legacy = await fixture.cache.entry(for: track.id)
        XCTAssertNil(legacy?.quality)
        let invalidQuality: [Any] = [NSNull(), "unknown", ["codec": "future-codec"], ["codec": "mp4a.40.2", "bitRate": "not a rate"]]
        for invalid in invalidQuality {
            json["quality"] = invalid
            try JSONSerialization.data(withJSONObject: json).write(to: sidecarURL, options: .atomic)
            let entry = await fixture.cache.entry(for: track.id)
            XCTAssertNotNil(entry)
            XCTAssertNil(entry?.quality)
            XCTAssertEqual(try Data(contentsOf: cached.url), data)
        }
    }

    func testKnown128CacheRemainsImmediateWithoutAutomaticNetworkChecks() async throws {
        let (fixture, _) = try cacheFixture()
        let cached = try await fixture.cache.store(trackID: track.id, from: highURL,
                                                   stream: ResolvedStream(url: highURL, quality: highQuality))
        let calls = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { id, _ in calls.record(id); throw URLError(.notConnectedToInternet) },
                                             validate: { _ in calls.record("validation") }, audioCache: fixture.cache)
        for forced in [false, true] {
            let result = try await resolver.resolve(track: track, forceRefresh: forced)
            XCTAssertEqual(result.url, cached.url)
            XCTAssertEqual(result.quality, highQuality)
        }
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testExplicitReloadEscapesLowCacheWithoutRewritingPinnedFiles() async throws {
        let (fixture, data) = try cacheFixture()
        let cached = try await fixture.cache.store(trackID: track.id, from: lowURL,
                                                   stream: ResolvedStream(url: lowURL, quality: lowQuality))
        let next = try fixture.seed("NJAv_7lHUIU")
        let outgoing = try fixture.seed("J7p4bzqLvCw")
        let nextBytes = try Data(contentsOf: next)
        let outgoingBytes = try Data(contentsOf: outgoing)
        await fixture.cache.pin(only: [track.id, "NJAv_7lHUIU", "J7p4bzqLvCw"])
        let fresh = ResolvedStream(url: highURL, quality: highQuality)
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in }, audioCache: fixture.cache,
                                             qualityExtract: { _, _ in [fresh] })
        let result = try await resolver.refreshQuality(track: track)
        XCTAssertEqual(result.url, highURL)
        XCTAssertEqual(result.quality, highQuality)
        XCTAssertEqual(try Data(contentsOf: cached.url), data)
        XCTAssertEqual(try Data(contentsOf: next), nextBytes)
        XCTAssertEqual(try Data(contentsOf: outgoing), outgoingBytes)
        let saved = await fixture.cache.entry(for: track.id)
        XCTAssertEqual(saved?.quality, lowQuality, "A source reload does not overwrite a pinned disk copy")
        let regular = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(regular.url, cached.url, "Ordinary playback retains its cache-first/offline behavior")
        XCTAssertEqual(fixture.mock.state.requests.count, 1, "The reload uses the source; it does not start a replacement writer")
    }

    func testExplicitReloadKeepsCachedAudioWhenOffline() async throws {
        let (fixture, data) = try cacheFixture()
        let cached = try await fixture.cache.store(trackID: track.id, from: lowURL,
                                                   stream: ResolvedStream(url: lowURL, quality: lowQuality))
        let resolver = YouTubeStreamResolver(extract: { _, _ in throw URLError(.notConnectedToInternet) },
                                             validate: { _ in }, audioCache: fixture.cache)
        let result = try await resolver.refreshQuality(track: track)
        XCTAssertEqual(result.url, cached.url)
        XCTAssertEqual(result.quality, lowQuality)
        XCTAssertEqual(try Data(contentsOf: result.url), data)
    }

    func testQualityReloadTimeoutIsBoundedAndReturnsTheWorkingCopy() async throws {
        let (fixture, data) = try cacheFixture()
        let cached = try await fixture.cache.store(trackID: track.id, from: lowURL, stream: ResolvedStream(url: lowURL))
        let resolver = YouTubeStreamResolver(timeout: 0.05, extract: { _, _ in
            try await Task.sleep(for: .seconds(10))
            return []
        }, validate: { _ in }, audioCache: fixture.cache)
        let start = ContinuousClock.now
        let result = try await resolver.refreshQuality(track: track)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(result.url, cached.url)
        XCTAssertEqual(try Data(contentsOf: cached.url), data)
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 0 }
    }

    func testCancelledQualityReloadDoesNotReturnOrInstallAnObsoleteCachedCopy() async throws {
        let (fixture, data) = try cacheFixture()
        let cached = try await fixture.cache.store(trackID: track.id, from: lowURL, stream: ResolvedStream(url: lowURL))
        let started = CatalogTestRecorder<Bool>()
        let resolver = YouTubeStreamResolver(extract: { _, _ in
            started.record(true)
            try await Task.sleep(for: .seconds(10))
            return []
        }, validate: { _ in }, audioCache: fixture.cache)
        let track = track
        let work = Task { try await resolver.refreshQuality(track: track) }
        defer { work.cancel() }
        try await PlaybackTestSupport.waitUntil { !started.values.isEmpty }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancellation must retire this playback intent") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: cached.url), data)
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 0 }
    }

    func testQualityReloadCannotDowngradeAKnownBetterSavedCopy() async throws {
        let (fixture, _) = try cacheFixture()
        let cached = try await fixture.cache.store(trackID: track.id, from: highURL,
                                                   stream: ResolvedStream(url: highURL, quality: highQuality))
        for quality in [lowQuality, highQuality, nil] {
            let candidate = ResolvedStream(url: lowURL, quality: quality)
            let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in }, audioCache: fixture.cache,
                                                 qualityExtract: { _, _ in [candidate] })
            let result = try await resolver.refreshQuality(track: track)
            XCTAssertEqual(result.url, cached.url)
            XCTAssertEqual(result.quality, highQuality)
        }
    }

    func testQualityReloadWithoutACachedFallbackSurfacesFailureAndRejectsInvalidIDs() async throws {
        let calls = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { id, _ in
            calls.record(id)
            throw URLError(.notConnectedToInternet)
        }, validate: { _ in })
        do { _ = try await resolver.refreshQuality(track: track); XCTFail("There is no file to fall back to") }
        catch { XCTAssertTrue(error is MusicServiceError) }
        do {
            _ = try await resolver.refreshQuality(track: Track(id: "bad/id", title: "Invalid"))
            XCTFail("Invalid identifiers must fail before extraction")
        } catch {
            guard case PlaybackStreamError.invalidID = error else { return XCTFail("Unexpected invalid-ID failure") }
        }
        XCTAssertEqual(calls.values, [track.id])
    }

    func testPlayerQualityFollowsTheInstalledStreamAndClearsOnSelectionChange() async throws {
        let url = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = PlaybackResolutionGate()
        addTeardownBlock { await gate.cancelRemaining() }
        let player = PlayerController(resolver: gate)
        defer { player.pause() }
        XCTAssertNil(player.sourceAudioQuality)
        player.play([track])
        let first = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
        await gate.finish(first, with: .success(ResolvedStream(url: url, duration: 8, quality: highQuality)))
        try await PlaybackTestSupport.waitUntil { player.sourceAudioQuality == self.highQuality }
        player.play([Track(id: "NJAv_7lHUIU", title: "Next")])
        XCTAssertNil(player.sourceAudioQuality)
        let next = try await PlaybackTestSupport.waitForRequests(2, on: gate)[1]
        await gate.finish(next, with: .success(ResolvedStream(url: url, duration: 8)))
        try await PlaybackTestSupport.waitUntil { player.currentStreamURL == url }
        XCTAssertNil(player.sourceAudioQuality, "Unknown source data must not inherit the previous track's quality")
    }

    func testPlayerQualityReloadUsesTheExplicitResolverPathAndRetainsTheOfflineFile() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { @MainActor in try await fixture.close() }
        let saved = try fixture.seed(track.id, seconds: 8)
        let savedBytes = try Data(contentsOf: saved)
        let replacement = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: replacement.deletingLastPathComponent()) }
        let fresh = ResolvedStream(url: replacement, quality: highQuality)
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in }, audioCache: fixture.cache,
                                             qualityExtract: { _, _ in [fresh] })
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.play([track])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.currentStreamURL == saved }
        XCTAssertNil(player.sourceAudioQuality)
        XCTAssertTrue(player.canReloadAudioQuality)
        player.retry(preferBestAudio: true)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.currentStreamURL == replacement }
        XCTAssertEqual(player.sourceAudioQuality, highQuality)
        XCTAssertEqual(try Data(contentsOf: saved), savedBytes)
    }

    private func format(url: URL, codec: SourceAudioQuality.Codec = .aac, bitRate: Int) -> [String: Any] {
        ["mimeType": "audio/mp4; codecs=\"\(codec.rawValue)\"", "bitrate": bitRate, "url": url.absoluteString]
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
