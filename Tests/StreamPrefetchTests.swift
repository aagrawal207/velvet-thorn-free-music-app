import XCTest
@testable import GanaBajana

private actor StreamSpeedFixture {
    private(set) var calls: [String] = []
    private var pending: [String: CheckedContinuation<[URL], Error>] = [:]

    func ready(_ id: String) -> [URL] { calls.append(id); return Self.urls(id) }
    func hold(_ id: String) async throws -> [URL] {
        calls.append(id)
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func finish(_ id: String) { pending.removeValue(forKey: id)?.resume(returning: Self.urls(id)) }
    static func urls(_ id: String) -> [URL] {
        [URL(string: "https://audio.googlevideo.com/videoplayback?id=\(id)&dur=200&expire=4000000000")!]
    }
}

final class StreamPrefetchTests: XCTestCase {
    private let a = Track(id: "fsiPzT50ZiM", title: "A")
    private let b = Track(id: "NJAv_7lHUIU", title: "B")
    private let c = Track(id: "J7p4bzqLvCw", title: "C")

    private func wait(_ condition: () async -> Bool) async throws {
        let start = ContinuousClock.now
        while !(await condition()) {
            if start.duration(to: .now) > .seconds(3) { throw PlaybackStreamError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testLRUEvictsOnlyTheLeastRecentlyUsedEntry() async throws {
        let fixture = StreamSpeedFixture()
        let resolver = YouTubeStreamResolver(cacheCapacity: 2, extract: { id, _ in await fixture.ready(id) }, validate: { _ in })
        for track in [a, b, a, c, a, b] { _ = try await resolver.resolve(track: track, forceRefresh: false) }
        let calls = await fixture.calls
        XCTAssertEqual(calls, [a.id, b.id, c.id, b.id])
    }

    func testSameSongCoalescesAndCancellingOneWaiterKeepsTheOther() async throws {
        let fixture = StreamSpeedFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in try await fixture.hold(id) }, validate: { _ in })
        let track = a
        let first = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        try await wait { await fixture.calls.count == 1 }
        let second = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        try await wait { await resolver.activeWaiterCount == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected waiter cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await wait { await resolver.activeWaiterCount == 1 }
        await fixture.finish(track.id)
        let result = try await second.value
        let cached = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(result.url, cached.url)
        let calls = await fixture.calls
        XCTAssertEqual(calls, [track.id])
    }

    func testForegroundJoinsPrefetchEvenIfThePrefetchWaiterIsCancelled() async throws {
        let fixture = StreamSpeedFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in await fixture.ready("library-" + id) },
            validate: { _ in }, fastExtract: { FastPathResult(urls: try await fixture.hold($0)) })
        let track = a
        let warmup = Task(priority: .utility) { await resolver.prefetch([track]) }
        try await wait { await fixture.calls.count == 1 }
        let foreground = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        try await wait { await resolver.activeWaiterCount == 2 }
        warmup.cancel()
        await warmup.value
        let remaining = await resolver.activeWaiterCount
        XCTAssertEqual(remaining, 1)
        await fixture.finish(track.id)
        let result = try await foreground.value
        XCTAssertEqual(result.duration, 200)
        let calls = await fixture.calls
        XCTAssertEqual(calls, [track.id])
    }

    func testForegroundPreemptsIrrelevantWarmupWithoutWaitingForItOrStartingItsNextSong() async throws {
        let fixture = StreamSpeedFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in await fixture.ready("library-" + id) },
            validate: { _ in }, fastExtract: { FastPathResult(urls: try await fixture.hold($0)) })
        let tracks = [a, b]
        let warmup = Task(priority: .utility) { await resolver.prefetch(tracks) }
        try await wait { await fixture.calls.count == 1 }
        let selected = c
        let foreground = Task { try await resolver.resolve(track: selected, forceRefresh: false) }
        try await wait { await fixture.calls.contains(selected.id) }
        await fixture.finish(selected.id)
        _ = try await foreground.value
        await warmup.value
        let calls = await fixture.calls
        XCTAssertEqual(calls, [a.id, c.id])
        await fixture.finish(a.id)
    }

    func testPrefetchIsLimitedToTwoUniqueSongsAndNeverUsesTheSerializedExtractor() async {
        let fixture = StreamSpeedFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in await fixture.ready("library-" + id) },
            validate: { _ in }, fastExtract: { id in
                _ = await fixture.ready(id)
                throw PlaybackStreamError.noAudio
            })
        await resolver.prefetch([a, a, b, c])
        let calls = await fixture.calls
        XCTAssertEqual(calls, [a.id, b.id])
    }

    func testForegroundFallsBackToYouTubeKitWhenTheFastPathIsUnsupported() async throws {
        let fixture = StreamSpeedFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in await fixture.ready("library-" + id) },
            validate: { _ in }, fastExtract: { id in
                _ = await fixture.ready(id)
                throw PlaybackStreamError.noAudio
            })
        let stream = try await resolver.resolve(track: a, forceRefresh: false)
        XCTAssertNil(stream.loudnessDb, "YouTubeKit exposes no loudness metadata")
        XCTAssertNil(stream.viewCount, "YouTubeKit exposes no play count either")
        let calls = await fixture.calls
        XCTAssertEqual(calls, [a.id, "library-" + a.id])
    }

    func testFastPathLoudnessTravelsWithTheResolvedStreamAndItsCacheEntry() async throws {
        let fixture = StreamSpeedFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in await fixture.ready("library-" + id) },
            validate: { _ in }, fastExtract: { FastPathResult(urls: await fixture.ready($0), loudnessDb: 5.25, viewCount: 1_234_567) })
        let first = try await resolver.resolve(track: a, forceRefresh: false)
        XCTAssertEqual(first.loudnessDb, 5.25)
        XCTAssertEqual(first.viewCount, 1_234_567)
        let cached = try await resolver.resolve(track: a, forceRefresh: false)
        XCTAssertEqual(cached.loudnessDb, 5.25)
        XCTAssertEqual(cached.viewCount, 1_234_567)
        let calls = await fixture.calls
        XCTAssertEqual(calls, [a.id])
    }

    func testAllWaitersCancelledDiscardsLateWorkInsteadOfCachingIt() async throws {
        let fixture = StreamSpeedFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in try await fixture.hold(id) }, validate: { _ in })
        let track = a
        let first = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        try await wait { await fixture.calls.count == 1 }
        first.cancel()
        _ = try? await first.value
        try await wait { await resolver.activeWaiterCount == 0 }
        await fixture.finish(track.id)
        let second = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        try await wait { await fixture.calls.count == 2 }
        await fixture.finish(track.id)
        _ = try await second.value
    }

    func testDefaultProtocolPrefetchDoesNotResolveMockStreams() async {
        let gate = PlaybackResolutionGate()
        await gate.prefetch([a, b])
        let requests = await gate.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPrefetchSkipsKnownVideoRecordings() async {
        let fixture = StreamSpeedFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in await fixture.ready("library-" + id) },
            validate: { _ in }, fastExtract: { FastPathResult(urls: await fixture.ready($0)) })
        var video = a
        video.isAudioRecording = false
        await resolver.prefetch([video, b, c])
        let calls = await fixture.calls
        XCTAssertEqual(calls, [b.id, c.id])
    }

    func testNearExpiryURLsDoNotDisplaceFreshLRUEntries() async throws {
        let fixture = StreamSpeedFixture()
        let nearExpiryID = b.id
        let resolver = YouTubeStreamResolver(cacheCapacity: 1, extract: { id, _ in
            let urls = await fixture.ready(id)
            guard id == nearExpiryID else { return urls }
            let expires = Int(Date().addingTimeInterval(60).timeIntervalSince1970)
            return [URL(string: "https://audio.googlevideo.com/videoplayback?dur=200&expire=\(expires)")!]
        }, validate: { _ in })
        for track in [a, b, a, b] { _ = try await resolver.resolve(track: track, forceRefresh: false) }
        let calls = await fixture.calls
        XCTAssertEqual(calls, [a.id, b.id, b.id])
    }
}
