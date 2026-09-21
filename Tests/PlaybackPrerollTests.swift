import AVFoundation
import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackPrerollTests: XCTestCase {
    private let first = Track(id: "preroll-first", title: "First")
    private let second = Track(id: "preroll-second", title: "Second")

    func testPendingAndFailedPrerollAreNeverTransitionEligible() async throws {
        let url = try audio()
        let gate = PrerollGate()
        let deck = StandbyDeck(resolver: PlaybackFileResolver(url: url, duration: 4), preroll: gate.start)
        defer { deck.invalidate() }
        let entry = UUID()
        deck.prepare(track: first, entryID: entry, forceRefresh: false, after: nil)
        try await PlaybackTestSupport.waitUntil { gate.requests.count == 1 }
        XCTAssertFalse(deck.isReady)
        XCTAssertFalse(deck.isUsable(entryID: entry, transitionAt: Date()))
        XCTAssertNil(deck.take(entryID: entry, transitionAt: Date()))
        XCTAssertFalse(deck.didFail)

        gate.complete(0, with: false)
        XCTAssertTrue(deck.didFail)
        XCTAssertFalse(deck.isReady)
        XCTAssertNil(deck.take(entryID: entry, transitionAt: Date()))
        XCTAssertNil(deck.player?.currentItem)
    }

    func testSuccessfulPrerollAllowsExactlyThePreparedItemToBeTaken() async throws {
        let url = try audio()
        let gate = PrerollGate()
        let deck = StandbyDeck(resolver: PlaybackFileResolver(url: url, duration: 4), preroll: gate.start)
        defer { deck.invalidate() }
        let entry = UUID()
        deck.prepare(track: first, entryID: entry, forceRefresh: false, after: nil)
        try await PlaybackTestSupport.waitUntil { gate.requests.count == 1 }
        gate.complete(0, with: true)
        XCTAssertTrue(deck.isReady)
        XCTAssertFalse(deck.isUsable(entryID: UUID(), transitionAt: Date()))
        let prepared = try XCTUnwrap(deck.take(entryID: entry, transitionAt: Date()))
        XCTAssertTrue(prepared.item === gate.requests[0].item)
        XCTAssertEqual(prepared.stream.url, url)
        XCTAssertFalse(deck.isReady)
        XCTAssertNil(deck.player)
        XCTAssertNil(deck.take(entryID: entry, transitionAt: Date()))
        gate.complete(0, with: false)
        XCTAssertFalse(deck.didFail)
        deck.reclaim(prepared.player)
    }

    func testLatePrerollCannotReadyAnAdoptedOrInvalidatedItem() async throws {
        let original = try audio()
        let replacement = try audio()
        let gate = PrerollGate()
        let deck = StandbyDeck(resolver: PlaybackFileResolver(url: original, duration: 4), preroll: gate.start)
        defer { deck.invalidate() }
        let entry = UUID()
        deck.prepare(track: first, entryID: entry, forceRefresh: false, after: nil)
        try await PlaybackTestSupport.waitUntil { gate.requests.count == 1 }
        deck.adopt(ResolvedStream(url: replacement, duration: 4), entryID: entry)
        try await PlaybackTestSupport.waitUntil { gate.requests.count == 2 }
        XCTAssertFalse(gate.requests[0].item === gate.requests[1].item)
        gate.complete(0, with: true)
        XCTAssertFalse(deck.isReady)
        XCTAssertFalse(deck.didFail)
        gate.complete(1, with: true)
        XCTAssertTrue(deck.isReady)
        gate.complete(0, with: false)
        XCTAssertTrue(deck.isReady)
        XCTAssertEqual(deck.streamURL, replacement)

        deck.prepare(track: first, entryID: entry, forceRefresh: true, after: nil)
        try await PlaybackTestSupport.waitUntil { gate.requests.count == 3 }
        deck.invalidate()
        gate.complete(2, with: true)
        XCTAssertFalse(deck.isReady)
        XCTAssertNil(deck.entryID)
        XCTAssertNil(deck.player?.currentItem)
    }

    func testAnUnfinishedPrerollSkipsCrossfadeAndTheQueueStillAdvancesAtTheEnd() async throws {
        let url = try audio()
        let gate = PrerollGate()
        let resolver = PlaybackFileResolver(url: url, duration: 4)
        let player = PlayerController(resolver: resolver, standbyPreroll: gate.start)
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.gapless = true
        settings.crossfadeSeconds = 2
        settings.automix = false
        settings.autoplay = false
        player.apply(settings)
        var starts: [String] = []
        player.onTrackStarted = { starts.append($0.id) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { gate.requests.count == 1 }
        try await PlaybackTestSupport.waitUntil { player.currentTrack == self.first && player.isPlaying && player.position > 2.3 }
        XCTAssertNil(player.crossfadeState)
        XCTAssertFalse(player.isStandbyReady)
        try await PlaybackTestSupport.waitUntil { player.currentTrack == self.second && player.isPlaying }
        gate.complete(0, with: true)
        XCTAssertNil(player.crossfadeState)
        XCTAssertFalse(player.isStandbyReady)
        XCTAssertEqual(starts, [first.id, second.id])
        XCTAssertNil(player.errorMessage)
        let refreshes = await resolver.refreshes
        XCTAssertEqual(refreshes.count, 3, "The unfinished standby falls back to an ordinary resolution at the end")
    }

    private func audio() throws -> URL {
        let url = try PlaybackTestSupport.audioFile(seconds: 4)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    @MainActor
    private final class PrerollGate {
        struct Request {
            let item: AVPlayerItem
            let complete: @MainActor @Sendable (Bool) -> Void
        }

        private(set) var requests: [Request] = []

        func start(_ player: AVPlayer, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
            guard let item = player.currentItem else { XCTFail("Preroll requires the current item"); return }
            requests.append(Request(item: item, complete: completion))
        }

        func complete(_ index: Int, with result: Bool) { requests[index].complete(result) }
    }
}
