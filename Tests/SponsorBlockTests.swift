import XCTest
@testable import GanaBajana

/// Answers lookups from a table and can hold them open so cancellation and clearing are observable.
actor SponsorBlockProviderGate: SponsorBlockSegmentProviding {
    private(set) var requests: [String] = []
    private let table: [String: [SponsorBlockSegment]]
    private let holds: Bool
    private var pending: [(videoID: String, continuation: CheckedContinuation<[SponsorBlockSegment], Error>)] = []

    init(_ table: [String: [SponsorBlockSegment]], holds: Bool = false) {
        self.table = table
        self.holds = holds
    }

    func segments(forVideoID videoID: String, duration: TimeInterval?) async throws -> [SponsorBlockSegment] {
        requests.append(videoID)
        guard holds else { return table[videoID] ?? [] }
        return try await withCheckedThrowingContinuation { pending.append((videoID, $0)) }
    }

    func release() {
        let waiting = pending
        pending.removeAll()
        for entry in waiting { entry.continuation.resume(returning: table[entry.videoID] ?? []) }
    }
}

@MainActor
final class SponsorBlockTests: XCTestCase {
    private let videoID = "dQw4w9WgXcQ"
    private let contact = URL(string: "https://example.com/contact")!

    /// Two videos share the prefix; only the first is ours. Its submissions cover every eligibility rule.
    private var prefixResponse: Data {
        Data("""
        [{"videoID":"dQw4w9WgXcQ","segments":[
          {"category":"music_offtopic","actionType":"skip","segment":[0,12.5],"UUID":"a","votes":3,"locked":0,"videoDuration":262},
          {"category":"sponsor","actionType":"skip","segment":[10,20],"UUID":"b","votes":0,"locked":0,"videoDuration":262},
          {"category":"intro","actionType":"skip","segment":[30,40],"UUID":"c","votes":-2,"locked":0,"videoDuration":262},
          {"category":"selfpromo","actionType":"mute","segment":[50,60],"UUID":"d","votes":5,"locked":0,"videoDuration":262},
          {"category":"selfpromo","actionType":"skip","segment":[70,70.5],"UUID":"e","votes":5,"locked":0,"videoDuration":262},
          {"category":"outro","actionType":"skip","segment":[250,262],"UUID":"f","votes":-5,"locked":1,"videoDuration":262},
          {"category":"music_offtopic","actionType":"skip","segment":[5,240],"UUID":"g","votes":9,"locked":0,"videoDuration":262},
          {"category":"filler","actionType":"skip","segment":[100,110],"UUID":"h","votes":9,"locked":0,"videoDuration":262}
        ]},
        {"videoID":"otherVideo1","segments":[
          {"category":"sponsor","actionType":"skip","segment":[1,30],"UUID":"z","votes":9,"locked":0,"videoDuration":100}
        ]}]
        """.utf8)
    }

    // MARK: Client

    func testHashPrefixIsTheFirstFourHexCharactersOfSHA256() {
        XCTAssertEqual(SponsorBlockClient.hashPrefix(for: "dQw4w9WgXcQ"), "5f6b")
        XCTAssertEqual(SponsorBlockClient.hashPrefix(for: "fsiPzT50ZiM"), "5192")
    }

