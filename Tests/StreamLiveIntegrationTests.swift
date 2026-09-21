import AVFoundation
import XCTest
@testable import GanaBajana

final class StreamLiveIntegrationTests: XCTestCase {
    func testLiveMediaTransportProbe() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_MEDIA_TRANSPORT_PROBE"] == "1")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let opus = try await YouTubeAudioFastPath.extract(videoID: "fsiPzT50ZiM")
        let source = try XCTUnwrap(opus.streams.first(where: { $0.quality?.codec == .opus }))
        let report = NSMutableArray()
        for range in ["bytes=0-1048575", "bytes=1048576-2097151"] {
            let start = ContinuousClock.now
            var request = URLRequest(url: source.url)
            request.httpShouldHandleCookies = false
            request.setValue(range, forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            do {
                let (data, response) = try await session.data(for: request)
                report.add(["range": range, "bytes": data.count, "status": (response as? HTTPURLResponse)?.statusCode ?? 0,
                            "contentRange": (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? "",
                            "elapsed": String(describing: start.duration(to: .now))])
            } catch {
                report.add(["range": range, "error": (error as NSError).domain, "code": (error as NSError).code,
                            "elapsed": String(describing: start.duration(to: .now))])
            }
        }
        let result = try await YouTubeAudioFastPath.extract(videoID: "J7p4bzqLvCw")
        let aac = try XCTUnwrap((result.streams + result.aacFallbacks).first(where: { $0.quality?.codec != .opus }))
        for userAgent in [nil, "Mozilla/5.0", "Breezy/1.0"] as [String?] {
            let asset = AVURLAsset(url: aac.url, options: userAgent.map { [AVURLAssetHTTPUserAgentKey: $0] })
            defer { asset.cancelLoading() }
            do {
                let count = try await PlaybackDeadline.run(seconds: 10) { try await asset.loadTracks(withMediaType: .audio).count }
                report.add(["userAgent": userAgent ?? "default", "audioTracks": count])
            } catch {
                let error = error as NSError
                let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                report.add(["userAgent": userAgent ?? "default", "error": error.domain, "code": error.code,
                            "underlyingCode": underlying?.code ?? 0])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "media-transport-probe"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func requireLiveTests() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set GANABAJANA_LIVE_TESTS=1 to exercise public YouTube extraction.")
        }
    }

    func testLiveClearOpusSourcePreparesAndDecodesWithItsOriginalCodec() async throws {
        try requireLiveTests()
        guard OpusNativeAudio.isSupported else { throw XCTSkip("Opus preparation is enabled on iOS 26.5 and later.") }
        let id = "fsiPzT50ZiM"
        let fast = try await YouTubeAudioFastPath.extract(videoID: id)
        guard let source = fast.streams.first(where: { $0.quality?.codec == .opus }) else {
            throw XCTSkip("The provider did not offer a clear, selected Opus source for this recording.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BreezyLiveOpus-\(UUID())", isDirectory: true)
        let cache = AudioCache(directory: directory)
        addTeardownBlock {
            await cache.pin(only: [])
            _ = try await cache.clearUnused()
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        await cache.pin(id)
        let permit = try await cache.writePermit()
        let prepared = try await PlaybackDeadline.run(seconds: 20) {
            try await cache.storeOpus(trackID: id, stream: source, permit: permit, foreground: true)
        }
        let native = try await OpusNativeAudio.inspect(prepared.url)
        XCTAssertEqual(prepared.quality?.codec, .opus)
        XCTAssertEqual(prepared.quality?.bitRate, source.quality?.bitRate)
        XCTAssertEqual(native.sampleRate, 48_000)
        XCTAssertGreaterThan(native.decodedFrames, 0)
        XCTAssertGreaterThan(prepared.bytes, 1_000_000)
        print("OPUS LIVE recording=\(id) quality=\(prepared.quality?.summary ?? "unknown") bytes=\(prepared.bytes) decodedFrames=\(native.decodedFrames)")
    }

    func testPublicHindiAndEnglishTracksHaveValidatedNativeStreams() async throws {
        try requireLiveTests()
        let resolver = YouTubeStreamResolver()
        for id in ["fsiPzT50ZiM", "NJAv_7lHUIU", "J7p4bzqLvCw"] {
            var track = Track(id: id, title: id)
            track.isAudioRecording = true
            let stream = try await resolver.resolve(track: track, forceRefresh: true)
            if stream.url.isFileURL {
                XCTAssertTrue(resolver.isCachedStream(stream))
                XCTAssertNil(stream.expiresAt)
                if stream.quality?.codec == .opus {
                    let inspection = try await OpusNativeAudio.inspect(stream.url)
                    XCTAssertGreaterThan(inspection.decodedFrames, 0)
                }
            } else {
                XCTAssertEqual(stream.url.scheme, "https")
                XCTAssertTrue(stream.url.host?.hasSuffix(".googlevideo.com") == true)
                XCTAssertGreaterThan(try XCTUnwrap(stream.expiresAt).timeIntervalSinceNow, 30)
            }
            XCTAssertGreaterThan(try XCTUnwrap(stream.duration), 0)
            let asset = AVURLAsset(url: stream.url)
            defer { asset.cancelLoading() }
            let counts: (Int, Int)
            do {
                counts = try await PlaybackDeadline.run(seconds: 20) {
                    let audio = try await asset.loadTracks(withMediaType: .audio)
                    let video = try await asset.loadTracks(withMediaType: .video)
                    return (audio.count, video.count)
                }
            } catch {
                let error = error as NSError
                let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                throw MusicServiceError.network("Native media load failed: \(error.domain)(\(error.code)), underlying \(underlying?.code ?? 0).")
            }
            XCTAssertEqual(counts.0, 1)
            XCTAssertEqual(counts.1, 0)
            let loudness = stream.loudnessDb.map { String($0) } ?? "nil"
            let views = stream.viewCount.map { String($0) } ?? "nil"
            print("STREAM LIVE \(id): duration=\(stream.duration ?? 0) quality=\(stream.quality?.summary ?? "unknown") cached=\(stream.url.isFileURL) loudnessDb=\(loudness) viewCount=\(views)")
        }
    }

    /// The cache's real HTTP path against a public AAC sample: streaming download, `clen` verification, MP4 sniffing,
    /// sidecar, cache-first resolution with a resolver whose network paths all fail, and AVFoundation reading the file.
    func testLiveCacheDownloadsAPublicM4AAndServesItWithoutTheNetwork() async throws {
        try requireLiveTests()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajanaLiveAudioCache-\(UUID())", isDirectory: true)
        addTeardownBlock { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
        // filesamples.com serves this 2,034,429-byte file chunked (no Content-Length); `clen` carries the size as googlevideo does.
        let remote = try XCTUnwrap(URL(string: "https://filesamples.com/samples/audio/m4a/sample1.m4a?clen=2034429&dur=122.093"))
        let cache = AudioCache(directory: directory)
        let track = Track(id: "sample1m4a_", title: "Public sample", duration: 122)
        let started = ContinuousClock.now
        let stored = try await cache.store(trackID: track.id, from: remote, stream: ResolvedStream(url: remote, duration: 122.093, loudnessDb: -1.5, viewCount: 12))
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(stored.bytes, 2_034_429)
        XCTAssertEqual(stored.url.pathExtension, "m4a")
        XCTAssertEqual(stored.duration ?? 0, 122.093, accuracy: 0.001)
        let sidecar = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("\(track.id).json"))) as? [String: Any]
        XCTAssertEqual(sidecar?["bytes"] as? Int64, 2_034_429)
        XCTAssertEqual(try XCTUnwrap(sidecar?["duration"] as? Double), 122.093, accuracy: 0.001)
        XCTAssertEqual(sidecar?["viewCount"] as? Int64, 12)
        let asset = AVURLAsset(url: stored.url)
        let assetDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(assetDuration, 122.09, accuracy: 0.5, "AVFoundation reads the cached file as a complete AAC recording")
        print("STREAM LIVE cache download public m4a: bytes=\(stored.bytes) assetDuration=\(assetDuration) elapsed=\(elapsed)")

        let offline = CatalogMockSession { _ in throw URLError(.notConnectedToInternet) }
        defer { offline.close() }
        let offlineResolver = YouTubeStreamResolver(extract: { _, _ in throw URLError(.notConnectedToInternet) },
                                                    validate: { _ in throw URLError(.notConnectedToInternet) },
                                                    fastExtract: { _ in throw URLError(.notConnectedToInternet) },
                                                    audioCache: AudioCache(directory: directory, session: offline.session))
        let again = ContinuousClock.now
        let cached = try await offlineResolver.resolve(track: track, forceRefresh: true)
        let hit = again.duration(to: .now)
        XCTAssertEqual(cached.url, stored.url)
        XCTAssertEqual(cached.duration ?? 0, 122.093, accuracy: 0.001)
        XCTAssertEqual(cached.loudnessDb, -1.5)
        XCTAssertEqual(cached.viewCount, 12)
        XCTAssertNil(cached.expiresAt)
        XCTAssertTrue(offlineResolver.isCachedStream(cached))
        XCTAssertLessThan(hit, .milliseconds(50), "A cache hit is a local file stat, not a network round trip")
        print("STREAM LIVE cache hit public m4a: \(hit)")
    }

    func testLiveDownloadCachesAWholeSongAndServesItWithoutTheNetwork() async throws {
        try requireLiveTests()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajanaLiveAudioCache-\(UUID())", isDirectory: true)
        addTeardownBlock { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
        let cache = AudioCache(directory: directory)
        let resolver = YouTubeStreamResolver(extract: { _, _ in throw PlaybackStreamError.noAudio },
                                             validate: { try await StreamValidation.validate(url: $0) },
                                             fastExtract: { try await YouTubeAudioFastPath.extract(videoID: $0) }, audioCache: cache)
        var track = Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho")
        track.isAudioRecording = true
        let started = ContinuousClock.now
        let stream: ResolvedStream
        do { stream = try await resolver.download(track) }
        catch let error as PlaybackStreamError {
            // Extraction itself is out of scope here; when YouTube refuses the anonymous client the cache path is
            // still proven by the public-M4A test above.
            throw XCTSkip("YouTube refused anonymous extraction for fsiPzT50ZiM (\(error)); nothing to download into the cache.")
        } catch let error as MusicServiceError {
            throw XCTSkip("YouTube extraction is unavailable right now (\(error)); nothing to download into the cache.")
        }
        let elapsed = started.duration(to: .now)
        XCTAssertTrue(stream.url.isFileURL)
        XCTAssertTrue(resolver.isCachedStream(stream))
        let stored = await cache.entry(for: track.id)
        let entry = try XCTUnwrap(stored)
        XCTAssertEqual(try XCTUnwrap(entry.duration), 262, accuracy: 3, "The sidecar carries the recording's duration")
        XCTAssertGreaterThan(entry.bytes, 1_000_000)
        let sidecar = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("\(track.id).json"))) as? [String: Any]
        XCTAssertEqual(try XCTUnwrap(sidecar?["duration"] as? Double), 262, accuracy: 3)
        XCTAssertEqual(sidecar?["bytes"] as? Int64, entry.bytes)
        let loudness = entry.loudnessDb.map { String($0) } ?? "nil"
        let views = entry.viewCount.map { String($0) } ?? "nil"
        print("STREAM LIVE cache download fsiPzT50ZiM: bytes=\(entry.bytes) duration=\(entry.duration ?? 0) loudnessDb=\(loudness) viewCount=\(views) elapsed=\(elapsed)")

        // A resolver whose every network path fails proves the second resolution is served from disk alone.
        let offline = CatalogMockSession { _ in throw URLError(.notConnectedToInternet) }
        defer { offline.close() }
        let offlineResolver = YouTubeStreamResolver(extract: { _, _ in throw URLError(.notConnectedToInternet) },
                                                    validate: { _ in throw URLError(.notConnectedToInternet) },
                                                    fastExtract: { _ in throw URLError(.notConnectedToInternet) },
                                                    audioCache: AudioCache(directory: directory, session: offline.session))
        let again = ContinuousClock.now
        let cached = try await offlineResolver.resolve(track: track, forceRefresh: true)
        let hit = again.duration(to: .now)
        XCTAssertEqual(cached.url, stream.url)
        XCTAssertEqual(cached.duration, entry.duration)
        XCTAssertNil(cached.expiresAt)
        XCTAssertLessThan(hit, .milliseconds(50), "A cache hit is a local file stat, not a network round trip")
        print("STREAM LIVE cache hit fsiPzT50ZiM: \(hit)")
    }
}
