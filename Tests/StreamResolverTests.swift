import XCTest
@testable import GanaBajana

private actor StreamExtractionFixture {
    var methods: [Bool] = []
    var validations: [URL] = []
    var localEmpty = false
    var rejectLocal = false
    let local = URL(string: "https://local.googlevideo.com/videoplayback?dur=263.267&expire=4000000000")!
    let remote = URL(string: "https://remote.googlevideo.com/videoplayback?dur=263.267&expire=4000000000")!

    func configure(empty: Bool = false, rejected: Bool = false) { localEmpty = empty; rejectLocal = rejected }
    func extract(remote: Bool) -> [URL] {
        methods.append(remote)
        return remote ? [self.remote] : (localEmpty ? [] : [local])
    }
    func validate(_ url: URL) throws {
        validations.append(url)
        if rejectLocal && url == local { throw PlaybackStreamError.httpStatus(403) }
    }
}

final class StreamResolverTests: XCTestCase {
    private let track = Track(id: "JGwWNGJdvx8", title: "Shape of You", duration: 100)

    func testDefaultDoesNotCallRemoteWhenLocalIsEmpty() async {
        let fixture = StreamExtractionFixture()
        await fixture.configure(empty: true)
        let resolver = YouTubeStreamResolver(extract: { _, remote in await fixture.extract(remote: remote) },
                                             validate: { try await fixture.validate($0) })
        do { _ = try await resolver.resolve(track: track, forceRefresh: false); XCTFail("Expected missing audio") }
        catch { XCTAssertTrue(error is PlaybackStreamError) }
        let methods = await fixture.methods
        XCTAssertEqual(methods, [false])
    }

    func testOptedInFallbackCoversEmptyExtractionAndHTTP403() async throws {
        for empty in [true, false] {
            let fixture = StreamExtractionFixture()
            await fixture.configure(empty: empty, rejected: !empty)
            let resolver = YouTubeStreamResolver(allowRemoteFallback: true,
                extract: { _, remote in await fixture.extract(remote: remote) }, validate: { try await fixture.validate($0) })
            let stream = try await resolver.resolve(track: track, forceRefresh: false)
            XCTAssertEqual(stream.url.host, "remote.googlevideo.com")
            XCTAssertEqual(stream.duration, 263.267)
            let methods = await fixture.methods
            XCTAssertEqual(methods, [false, true])
        }
    }

    func testValidatedCacheIsBypassedByForceRefresh() async throws {
        let fixture = StreamExtractionFixture()
        let resolver = YouTubeStreamResolver(extract: { _, remote in await fixture.extract(remote: remote) },
                                             validate: { try await fixture.validate($0) })
        _ = try await resolver.resolve(track: track, forceRefresh: false)
        _ = try await resolver.resolve(track: track, forceRefresh: false)
        _ = try await resolver.resolve(track: track, forceRefresh: true)
        let methods = await fixture.methods
        let validations = await fixture.validations
        XCTAssertEqual(methods, [false, false])
        XCTAssertEqual(validations.count, 2)
    }

    func testDisablingFallbackAppliesToSubsequentRequests() async throws {
        let fixture = StreamExtractionFixture()
        await fixture.configure(empty: true)
        let resolver = YouTubeStreamResolver(allowRemoteFallback: true,
            extract: { _, remote in await fixture.extract(remote: remote) }, validate: { try await fixture.validate($0) })
        await resolver.setRemoteFallbackEnabled(false)
        do { _ = try await resolver.resolve(track: track, forceRefresh: true); XCTFail("Remote must remain opt-in") }
        catch { }
        let methods = await fixture.methods
        XCTAssertEqual(methods, [false])
    }

    func testCancellationDoesNotBecomeRemoteFallback() async throws {
        let fixture = StreamExtractionFixture()
        let resolver = YouTubeStreamResolver(allowRemoteFallback: true, extract: { _, remote in
            _ = await fixture.extract(remote: remote)
            throw CancellationError()
        }, validate: { _ in })
        do { _ = try await resolver.resolve(track: track, forceRefresh: false); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let methods = await fixture.methods
        XCTAssertEqual(methods, [false])
    }

    func testInvalidIDsFailBeforeNetworkAccess() async {
        let fixture = StreamExtractionFixture()
        let resolver = YouTubeStreamResolver(extract: { _, remote in await fixture.extract(remote: remote) }, validate: { _ in })
        do { _ = try await resolver.resolve(track: Track(id: "bad/id", title: "Invalid"), forceRefresh: false); XCTFail("Invalid ID accepted") }
        catch { }
        let methods = await fixture.methods
        XCTAssertTrue(methods.isEmpty)
    }

    /// The production resolver reads the shared registry; the test restores it so no other test inherits a bot check.
    func testRecentBotCheckWithoutSignInTurnsFallbackFailuresIntoSignInGuidance() async {
        struct ExtractionFailure: Error { }
        let registry = YouTubeSessionRegistry.shared
        let session = YouTubeAccountSession(cookies: [StoredCookie(name: "SAPISID", value: "a", domain: ".youtube.com"),
                                                      StoredCookie(name: "SID", value: "b", domain: ".youtube.com")])
        defer { registry.clearBotCheck(); registry.update(session: nil) }
        func failure(_ extract: @escaping YouTubeStreamResolver.Extraction) async -> (any Error)? {
            let resolver = YouTubeStreamResolver(extract: extract, validate: { _ in })
            do { _ = try await resolver.resolve(track: track, forceRefresh: false); return nil }
            catch { return error }
        }
        let generic: YouTubeStreamResolver.Extraction = { _, _ in throw ExtractionFailure() }
        let empty: YouTubeStreamResolver.Extraction = { _, _ in [] }
        let offline: YouTubeStreamResolver.Extraction = { _, _ in throw URLError(.notConnectedToInternet) }

        registry.recordBotCheck()
        for extract in [generic, empty] {
            let error = await failure(extract)
            guard case PlaybackStreamError.signInRequired? = error else { return XCTFail("Expected sign-in guidance, got \(String(describing: error))") }
        }
        guard case MusicServiceError.network? = await failure(offline) else { return XCTFail("A network failure is not a bot gate") }

        registry.update(session: session)
        guard case MusicServiceError.unavailable? = await failure(generic) else { return XCTFail("Signed in, so signing in is not the fix") }
        registry.update(session: nil)

        registry.recordBotCheck(at: Date().addingTimeInterval(-16 * 60))
        guard case MusicServiceError.unavailable? = await failure(generic) else { return XCTFail("A stale bot check is not evidence") }

        registry.clearBotCheck()
        guard case PlaybackStreamError.noAudio? = await failure(empty) else { return XCTFail("Without a bot check, empty extraction stays noAudio") }
    }
}
