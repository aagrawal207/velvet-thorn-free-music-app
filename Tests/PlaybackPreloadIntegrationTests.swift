import AVFoundation
import XCTest
@testable import GanaBajana

/// PlayerController wiring for quick skips: the preloader follows the queue's play order and waits for the selected
/// song's first audio, the gapless deck serves a manual Next, and complete next-song downloads wait until the
/// listener has stayed with the current song.
@MainActor
final class PlaybackPreloadIntegrationTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    /// Local playback for every track, plus a remote-looking preload answer the fake asset loader accepts.
    private actor PreloadingFixtureResolver: PlaybackPreloadResolving {
        let url: URL
        private(set) var resolutions: [String] = []
        private(set) var preloads: [String] = []

        init(url: URL) { self.url = url }

        func resolve(track: Track, forceRefresh: Bool) -> ResolvedStream {
            resolutions.append(track.id)
            return ResolvedStream(url: url, duration: 8)
        }

        func preloadStream(for track: Track) -> ResolvedStream? {
            preloads.append(track.id)
            return ResolvedStream(url: URL(string: "https://example.invalid/\(track.id).m4a")!)
        }
    }

    private func tracks(_ count: Int) -> [Track] {
        (0..<count).map { Track(id: String(format: "preload%04d", $0), title: "Song \($0)") }
    }

    private func makePlayer(_ resolver: PreloadingFixtureResolver, store: PlaybackPreloadStore) -> PlayerController {
        let preloader = PlaybackPreloader(resolver: resolver, store: store, loadAsset: { AVURLAsset(url: $0) }, enabled: true)
        let player = PlayerController(resolver: resolver, preloader: preloader)
        var settings = PlaybackTransitionSettings()
        settings.gapless = false
        settings.crossfadeSeconds = 0
        settings.automix = false
        settings.autoplay = false
        player.apply(settings)
        return player
    }

    private func audio(seconds: Int) throws -> URL {
        let url = try PlaybackTestSupport.audioFile(seconds: seconds)
        directories.append(url.deletingLastPathComponent())
        return url
    }

    func testPreloadingWaitsForFirstAudioThenFollowsTheNextFiveInPlayOrder() async throws {
        let resolver = PreloadingFixtureResolver(url: try audio(seconds: 8))
        let store = PlaybackPreloadStore()
        let player = makePlayer(resolver, store: store)
        defer { player.pause() }
        let queue = tracks(8)
        player.play(queue)
        XCTAssertTrue(player.preloader.isHolding, "Nothing competes with the selected song before its first audio")
        let early = await resolver.preloads
        XCTAssertTrue(early.isEmpty)

        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        try await PlaybackTestSupport.eventually { await resolver.preloads.count == 5 }
        let preloads = await resolver.preloads
        XCTAssertEqual(preloads, Array(queue[1...5]).map(\.id), "Nearest first, current song excluded")
        try await PlaybackTestSupport.waitUntil { store.count == 5 }
        XCTAssertEqual(player.upcomingTracks(limit: 5).map(\.id), Array(queue[1...5]).map(\.id))
    }

    func testUpcomingTracksFollowShuffleRepeatAllAndLetNextLeaveRepeatOne() async throws {
        let resolver = PreloadingFixtureResolver(url: try audio(seconds: 8))
        let player = makePlayer(resolver, store: PlaybackPreloadStore())
        defer { player.pause() }
        let queue = tracks(4)
        player.play(queue, startingAt: 2)
        XCTAssertEqual(player.upcomingTracks(limit: 5).map(\.id), [queue[3].id])

        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertEqual(player.upcomingTracks(limit: 5).map(\.id), [queue[3], queue[0], queue[1]].map(\.id),
                       "Repeat all wraps once and never lists the current song")
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .one)
        XCTAssertEqual(player.upcomingTracks(limit: 5).map(\.id), [queue[3].id], "Next still moves on under Repeat One")

        player.cycleRepeatMode()
        player.toggleShuffle()
        let current = try XCTUnwrap(player.currentTrack)
        let order = player.queue.map(\.id)
        let index = try XCTUnwrap(order.firstIndex(of: current.id))
        XCTAssertEqual(player.upcomingTracks(limit: 5).map(\.id), Array(order[(index + 1)...]),
                       "Shuffle uses the play order, not the source order")
    }

    func testManualNextTakesTheReadyGaplessDeckWithoutAnotherResolution() async throws {
        let firstURL = try audio(seconds: 8)
        let secondURL = try audio(seconds: 8)
        let first = Track(id: "deck-first", title: "First")
        let second = Track(id: "deck-second", title: "Second")
        let resolver = PlaybackFixtureResolver([first.id: .init(url: firstURL, duration: 8), second.id: .init(url: secondURL, duration: 8)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.gapless = true
        settings.crossfadeSeconds = 0
        settings.automix = false
        settings.autoplay = false
        player.apply(settings)
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.standbyTrack == second && player.isStandbyReady }

        player.next()
        XCTAssertEqual(player.currentTrack, second)
        XCTAssertEqual(player.currentStreamURL, secondURL)
        XCTAssertTrue(player.isPlaying, "The prerolled deck plays at once instead of waiting for a new item")
        try await PlaybackTestSupport.waitUntil { player.position > 0.3 }
        let requests = await resolver.requests
        XCTAssertEqual(requests.filter { $0.trackID == second.id }.count, 1, "Only the deck's own resolution")
        XCTAssertNil(player.errorMessage)
    }

    func testTheNextSongDownloadsCompletelyOnlyAfterTheListenerSettles() async throws {
        let first = Track(id: "settle-first", title: "First")
        let second = Track(id: "settle-second", title: "Second")
        let third = Track(id: "settle-third", title: "Third")
        var entries: [String: PlaybackCachingFixtureResolver.Entry] = [:]
        for track in [first, second, third] {
            let remote = try audio(seconds: 8)
            let cached = remote.deletingLastPathComponent().appendingPathComponent("cached.wav")
            try FileManager.default.copyItem(at: remote, to: cached)
            entries[track.id] = .init(remote: remote, cached: cached, duration: 8)
        }
        let resolver = PlaybackCachingFixtureResolver(entries)
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.nextDownloadSettleSeconds = 1.5
        var settings = PlaybackTransitionSettings()
        settings.gapless = true
        settings.automix = false
        settings.autoplay = false
        player.apply(settings)

        player.play([first, second, third])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isCurrentTrackCached }
        try await PlaybackTestSupport.waitUntil { player.position > 0.3 }
        XCTAssertLessThan(player.position, 1.5)
        var downloads = await Self.downloads(resolver)
        XCTAssertEqual(downloads, [first.id], "A song the listener may skip earns no complete download yet")

        // A quick skip moves on before settling, so the old next song's file is never requested.
        player.next()
        try await PlaybackTestSupport.waitUntil { player.currentTrack == second && player.isPlaying && player.isCurrentTrackCached }
        downloads = await Self.downloads(resolver)
        XCTAssertEqual(downloads, [first.id, second.id])

        try await PlaybackTestSupport.waitUntil(timeout: 6) { player.isNextTrackCached }
        XCTAssertGreaterThanOrEqual(player.position, 1.4)
        downloads = await Self.downloads(resolver)
        XCTAssertEqual(downloads, [first.id, second.id, third.id], "Settling releases the next song's download once")
        XCTAssertNil(player.errorMessage)
    }

    private static func downloads(_ resolver: PlaybackCachingFixtureResolver) async -> [String] {
        await resolver.requests.compactMap { if case .download(let id) = $0 { return id } else { return nil } }
    }

    func testARestoredPausedQueueStartsNoPreparationUntilPlay() async throws {
        let resolver = PreloadingFixtureResolver(url: try audio(seconds: 8))
        let store = PlaybackPreloadStore()
        let player = makePlayer(resolver, store: store)
        defer { player.pause() }
        let queue = tracks(6)
        player.restore(PlaybackSnapshot(queue: queue, currentIndex: 0, position: 2))
        try await Task.sleep(for: .milliseconds(700))
        let paused = await resolver.preloads
        XCTAssertTrue(paused.isEmpty, "A restored queue spends nothing while it stays paused")
        XCTAssertTrue(player.preloader.queueTracks.map(\.id) == Array(queue[1...5]).map(\.id))

        player.togglePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        try await PlaybackTestSupport.eventually { await resolver.preloads.count == 5 }
        let playing = await resolver.preloads
        XCTAssertEqual(playing, Array(queue[1...5]).map(\.id))
    }

    func testALookupForANewerSignedURLDropsTheStalePreparation() {
        let store = PlaybackPreloadStore()
        let old = URL(string: "https://example.invalid/song.m4a?expire=4102444800&sig=old")!
        let fresh = URL(string: "https://example.invalid/song.m4a?expire=4102444800&sig=new")!
        store.store(.init(trackID: "song", url: old, asset: AVURLAsset(url: old), expiresAt: nil))
        XCTAssertTrue(store.hasUsableAsset(trackID: "song"))
        XCTAssertNil(store.asset(trackID: "song", url: fresh))
        XCTAssertFalse(store.hasUsableAsset(trackID: "song"), "The preloader must prepare the current URL again")
    }

    func testAChangedNextTargetCancelsTheObsoleteTransferWithoutRepeatingTheCurrentSong() async throws {
        let current = Track(id: "pipe-current", title: "Current")
        let oldNext = Track(id: "pipe-old-next", title: "Old next")
        let newNext = Track(id: "pipe-new-next", title: "New next")
        var entries: [String: PlaybackCachingFixtureResolver.Entry] = [:]
        for (track, delay) in [(current, Duration.zero), (oldNext, .seconds(5)), (newNext, .zero)] {
            let remote = try audio(seconds: 2)
            let cached = remote.deletingLastPathComponent().appendingPathComponent("cached.wav")
            try FileManager.default.copyItem(at: remote, to: cached)
            entries[track.id] = .init(remote: remote, cached: cached, duration: 2, downloadDelay: delay)
        }
        let resolver = PlaybackCachingFixtureResolver(entries)
        let pipeline = PlaybackCachePipeline(resolver: resolver)
        defer { pipeline.cancel() }
        var nextCached: [String] = []
        pipeline.onNextCached = { target, _ in nextCached.append(target.track.id) }
        pipeline.sync(current: current, next: .init(track: oldNext, entryID: UUID()))
        try await PlaybackTestSupport.eventually { await Self.downloads(resolver) == [current.id, oldNext.id] }

        pipeline.sync(current: current, next: .init(track: newNext, entryID: UUID()))
        try await PlaybackTestSupport.waitUntil(timeout: 3) { nextCached == [newNext.id] }
        let downloads = await Self.downloads(resolver)
        XCTAssertEqual(downloads, [current.id, oldNext.id, newNext.id], "The landed current copy is not requested again")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(nextCached, [newNext.id], "The obsolete transfer never reports completion")
    }
}
