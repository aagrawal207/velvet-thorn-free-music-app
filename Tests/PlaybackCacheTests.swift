import XCTest
@testable import GanaBajana

/// PlayerController over a `StreamCaching` fixture: next-track downloads feeding the standby deck, cached starts,
/// and recovery paths that prefer or discard local copies.
@MainActor
final class PlaybackCacheTests: XCTestCase {
    private let first = Track(id: "cache-first", title: "First")
    private let second = Track(id: "cache-second", title: "Second")
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    func testNextTrackDownloadsAfterTheCurrentStartsAndTheStandbySwapsToTheFileForAGaplessCut() async throws {
        let firstRemote = try audio(seconds: 5)
        let firstCached = try copy(firstRemote)
        let secondRemote = try audio(seconds: 4)
        let secondCached = try copy(secondRemote)
        let resolver = PlaybackCachingFixtureResolver([
            first.id: .init(remote: firstRemote, cached: firstCached, duration: 5, downloadDelay: .milliseconds(300)),
            second.id: .init(remote: secondRemote, cached: secondCached, duration: 4, downloadDelay: .milliseconds(600)),
        ])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: true))
        var starts: [String] = []
        player.onTrackStarted = { starts.append($0.id) }
        player.play([first, second])

        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.standbyTrack == self.second && player.isStandbyReady }
        XCTAssertEqual(player.standbyStreamURL, secondRemote, "The deck is armed with the remote stream first")
        XCTAssertFalse(player.isNextTrackCached)
        XCTAssertFalse(player.isCurrentTrackCached)
        XCTAssertEqual(player.currentStreamURL, firstRemote)

        try await PlaybackTestSupport.waitUntil { player.isNextTrackCached }
        try await PlaybackTestSupport.waitUntil { player.standbyStreamURL == secondCached && player.isStandbyReady }
        XCTAssertEqual(player.standbyTrack, second)
        XCTAssertEqual(player.currentTrack, first, "Swapping the standby never touches the playing track")
        try await PlaybackTestSupport.waitUntil { player.isCurrentTrackCached }
        XCTAssertEqual(player.currentStreamURL, firstRemote, "The playing item is left alone once its copy lands")
        let downloads = await resolver.requests.filter { if case .download = $0 { return true } else { return false } }
        XCTAssertEqual(Array(downloads.prefix(2)), [.download(second.id), .download(first.id)], "Next first, then current")
        let retained = await resolver.retained
        XCTAssertEqual(retained.last, [first.id, second.id])

        try await PlaybackTestSupport.waitUntil(timeout: 8) { player.currentTrack == self.second }
        XCTAssertNil(player.crossfadeState)
        XCTAssertEqual(player.currentStreamURL, secondCached, "The cut lands on the file-backed standby")
        XCTAssertTrue(player.isCurrentTrackCached)
        XCTAssertFalse(player.isNextTrackCached, "Nothing follows the last entry")
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.5 }
        XCTAssertEqual(starts, [first.id, second.id])
        XCTAssertNil(player.errorMessage)
        let resolutions = await resolver.requests.filter { if case .resolve = $0 { return true } else { return false } }
        XCTAssertEqual(resolutions, [.resolve(first.id, forceRefresh: false), .resolve(second.id, forceRefresh: false)],
                       "Adopting the download replaces the standby item without another resolution")
    }

    func testALateDownloadKeepsTheRemoteStandbyButStillMarksTheNextTrackCached() async throws {
        let firstRemote = try audio(seconds: 5)
        let secondRemote = try audio(seconds: 3)
        let secondCached = try copy(secondRemote)
        // Lands ~0.8 s before the cut, inside the 1.25 s swap margin of a 5 s track.
        let resolver = PlaybackCachingFixtureResolver([
            first.id: .init(remote: firstRemote, cached: nil, duration: 5),
            second.id: .init(remote: secondRemote, cached: secondCached, duration: 3, downloadDelay: .milliseconds(4_200)),
        ])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: true))
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.standbyTrack == self.second && player.isStandbyReady }
        try await PlaybackTestSupport.waitUntil(timeout: 7) { player.isNextTrackCached }
        XCTAssertEqual(player.standbyStreamURL, secondRemote, "Inside the margin before the cut the remote standby stays")
        try await PlaybackTestSupport.waitUntil(timeout: 7) { player.currentTrack == self.second }
        XCTAssertEqual(player.currentStreamURL, secondRemote)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.3 }
        XCTAssertNil(player.errorMessage)
    }

    func testPlayingAnAlreadyCachedTrackInstallsTheFileAtOnce() async throws {
        let remote = try audio(seconds: 6)
        let cached = try copy(remote)
        let resolver = PlaybackCachingFixtureResolver([second.id: .init(remote: remote, cached: cached, duration: 6)], downloaded: [second.id])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        let started = ContinuousClock.now
        player.play([second])
        try await PlaybackTestSupport.waitUntil { player.currentStreamURL == cached }
        let installed = started.duration(to: .now)
        XCTAssertLessThan(installed, .milliseconds(150), "A cached track is installed without any network round trip")
        XCTAssertTrue(player.isCurrentTrackCached)
        try await PlaybackTestSupport.waitUntil { !player.isPreparing }
        let ready = started.duration(to: .now)
        XCTAssertLessThan(ready, .milliseconds(750), "A local file becomes ready almost immediately")
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.3 }
        XCTAssertEqual(player.duration, 6)
        let requests = await resolver.requests
        XCTAssertEqual(requests.first, .resolve(second.id, forceRefresh: false))
        XCTAssertFalse(requests.contains(.discard(second.id)))
        XCTAssertNil(player.errorMessage)
    }

    func testAFailingCachedFileIsDiscardedAndPlaybackFallsBackToTheRemoteStream() async throws {
        let remote = try audio(seconds: 6)
        let missing = remote.deletingLastPathComponent().appendingPathComponent("gone.wav")
        let resolver = PlaybackCachingFixtureResolver(
            [first.id: .init(remote: remote, cached: missing, duration: 6, downloadFails: true)], downloaded: [first.id])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.play([first])
        try await PlaybackTestSupport.waitUntil(timeout: 12) { player.isPlaying && player.position > 0.3 }
        XCTAssertEqual(player.currentStreamURL, remote)
        XCTAssertFalse(player.isCurrentTrackCached)
        XCTAssertNil(player.errorMessage)
        let requests = await resolver.requests
        XCTAssertEqual(Array(requests.prefix(3)), [.resolve(first.id, forceRefresh: false), .discard(first.id), .resolve(first.id, forceRefresh: true)],
                       "The unplayable copy is dropped before the forced re-resolution")
        let downloaded = await resolver.downloadedTrackIDs
        XCTAssertFalse(downloaded.contains(first.id))
    }

    func testRecoveryFromAStreamFailureSwitchesToTheCachedCopyAtTheSamePosition() async throws {
        let remote = try audio(seconds: 10)
        let cached = try copy(remote)
        let resolver = PlaybackCachingFixtureResolver([first.id: .init(remote: remote, cached: cached, duration: 10)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.play([first])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isCurrentTrackCached }
        XCTAssertEqual(player.currentStreamURL, remote, "The copy waits in the background while the remote item plays")
        try await PlaybackTestSupport.waitUntil { player.position > 1.5 }
        let saved = player.position
        // The same forced re-resolution the stalled/expired/transport paths take, without waiting out a 20 s stall.
        player.handleMediaServicesReset()
        try await PlaybackTestSupport.waitUntil { player.currentStreamURL == cached }
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > saved + 0.2 }
        XCTAssertGreaterThan(player.position, saved - 0.1)
        XCTAssertTrue(player.isCurrentTrackCached)
        XCTAssertNil(player.errorMessage)
        let requests = await resolver.requests
        XCTAssertTrue(requests.contains(.resolve(first.id, forceRefresh: true)))
        XCTAssertFalse(requests.contains(.discard(first.id)), "A healthy copy is never discarded by a network-side failure")
    }

    // MARK: - Helpers

    private func settings(crossfade: TimeInterval, gapless: Bool) -> PlaybackTransitionSettings {
        var settings = PlaybackTransitionSettings()
        settings.crossfadeSeconds = crossfade
        settings.gapless = gapless
        settings.automix = false
        settings.autoplay = false
        return settings
    }

    private func audio(seconds: Int) throws -> URL {
        let url = try PlaybackTestSupport.audioFile(seconds: seconds)
        directories.append(url.deletingLastPathComponent())
        return url
    }

    private func copy(_ url: URL) throws -> URL {
        let target = url.deletingLastPathComponent().appendingPathComponent("cached.wav")
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }
}
