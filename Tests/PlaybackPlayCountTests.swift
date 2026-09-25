import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackPlayCountTests: XCTestCase {
    func testSongTotalWinsOverRecordingViewsAndSurvivesStreamRefresh() async throws {
        let url = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = PlaybackResolutionGate()
        addTeardownBlock { await gate.cancelRemaining() }
        let player = PlayerController(resolver: gate)
        defer { player.pause() }
        let track = Track(id: CatalogFixtures.hindiID, title: "Tum Hi Ho", playCount: 1_200_000_000)
        player.play([track])
        XCTAssertEqual(player.currentPlayCount, 1_200_000_000)
        let first = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
        await gate.finish(first, with: .success(ResolvedStream(url: url, duration: 8, viewCount: 200_574_245)))
        try await PlaybackTestSupport.waitUntil { player.resolvedViewCount == 200_574_245 }
        XCTAssertEqual(player.currentPlayCount, 1_200_000_000, "Upload views and the provider's song total have different scopes")
        player.retry()
        let second = try await PlaybackTestSupport.waitForRequests(2, on: gate)[1]
        await gate.finish(second, with: .success(ResolvedStream(url: url, duration: 8)))
        try await PlaybackTestSupport.waitUntil { player.currentStreamURL == url }
        XCTAssertNil(player.resolvedViewCount, "A replacement stream with no view count must not retain stale diagnostics")
        XCTAssertEqual(player.currentPlayCount, 1_200_000_000)
    }

    func testMissingTotalDoesNotBecomeTheAlternateUploadsViewCount() async throws {
        let url = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = PlaybackResolutionGate()
        addTeardownBlock { await gate.cancelRemaining() }
        let player = PlayerController(resolver: gate)
        defer { player.pause() }
        player.play([Track(id: "BjL7AuPsmEk", title: "Tum Hi Ho")])
        let request = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
        await gate.finish(request, with: .success(ResolvedStream(url: url, duration: 8, viewCount: 330_833)))
        try await PlaybackTestSupport.waitUntil { player.resolvedViewCount == 330_833 }
        XCTAssertNil(player.currentPlayCount)
    }

    func testRestoredAndChangedSelectionsUseOnlyTheirOwnProviderTotal() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        let known = Track(id: CatalogFixtures.hindiID, title: "Tum Hi Ho", playCount: 1_200_000_000)
        let unknown = Track(id: "BjL7AuPsmEk", title: "Tum Hi Ho")
        player.restore(PlaybackSnapshot(queue: [known, unknown]))
        XCTAssertEqual(player.currentPlayCount, 1_200_000_000)
        player.next()
        XCTAssertNil(player.currentPlayCount)
        XCTAssertNil(player.resolvedViewCount)
        player.removeFromQueue(at: player.currentIndex)
        player.removeFromQueue(at: player.currentIndex)
        XCTAssertNil(player.currentPlayCount)
        let requests = await gate.requests
        XCTAssertTrue(requests.isEmpty, "Presenting totals does not trigger per-song provider requests")
    }

    func testPreparedStandbyDoesNotInheritTheOutgoingTotalOrSubstituteUploadViews() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = PlaybackResolutionGate()
        addTeardownBlock { await gate.cancelRemaining() }
        let player = PlayerController(resolver: gate, standbyPreroll: { _, completion in completion(true) })
        defer { player.pause() }
        var settings = player.settings
        settings.crossfadeSeconds = 1
        settings.gapless = true
        settings.automix = false
        settings.autoplay = false
        player.apply(settings)
        let outgoing = Track(id: CatalogFixtures.hindiID, title: "Tum Hi Ho", playCount: 1_200_000_000)
        let incoming = Track(id: "BjL7AuPsmEk", title: "Tum Hi Ho")
        player.play([outgoing, incoming])
        let first = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
        await gate.finish(first, with: .success(ResolvedStream(url: url, duration: 20, viewCount: 200_574_245)))
        let next = try await PlaybackTestSupport.waitForRequests(2, on: gate)[1]
        XCTAssertEqual(next.trackID, incoming.id)
        await gate.finish(next, with: .success(ResolvedStream(url: url, duration: 20, viewCount: 330_833)))
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady }
        XCTAssertEqual(player.currentPlayCount, 1_200_000_000)
        player.next()
        XCTAssertNotNil(player.crossfadeState, "Exercise the prepared-deck handoff rather than another resolution")
        XCTAssertEqual(player.currentTrack?.id, incoming.id)
        XCTAssertEqual(player.resolvedViewCount, 330_833)
        XCTAssertNil(player.currentPlayCount)
    }
}
