import AVFoundation
import XCTest
@testable import GanaBajana

@MainActor
final class LiveRadioIntegrationTests: XCTestCase {
    /// Opt-in audit of what the Live Radio screen offers: the landing list, NPR and India, each station taken
    /// through the app's probe, native validation and an AVPlayer item until it is ready to play.
    func testPublicDirectoryStationAudit() async throws {
        guard ProcessInfo.processInfo.environment["BREEZY_LIVE_RADIO_TESTS"] == "1" else {
            throw XCTSkip("Explicit opt-in required for public directory and broadcaster requests.")
        }
        let directory = LiveRadioDirectory()
        var seen = Set<UUID>()
        var stations: [(list: String, station: LiveRadioStation)] = []
        for (list, filter) in [("landing", LiveRadioFilter()), ("npr", LiveRadioFilter.npr), ("india", LiveRadioFilter(countryCode: "IN"))] {
            let found = try await directory.search(filter)
            for station in found where seen.insert(station.id).inserted { stations.append((list, station)) }
            try await Task.sleep(for: .milliseconds(400))
        }
        var outcomes: [String: Int] = [:]
        var lines: [String] = []
        var start = 0
        while start < stations.count {
            let batch = Array(stations[start..<min(stations.count, start + 8)])
            start += batch.count
            let tasks = batch.map { entry in Task { @MainActor in await Self.audit(entry.station) } }
            var audited: [(String, LiveRadioStation, String)] = []
            for (entry, task) in zip(batch, tasks) { audited.append((entry.list, entry.station, await task.value)) }
            for (list, station, outcome) in audited {
                outcomes[outcome, default: 0] += 1
                lines.append("RADIO_AUDIT list=\(list) outcome=\(outcome) codec=\(station.codec) hls=\(station.isHLS) name=\(station.name) url=\(station.streamingURL.absoluteString)")
            }
        }
        let summary = "RADIO_AUDIT_SUMMARY total=\(stations.count) " + outcomes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        report(([summary] + lines.sorted()).joined(separator: "\n"))
        XCTAssertFalse(stations.isEmpty)
    }

