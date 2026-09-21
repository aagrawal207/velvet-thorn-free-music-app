import AVFoundation
import XCTest
@testable import GanaBajana

private typealias LyricsMetadataObservation = (document: LyricsDocument?, elapsed: TimeInterval, errorCategory: String)

@MainActor
final class LyricsPlaybackMetadataLiveTests: XCTestCase {
    func testLiveLyricsComparePlaybackMetadataAndDurationBoundaries() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["GANABAJANA_LIVE_TESTS"] == "1"
                          && environment["GANABAJANA_LYRICS_DIAGNOSTICS"] == "1",
                          "Set GANABAJANA_LIVE_TESTS=1 and GANABAJANA_LYRICS_DIAGNOSTICS=1 for metadata-only lyrics diagnostics.")
        var report: [[String: String]] = []
        defer { attach(report) }
        let session = CatalogTransport.anonymousSession()
        defer { session.invalidateAndCancel() }
        let catalog = YouTubeMusicService(session: session)
        let recordingID = "fsiPzT50ZiM"
        let searchStarted = ContinuousClock.now
        let track: Track
        do {
            let page = try await PlaybackDeadline.run(seconds: 20) {
                try await catalog.search(query: "Tum Hi Ho Arijit Singh", filter: .songs, continuation: nil)
            }
            guard let found = page.tracks.first(where: { $0.id == recordingID && $0.isAudioRecording == true }) else {
                report.append(["provider": "YouTube Music search", "sourceID": recordingID,
                               "kind": "error", "errorCategory": "recording_not_found"])
                return
            }
            track = found
            report.append(metadata(track, provider: "YouTube Music search", exact: track.duration,
                                   elapsed: elapsed(since: searchStarted)))
        } catch {
            report.append(["provider": "YouTube Music search", "sourceID": recordingID, "kind": "error",
                           "elapsedSeconds": String(elapsed(since: searchStarted)),
                           "errorCategory": lyricsMetadataErrorCategory(error)])
            return
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BreezyLyricsMetadata-\(UUID())", isDirectory: true)
        let mediaSession = CatalogTransport.anonymousSession()
        let cache = AudioCache(directory: directory, capacityBytes: 128 << 20, maximumFiles: 1, session: mediaSession)
        // This is the bounded, anonymous fast-path setup used by the media live tests, including supported native Opus.
        let resolver = YouTubeStreamResolver(extract: { _, _ in throw PlaybackStreamError.noAudio },
            validate: { try await StreamValidation.validate(url: $0) },
            fastExtract: { try await YouTubeAudioFastPath.extract(videoID: $0) }, audioCache: cache,
            opusEnabled: OpusNativeAudio.isSupported)
        addTeardownBlock {
            mediaSession.invalidateAndCancel()
            do {
                await resolver.retainCached([])
                _ = try await resolver.clearAudioCache(retaining: { [] })
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            } catch {
                XCTFail("Lyrics diagnostic media cleanup: \(lyricsMetadataErrorCategory(error))")
            }
        }
        var playerDuration: TimeInterval?
        var nativeDuration: TimeInterval?
        let mediaStarted = ContinuousClock.now
        do {
            let stream = try await PlaybackDeadline.run(seconds: 60) { try await resolver.download(track) }
            guard stream.url.isFileURL else { throw PlaybackStreamError.invalidMedia }
            let resolved = try await PlaybackStreamLoading.loadMissingLocalDuration(in: stream)
            playerDuration = PlaybackTiming.duration(stream: resolved, track: track)
            report.append(metadata(track, provider: "PlaybackTiming", exact: playerDuration,
                                   elapsed: elapsed(since: mediaStarted)))
            let asset = AVURLAsset(url: resolved.url)
            defer { asset.cancelLoading() }
            let nativeStarted = ContinuousClock.now
            let seconds = try await PlaybackDeadline.run(seconds: 10) { try await asset.load(.duration).seconds }
            guard let duration = PlaybackTiming.validDuration(seconds) else { throw PlaybackStreamError.invalidMedia }
            nativeDuration = duration
            report.append(metadata(track, provider: "AVFoundation local asset", exact: duration,
                                   elapsed: elapsed(since: nativeStarted)))
        } catch {
            report.append(metadata(track, provider: "Native media", exact: nativeDuration,
                                   elapsed: elapsed(since: mediaStarted), errorCategory: lyricsMetadataErrorCategory(error)))
        }

        // Display truncation is not the lyrics input; LyricsView rounds the resolved player duration.
        var inputs: [(labels: [String], duration: TimeInterval)] = []
        let candidates: [(String, TimeInterval?)] = [("player-rounded", playerDuration?.rounded()),
            ("native-rounded", nativeDuration?.rounded()), ("edge-261", 261), ("edge-262", 262)]
        for (label, value) in candidates {
            guard let value = LyricsMatcher.validDuration(value) else { continue }
            if let index = inputs.firstIndex(where: { $0.duration == value }) { inputs[index].labels.append(label) }
            else { inputs.append(([label], value)) }
        }
        for input in inputs {
            if Task.isCancelled { break }
            var requested = track
            requested.duration = input.duration
            var rows = await compareFreshProviders(for: requested)
            for index in rows.indices {
                rows[index]["scenario"] = input.labels.joined(separator: ",")
                if let playerDuration { rows[index]["playerDurationExact"] = String(playerDuration) }
                if let nativeDuration { rows[index]["nativeDurationExact"] = String(nativeDuration) }
            }
            report += rows
        }
    }

    private func compareFreshProviders(for track: Track) async -> [[String: String]] {
        let primaryTransport = LyricsMetadataTransport()
        let directTransport = LyricsMetadataTransport()
        let primary = LyricsMetadataProvider(LRCLyricsService(transport: primaryTransport))
        let fallbackSession = CatalogTransport.anonymousSession()
        let fallback = LyricsMetadataProvider(YouTubeMusicService(session: fallbackSession))
        let composite = CompositeLyricsProvider(primary: primary, fallback: fallback)
        let direct = LRCLyricsService(transport: directTransport)

        // A cold production-budget lookup runs before the independent, longer LRCLIB lookup can warm the route.
        let combined = await observe(composite, track: track, timeout: 8)
        let standalone = await observe(direct, track: track, timeout: 40)
        var repeated: LyricsMetadataObservation?
        if let document = combined.document, document.kind != .unavailable, !Task.isCancelled {
            repeated = await observe(composite, track: track, timeout: 8)
        }
        fallbackSession.invalidateAndCancel()
        await primaryTransport.close()
        await directTransport.close()
        let drainDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while primary.started.values.count != primary.finished.values.count || fallback.started.values.count != fallback.finished.values.count {
            if Task.isCancelled || ContinuousClock.now >= drainDeadline { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        var rows = [await resultRow(combined, track: track, provider: "Composite fresh", transport: primaryTransport),
                    await resultRow(standalone, track: track, provider: "LRCLIB fresh", transport: directTransport)]
        if let result = primary.finished.values.last {
            rows.append(await resultRow(result, track: track, provider: "Composite primary LRCLIB", transport: primaryTransport))
        }
        if let result = fallback.finished.values.last {
            rows.append(await resultRow(result, track: track, provider: "Composite fallback YouTube Music", transport: primaryTransport))
        }
        if let repeated {
            rows.append(await resultRow(repeated, track: track, provider: "Composite immediate repeat", transport: primaryTransport))
        }
        for (provider, transport) in [("Composite primary LRCLIB HTTP", primaryTransport), ("Direct LRCLIB HTTP", directTransport)] {
            for request in await transport.observations {
                rows.append(metadata(track, provider: provider, exact: track.duration,
                                     elapsed: request.elapsed, errorCategory: request.errorCategory))
            }
        }
        if primary.started.values.count != primary.finished.values.count || fallback.started.values.count != fallback.finished.values.count {
            rows.append(metadata(track, provider: "Provider cleanup", exact: track.duration, errorCategory: "drain_timeout"))
        }
        return rows
    }

    private func observe(_ provider: any LyricsProviding, track: Track, timeout: TimeInterval) async -> LyricsMetadataObservation {
        let started = ContinuousClock.now
        let task = Task { try await provider.lyrics(for: track) }
        defer { task.cancel() }
        do {
            let document = try await PlaybackDeadline.run(seconds: timeout) { try await task.value }
            return (document, elapsed(since: started), "none")
        } catch {
            task.cancel()
            _ = await task.result
            return (nil, elapsed(since: started), lyricsMetadataErrorCategory(error))
        }
    }

    private func resultRow(_ result: LyricsMetadataObservation, track: Track, provider: String,
                           transport: LyricsMetadataTransport) async -> [String: String] {
        var row = metadata(track, provider: provider, exact: track.duration, elapsed: result.elapsed, errorCategory: result.errorCategory)
        guard let document = result.document else { return row }
        row["kind"] = document.kind.rawValue
        row["source"] = document.providerSource?.rawValue ?? "unknown"
        row["sourceID"] = document.sourceID.map(String.init)
        if document.providerSource?.isRecordingLinked == true { row["sourceID"] = document.trackID }
        row["matchedTitle"] = document.matchedTitle.map { String($0.prefix(512)) }
        row["matchedArtist"] = document.matchedArtist.map { String($0.prefix(512)) }
        if document.providerSource == .lrcLib, let id = document.sourceID, let record = await transport.record(id: id) {
            row["matchedAlbum"] = record.albumName.map { String($0.prefix(512)) }
            if let duration = LyricsMatcher.validDuration(record.duration) { row["matchedDuration"] = String(duration) }
            // Omitting duration here preserves the very last timestamp that the production plausibility check sees.
            if let last = LRCParser.parse(record.syncedLyrics ?? "").last(where: { !$0.text.isEmpty }) {
                row["lastNonemptyTimestamp"] = String(last.time)
            }
        }
        return row
    }

    private func metadata(_ track: Track, provider: String, exact: TimeInterval?, elapsed: TimeInterval? = nil,
                          errorCategory: String = "none") -> [String: String] {
        var row = ["provider": provider, "recordingID": track.id, "title": String(track.title.prefix(512)),
                   "artist": String(track.artistName.prefix(512)), "album": String((track.albumTitle ?? "").prefix(512)),
                   "kind": errorCategory == "none" ? "metadata" : "error", "errorCategory": errorCategory]
        if let exact = LyricsMatcher.validDuration(exact) {
            row["durationExact"] = String(exact)
            row["durationRounded"] = String(exact.rounded())
            row["durationDisplay"] = TimeText.duration(exact)
        }
        if let elapsed { row["elapsedSeconds"] = String(elapsed) }
        return row
    }

    private func attach(_ rows: [[String: String]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "lyrics-playback-metadata-diagnostic"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let text = String(data: data, encoding: .utf8) { print("LYRICS METADATA DIAGNOSTIC \(text)") }
    }
}

private struct LyricsMetadataProvider: LyricsProviding {
    let base: any LyricsProviding
    let started = CatalogTestRecorder<Bool>()
    let finished = CatalogTestRecorder<LyricsMetadataObservation>()

    init(_ base: any LyricsProviding) { self.base = base }

    func lyrics(for track: Track) async throws -> LyricsDocument {
        started.record(true)
        let start = ContinuousClock.now
        do {
            let document = try await base.lyrics(for: track)
            finished.record((document, elapsed(since: start), "none"))
            return document
        } catch {
            finished.record((nil, elapsed(since: start), lyricsMetadataErrorCategory(error)))
            throw error
        }
    }
}

private actor LyricsMetadataTransport: LRCHTTPTransport {
    private var base: LRCURLSessionTransport? = LRCURLSessionTransport()
    private var tasks: [UUID: Task<LRCHTTPResponse, any Error>] = [:]
    private var responses: [LRCHTTPResponse] = []
    private var requestCount = 0
    private(set) var observations: [(elapsed: TimeInterval, errorCategory: String)] = []

    func send(_ request: URLRequest) async throws -> LRCHTTPResponse {
        try Task.checkCancellation()
        guard let base, requestCount < LRCLIBClient.Configuration().maximumRequests else { throw CancellationError() }
        requestCount += 1
        let id = UUID()
        let start = ContinuousClock.now
        let task = Task<LRCHTTPResponse, any Error> { @Sendable [base, request] in try await base.send(request) }
        tasks[id] = task
        defer { tasks.removeValue(forKey: id) }
        do {
            let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            responses.append(response)
            observations.append((elapsed(since: start), response.statusCode == 200 ? "none" : "http_\(response.statusCode)"))
            return response
        } catch {
            observations.append((elapsed(since: start), lyricsMetadataErrorCategory(error)))
            throw error
        }
    }

    func record(id: Int) -> LRCLIBRecord? {
        let decoder = JSONDecoder()
        for response in responses.reversed() where response.statusCode == 200 {
            if let record = try? decoder.decode(LRCLIBRecord.self, from: response.data), record.id == id { return record }
            if let records = try? decoder.decode([LRCLIBRecord].self, from: response.data), records.count <= 20,
               let record = records.first(where: { $0.id == id }) { return record }
        }
        return nil
    }

    func close() async {
        let pending = Array(tasks.values)
        pending.forEach { $0.cancel() }
        base = nil
        for task in pending { _ = await task.result }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !tasks.isEmpty, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func elapsed(since start: ContinuousClock.Instant) -> TimeInterval {
    let value = start.duration(to: .now).components
    return Double(value.seconds) + Double(value.attoseconds) / 1e18
}

private func lyricsMetadataErrorCategory(_ error: any Error) -> String {
    if error is CancellationError { return "cancelled" }
    if let value = error as? PlaybackStreamError {
        switch value {
        case .invalidID: return "invalid_recording_id"
        case .noAudio: return "no_audio"
        case .invalidMedia: return "invalid_media"
        case .expired: return "expired_media"
        case .timedOut: return "deadline"
        case .signInRequired: return "sign_in_required"
        case .httpStatus(let status): return "http_\(status)"
        }
    }
    if let value = error as? MusicServiceError {
        switch value {
        case .invalidResponse: return "invalid_response"
        case .network: return "network"
        case .unavailable: return "provider_unavailable"
        case .rateLimited: return "rate_limited"
        }
    }
    if let value = error as? URLError { return "url_error_\(value.code.rawValue)" }
    if let value = error as? LyricsLookupError {
        switch value {
        case .recordingMismatch: return "recording_mismatch"
        case .sourcesFailed: return "sources_failed"
        }
    }
    return "other_error_\((error as NSError).code)"
}