    func testRequestUsesThePrefixPathRequestedCategoriesAndContactUserAgent() throws {
        let request = try SponsorBlockClient.request(videoID: videoID, categories: SponsorBlockCategory.allCases,
                                                     userAgent: SponsorBlockClient.userAgent(contactURL: contact), timeout: 6)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "sponsor.ajay.app")
        XCTAssertEqual(request.url?.path, "/api/skipSegments/5f6b")
        XCTAssertFalse(request.url?.absoluteString.contains(videoID) ?? true)
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "categories" }?.value,
                       #"["music_offtopic","sponsor","selfpromo","intro","outro","interaction","preview"]"#)
        XCTAssertEqual(query.first { $0.name == "actionTypes" }?.value, #"["skip"]"#)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Breezy/1.0 (https://example.com/contact)")
        XCTAssertEqual(SponsorBlockClient.userAgent(contactURL: nil), "Breezy/1.0")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, 6)
    }

    func testParsingKeepsOnlyTheMatchingVideoAndFilteringMergesOverlaps() throws {
        let submissions = try SponsorBlockClient.parse(prefixResponse, videoID: videoID)
        XCTAssertEqual(submissions.count, 8)
        XCTAssertEqual(submissions[5].locked, true)
        XCTAssertEqual(submissions[5].votes, -5)
        XCTAssertEqual(submissions[0].videoDuration, 262)
        XCTAssertEqual(try SponsorBlockClient.parse(prefixResponse, videoID: "missingVid1"), [])
        XCTAssertThrowsError(try SponsorBlockClient.parse(Data("{}".utf8), videoID: videoID))
        XCTAssertThrowsError(try SponsorBlockClient.parse(Data("not json".utf8), videoID: videoID))

        let usable = SponsorBlockSegments.usable(submissions, duration: 262)
        XCTAssertEqual(usable, [SponsorBlockSegment(start: 0, end: 20, category: .musicOfftopic),
                                SponsorBlockSegment(start: 250, end: 262, category: .outro)])
        // Without the player's duration the submissions' own videoDuration bounds the coverage rule.
        XCTAssertEqual(SponsorBlockSegments.usable(submissions, duration: nil), usable)
        // A shorter recording turns the 20 s merge into overreach while the 12 s outro stays.
        XCTAssertEqual(SponsorBlockSegments.usable(submissions, duration: 24).map(\.category), [.outro])
        XCTAssertEqual(SponsorBlockSegments.usable([], duration: 262), [])
        XCTAssertEqual(SponsorBlockCategory.intro.logValue, "other")
        XCTAssertEqual(SponsorBlockCategory.musicOfftopic.logValue, "music_offtopic")
    }

    func testMergeOrdersByStartAndCapsTheCount() {
        var submissions = (0..<40).map { index in
            SponsorBlockSubmission(category: "sponsor", actionType: "skip", start: Double(index * 10), end: Double(index * 10 + 2),
                                   votes: 1, locked: false, videoDuration: 1_000)
        }
        submissions.reverse()
        let usable = SponsorBlockSegments.usable(submissions, duration: 1_000)
        XCTAssertEqual(usable.count, SponsorBlockSegments.maximumCount)
        XCTAssertEqual(usable.first?.start, 0)
        XCTAssertEqual(usable.map(\.start), usable.map(\.start).sorted())
    }

    func testAbsenceIsCachedForAnHourAndSegmentsForADay() async throws {
        let clock = CatalogTestClock()
        let counter = CatalogTestCounter()
        let response = prefixResponse
        let mock = CatalogMockSession { request in
            XCTAssertEqual(request.url?.path, "/api/skipSegments/5f6b")
            if counter.increment() <= 2 { return CatalogStub(status: 404, data: Data("Not Found".utf8)) }
            return CatalogStub(data: response)
        }
        defer { mock.close() }
        let client = SponsorBlockClient(session: mock.session, contactURL: contact, now: { clock.now })
        let first = try await client.segments(forVideoID: videoID, duration: 262)
        XCTAssertEqual(first, [])
        _ = try await client.segments(forVideoID: videoID, duration: 262)
        XCTAssertEqual(mock.state.requests.count, 1, "A 404 is a cached absence")
        clock.advance(59 * 60)
        _ = try await client.segments(forVideoID: videoID, duration: 262)
        XCTAssertEqual(mock.state.requests.count, 1)
        clock.advance(2 * 60)
        _ = try await client.segments(forVideoID: videoID, duration: 262)
        XCTAssertEqual(mock.state.requests.count, 2, "The negative entry expires after an hour")
        clock.advance(2 * 60 * 60)
        let found = try await client.segments(forVideoID: videoID, duration: 262)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(mock.state.requests.count, 3)
        clock.advance(23 * 60 * 60)
        _ = try await client.segments(forVideoID: videoID, duration: 262)
        XCTAssertEqual(mock.state.requests.count, 3, "Segments stay cached for a day")
        clock.advance(2 * 60 * 60)
        _ = try await client.segments(forVideoID: videoID, duration: 262)
        XCTAssertEqual(mock.state.requests.count, 4)
        let cached = await client.cachedCount
        XCTAssertEqual(cached, 1)
    }

    func testAVideoMissingFromThePrefixBatchIsAnAbsence() async throws {
        let response = prefixResponse
        let mock = CatalogMockSession { _ in CatalogStub(data: response) }
        defer { mock.close() }
        let client = SponsorBlockClient(session: mock.session, contactURL: contact)
        let segments = try await client.segments(forVideoID: "missingVid1", duration: 200)
        XCTAssertEqual(segments, [])
        _ = try await client.segments(forVideoID: "missingVid1", duration: 200)
        XCTAssertEqual(mock.state.requests.count, 1)
        do { _ = try await client.segments(forVideoID: "saavn:1234", duration: 200); XCTFail("Invalid ids must not be requested") }
        catch { XCTAssertEqual(error as? SponsorBlockClient.RequestError, .invalidVideoID) }
        XCTAssertEqual(mock.state.requests.count, 1)
    }

    func testRateLimitsAndOversizedBodiesBackOffWithoutRepeating() async throws {
        let clock = CatalogTestClock()
        let counter = CatalogTestCounter()
        let response = prefixResponse
        let mock = CatalogMockSession { _ in
            if counter.increment() == 1 { return CatalogStub(status: 429, headers: ["Retry-After": "90"], data: Data("{}".utf8)) }
            return CatalogStub(data: response)
        }
        defer { mock.close() }
        let client = SponsorBlockClient(session: mock.session, contactURL: contact, now: { clock.now })
        do { _ = try await client.segments(forVideoID: videoID, duration: 262); XCTFail("Expected a rate limit") }
        catch { XCTAssertEqual(error as? SponsorBlockClient.RequestError, .rateLimited) }
        do { _ = try await client.segments(forVideoID: videoID, duration: 262); XCTFail("Expected the cooldown") }
        catch { XCTAssertEqual(error as? SponsorBlockClient.RequestError, .rateLimited) }
        XCTAssertEqual(mock.state.requests.count, 1)
        clock.advance(91)
        let segments = try await client.segments(forVideoID: videoID, duration: 262)
        XCTAssertEqual(segments.count, 2)

        var configuration = SponsorBlockClient.Configuration()
        configuration.maximumBytes = 2_048
        let oversized = CatalogMockSession { _ in CatalogStub(data: Data(repeating: 32, count: 4_096)) }
        defer { oversized.close() }
        let bounded = SponsorBlockClient(session: oversized.session, configuration: configuration, contactURL: contact)
        do { _ = try await bounded.segments(forVideoID: videoID, duration: 262); XCTFail("Oversized bodies must be rejected") }
        catch { XCTAssertEqual(error as? SponsorBlockClient.RequestError, .unavailable) }
        do { _ = try await bounded.segments(forVideoID: videoID, duration: 262); XCTFail("A failure defers the next request") }
        catch { XCTAssertEqual(error as? SponsorBlockClient.RequestError, .unavailable) }
        XCTAssertEqual(oversized.state.requests.count, 1)
    }

    // MARK: Skipper

    func testSkipperReturnsTheSegmentOnlyInsideItsSkippableRange() {
        let segment = SponsorBlockSegment(start: 10, end: 20, category: .sponsor)
        var skipper = SegmentSkipper(segments: [segment])
        XCTAssertNil(skipper.skipTarget(at: 9.9, uptime: 100))
        XCTAssertNil(skipper.skipTarget(at: 20, uptime: 100))
        XCTAssertNil(skipper.skipTarget(at: 19.9, uptime: 100), "The last quarter second is shorter than a tick")
        XCTAssertEqual(skipper.skipTarget(at: 19.75, uptime: 100), segment)
        XCTAssertEqual(skipper.skippedCount, 1)
        var fromStart = SegmentSkipper(segments: [segment])
        XCTAssertEqual(fromStart.skipTarget(at: 10, uptime: 100), segment)
        XCTAssertNil(fromStart.skipTarget(at: .nan, uptime: 100))
    }

    func testSkipperSkipsEachSegmentOncePerPlayUntilRestart() {
        let intro = SponsorBlockSegment(start: 0, end: 5, category: .intro)
        let talk = SponsorBlockSegment(start: 30, end: 40, category: .musicOfftopic)
        var skipper = SegmentSkipper(segments: [intro, talk])
        XCTAssertEqual(skipper.skipTarget(at: 0.5, uptime: 100), intro)
        XCTAssertNil(skipper.skipTarget(at: 1, uptime: 101), "A seek back into a skipped segment plays it through")
        XCTAssertEqual(skipper.skipTarget(at: 31, uptime: 130), talk)
        XCTAssertNil(skipper.skipTarget(at: 35, uptime: 131))
        XCTAssertEqual(skipper.skippedCount, 2)
        skipper.restart()
        XCTAssertEqual(skipper.skippedCount, 0)
        XCTAssertEqual(skipper.skipTarget(at: 1, uptime: 200), intro)
        skipper.install([talk])
        XCTAssertEqual(skipper.segments, [talk])
        XCTAssertEqual(skipper.skippedCount, 0)
        XCTAssertEqual(skipper.skipTarget(at: 31, uptime: 230), talk)
    }

    func testManualSeekGraceHoldsSkipsForTenSecondsAndSurvivesInstall() {
        let talk = SponsorBlockSegment(start: 30, end: 40, category: .musicOfftopic)
        var skipper = SegmentSkipper(segments: [talk])
        skipper.noteManualSeek(uptime: 100)
        XCTAssertNil(skipper.skipTarget(at: 31, uptime: 100.5))
        XCTAssertNil(skipper.skipTarget(at: 35, uptime: 109.9))
        XCTAssertEqual(skipper.skipTarget(at: 36, uptime: 110), talk)
        var late = SegmentSkipper()
        late.noteManualSeek(uptime: 100)
        late.install([talk])
        XCTAssertNil(late.skipTarget(at: 31, uptime: 105), "Segments arriving after a seek respect the same grace")
        XCTAssertEqual(late.skipTarget(at: 31, uptime: 111), talk)
        var restarted = SegmentSkipper(segments: [talk])
        restarted.noteManualSeek(uptime: 100)
        restarted.restart()
        XCTAssertEqual(restarted.skipTarget(at: 31, uptime: 101), talk, "A new play clears the grace")
    }

    // MARK: Controller

    func testYouTubeSongJumpsPastAnInjectedSegmentAndListeningExcludesTheJump() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let track = Track(id: "JGwWNGJdvx8", title: "Skip fixture", duration: 10)
        let provider = SponsorBlockProviderGate([track.id: [SponsorBlockSegment(start: 2, end: 5, category: .musicOfftopic)]])
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 10))
        defer { player.pause() }
        player.sponsorBlockProvider = provider
        player.setSponsorBlockSkipping(true)
        var listened: TimeInterval = 0
        player.onListeningProgress = { _, _, _, delta in listened += delta; return true }
        var positions: [TimeInterval] = []
        player.play([track])
        try await PlaybackTestSupport.waitUntil(timeout: 8) {
            positions.append(player.position)
            return player.position >= 5.5
        }
        XCTAssertTrue(positions.contains { $0 > 0.2 && $0 < 2.6 }, "Playback started from the beginning: \(positions)")
        XCTAssertFalse(positions.contains { $0 > 2.7 && $0 < 4.9 }, "The middle of the segment must never be reached: \(positions)")
        XCTAssertEqual(player.sponsorBlockSkipCount, 1)
        XCTAssertEqual(player.sponsorBlockSegments.count, 1)
        let requests = await provider.requests
        XCTAssertEqual(requests, [track.id])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position >= 6 }
        player.flushListeningProgress()
        let position = player.position
        XCTAssertLessThan(listened, position - 2.4, "Listening time must exclude the 3 s jump")
        XCTAssertGreaterThan(listened, 1)
        XCTAssertNil(player.errorMessage)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(player.sponsorBlockSkipCount, 1, "A segment skips once per play")
    }

    func testPreferenceOffMeansNoLookupAndNoSkip() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 8)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let track = Track(id: "JGwWNGJdvx8", title: "Untouched", duration: 8)
        let provider = SponsorBlockProviderGate([track.id: [SponsorBlockSegment(start: 1, end: 4, category: .sponsor)]])
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 8))
        defer { player.pause() }
        player.sponsorBlockProvider = provider
        player.play([track])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 2.2 }
        XCTAssertLessThan(player.position, 3.8, "Without the preference the segment plays through")
        XCTAssertEqual(player.sponsorBlockSkipCount, 0)
        XCTAssertTrue(player.sponsorBlockSegments.isEmpty)
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOnlyValidYouTubeIDsAreLookedUp() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = SponsorBlockProviderGate([:])
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 4))
        defer { player.pause() }
        player.sponsorBlockProvider = provider
        player.setSponsorBlockSkipping(true)
        player.play([Track(id: "saavn:123456", title: "Saavn song", duration: 4)])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.5 }
        // Fixture-style ids carry dots, which the 11-character video id shape rejects.
        player.play([Track(id: "fixture.local.audio", title: "Local file", duration: 4)])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.5 }
        var requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
        player.play([Track(id: "BddP6PYo2gs", title: "YouTube song", duration: 4)])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.5 }
        requests = await provider.requests
        XCTAssertEqual(requests, ["BddP6PYo2gs"])
    }

    func testTurningTheSettingOffClearsStateAndIgnoresALateLookup() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 8)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let track = Track(id: "JGwWNGJdvx8", title: "Late lookup", duration: 8)
        let provider = SponsorBlockProviderGate([track.id: [SponsorBlockSegment(start: 1, end: 6, category: .sponsor)]], holds: true)
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 8))
        defer { player.pause() }
        player.sponsorBlockProvider = provider
        player.setSponsorBlockSkipping(true)
        player.play([track])
        try await PlaybackTestSupport.eventually { await provider.requests.count == 1 }
        player.setSponsorBlockSkipping(false)
        await provider.release()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.5 }
        XCTAssertTrue(player.sponsorBlockSegments.isEmpty, "A cancelled lookup must not install segments")
        XCTAssertEqual(player.sponsorBlockSkipCount, 0)
        XCTAssertLessThan(player.position, 5)
    }

    func testRestoredSongLooksUpOnlyOncePlaybackStartsAndAManualSeekIsNotSkipped() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let track = Track(id: "JGwWNGJdvx8", title: "Restored", duration: 10)
        let provider = SponsorBlockProviderGate([track.id: [SponsorBlockSegment(start: 4, end: 8, category: .musicOfftopic)]])
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 10))
        defer { player.pause() }
        player.sponsorBlockProvider = provider
        player.setSponsorBlockSkipping(true)
        player.restore(PlaybackSnapshot(queue: [track], position: 1))
        try await Task.sleep(for: .milliseconds(200))
        var requests = await provider.requests
        XCTAssertTrue(requests.isEmpty, "A paused restore sends nothing")
        player.togglePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.3 }
        requests = await provider.requests
        XCTAssertEqual(requests, [track.id])
        try await PlaybackTestSupport.eventually { player.sponsorBlockSegments.count == 1 }
        player.seek(to: 4.5)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 5.5 }
        XCTAssertEqual(player.sponsorBlockSkipCount, 0, "A listener-chosen position inside a segment plays on")
        XCTAssertLessThan(player.position, 7.5)
    }
}