    private static func audit(_ station: LiveRadioStation) async -> String {
        let connection: LiveRadioConnection
        do { connection = try await LiveRadioStreamResolver().resolve(station) }
        catch { return "probe_" + Self.reason(error) }
        let asset = AVURLAsset(url: connection.streamingURL, options: [AVURLAssetHTTPCookiesKey: [HTTPCookie]()])
        do {
            try await PlaybackDeadline.run(seconds: 15) {
                try await LiveRadioNativeValidation.validate(asset, connection: connection)
            }
        } catch { asset.cancelLoading(); return "native_" + Self.reason(error) }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        defer { player.replaceCurrentItem(with: nil) }
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if item.status == .readyToPlay { return "ready" }
            if item.status == .failed { return "item_failed" }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return "item_timeout"
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case LiveRadioError.invalidStation: "unsupported"
        case LiveRadioError.unavailable: "unavailable"
        case LiveRadioError.tooLarge: "too_large"
        case PlaybackStreamError.timedOut: "timeout"
        case let url as URLError: "url_\(url.code.rawValue)"
        default: "other"
        }
    }

    func testPublicDirectoryToSharedAVPlayerLiveAudio() async throws {
        guard ProcessInfo.processInfo.environment["BREEZY_LIVE_RADIO_TESTS"] == "1" else {
            throw XCTSkip("Explicit opt-in required for public directory and broadcaster requests.")
        }
        let directory = LiveRadioDirectory()
        let stations = try await directory.search(.npr)
        let station = try XCTUnwrap(stations.first)
        report("Directory selection: name=\(station.name), uuid=\(station.id), codec=\(station.codec), hls=\(station.isHLS), publicURL=\(station.streamingURL.absoluteString)")
        let music = PlaybackResolutionGate()
        let player = PlayerController(resolver: music)
        defer { player.stopLiveRadio() }
        let identity = player.activePlayerIdentity
        var songStarts = 0
        player.onTrackStarted = { _ in songStarts += 1 }
        XCTAssertTrue(player.playLiveRadio(station))
        try await PlaybackTestSupport.waitUntil(timeout: 160) { player.isPlaying || player.errorMessage != nil }
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(player.isPlaying)
        try await Task.sleep(for: .seconds(3))
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(player.isPlaying, "The selected public station must sustain native playback.")
        XCTAssertEqual(player.activePlayerIdentity, identity)
        XCTAssertFalse(player.activePlayerAllowsExternalPlayback)
        XCTAssertNil(player.standbyTrack)
        XCTAssertNil(player.standbyStreamURL)
        XCTAssertNil(player.currentTrack)
        XCTAssertEqual(songStarts, 0)
        XCTAssertEqual(player.position, 0)
        let songRequests = await music.requests
        XCTAssertTrue(songRequests.isEmpty)
        player.pause()
        XCTAssertNil(player.currentStreamURL)
        XCTAssertFalse(player.isPlaying)
    }

    func testPublicStreamKCRWStrictAssetVersusProvenElementary() async throws {
        guard ProcessInfo.processInfo.environment["BREEZY_LIVE_RADIO_TESTS"] == "1" else {
            throw XCTSkip("Explicit opt-in required for public directory and broadcaster requests.")
        }
        let stations = try await LiveRadioDirectory().search(LiveRadioFilter(name: "KCRW 88.9 FM - Live", countryCode: "US", tags: "npr"))
        let expectedID = UUID(uuidString: "325a61dc-fe34-48c6-ae82-1467b710f07b")!
        let station = try XCTUnwrap(stations.first { $0.id == expectedID }, "The fixed KCRW directory entry is absent; no replacement station is selected.")
        report("Fixed native comparison: name=\(station.name), uuid=\(station.id), codec=\(station.codec), hls=\(station.isHLS), publicURL=\(station.streamingURL.absoluteString)")
        let connection = try await LiveRadioStreamResolver().resolve(station)
        guard connection.station.id == expectedID, connection.station.isValid,
              LiveRadioURLPolicy.permits(connection.streamingURL) else { throw LiveRadioError.invalidStation }
        guard case .elementary(let proof) = connection.sourceProof else {
            XCTFail("The fixed KCRW MP3 stream must produce elementary-frame proof.")
            return
        }
        XCTAssertEqual(proof.format, .mp3)
        XCTAssertTrue(connection.hasElementaryProof(for: connection.streamingURL))
        report("KCRW public stream probe proved consecutive \(proof.format.rawValue) frames. Beginning strict legacy asset validation without supplying that proof.")
        let assetFirst = AVURLAsset(url: connection.streamingURL, options: [AVURLAssetHTTPCookiesKey: [HTTPCookie]()])
        do {
            try await PlaybackDeadline.run(seconds: 15) {
                try await withTaskCancellationHandler {
                    try await LiveRadioNativeValidation.validate(assetFirst)
                } onCancel: { assetFirst.cancelLoading() }
            }
            report("KCRW strict legacy asset validation PASSED; the earlier empty-track failures remain recorded in Live-Radio-02.")
        } catch {
            report("KCRW strict legacy asset validation FAILED: \(errorIdentity(error)). See live_radio_validation stages. This result is retained separately from the proven-elementary path.")
        }
        assetFirst.cancelLoading()
        try Task.checkCancellation()

        let asset = AVURLAsset(url: connection.streamingURL, options: [AVURLAssetHTTPCookiesKey: [HTTPCookie]()])
        defer { asset.cancelLoading() }
        report("KCRW proven-elementary validation: requiring native playability and no video before item installation, with URL-bound audio-frame proof for empty static audio tracks.")
        do {
            try await PlaybackDeadline.run(seconds: 15) {
                try await withTaskCancellationHandler {
                    try await LiveRadioNativeValidation.validate(asset, connection: connection)
                } onCancel: { asset.cancelLoading() }
            }
        } catch {
            report("KCRW proven-elementary validation FAILED: \(errorIdentity(error)).")
            throw error
        }
        report("KCRW proven-elementary validation PASSED. Installing the native item.")
        let item = AVPlayerItem(asset: asset)
        let native = PlaybackAudioRoute.makePlayer()
        let session = AVAudioSession.sharedInstance()
        defer {
            native.pause()
            native.replaceCurrentItem(with: nil)
            asset.cancelLoading()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        native.replaceCurrentItem(with: item)
        do {
            try await PlaybackTestSupport.waitUntil(timeout: 20) { item.status == .readyToPlay || item.status == .failed }
        } catch {
            report("KCRW proven-elementary item readiness FAILED: \(errorIdentity(error)).")
            throw error
        }
        guard item.status == .readyToPlay else {
            report("KCRW proven-elementary native item FAILED: \(item.error.map(errorIdentity) ?? "no native error").")
            XCTFail("The fixed KCRW native item did not become ready.")
            return
        }
        report("KCRW proven-elementary native item READY.")
        let audioTracks = item.tracks.filter { $0.assetTrack?.mediaType == .audio }.count
        let videoTracks = item.tracks.filter { $0.assetTrack?.mediaType == .video }.count
        let unknownTracks = item.tracks.filter { $0.assetTrack == nil }.count
        report("KCRW ready-item track projection: audio=\(audioTracks), video=\(videoTracks), absentAssetTrack=\(unknownTracks).")
        guard videoTracks == 0 else {
            XCTFail("A ready native item with video must not be played.")
            return
        }
        try PlaybackAudioRoute.session.apply(to: session)
        try session.setActive(true)
        native.play()
        try await PlaybackTestSupport.waitUntil(timeout: 10) {
            native.timeControlStatus == .playing && native.currentTime().seconds.isFinite && native.currentTime().seconds > 0.25
        }
        let firstPosition = native.currentTime().seconds
        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThan(native.currentTime().seconds, firstPosition + 0.2, "The native broadcast playhead must keep advancing.")
        XCTAssertEqual(native.timeControlStatus, .playing)
        XCTAssertFalse(native.allowsExternalPlayback)
        report("KCRW proven-elementary path reached native playback; playhead advanced from \(firstPosition) to \(native.currentTime().seconds). The strict legacy outcome remains above. This comparison does not replace the production PlayerController test.")
    }

    private func report(_ message: String) {
        print("Live radio public test: \(message)")
        XCTContext.runActivity(named: "Public Radio Diagnostic") { activity in
            let attachment = XCTAttachment(string: message)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    private func errorIdentity(_ error: any Error) -> String {
        let native = error as NSError
        let underlying = (native.userInfo[NSUnderlyingErrorKey] as? NSError).map { "; underlying=\($0.domain)/\($0.code)" } ?? ""
        return "\(native.domain)/\(native.code)\(underlying)"
    }
}
