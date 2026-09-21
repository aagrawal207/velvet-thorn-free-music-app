import XCTest
@testable import GanaBajana

@MainActor
final class ReleaseRefreshRegistrationTests: XCTestCase {
    func testRegistrationBoundaryUsesMainQueueAndCompletesAfterRescheduling() async throws {
        var identifier: String?
        var queue: DispatchQueue?
        var launch: ReleaseRefreshRegistration.LaunchHandler?
        var expiration: (@Sendable () -> Void)?
        var trace: [String] = []
        var completions: [Bool] = []
        let registered = ReleaseRefreshRegistration.register(identifier: "release-test", registrar: { id, target, handler in
            identifier = id
            queue = target
            launch = handler
            return true
        }, operation: {
            XCTAssertTrue(Thread.isMainThread)
            trace.append("check")
        }, reschedule: {
            trace.append("schedule")
        })
        XCTAssertTrue(registered)
        XCTAssertEqual(identifier, "release-test")
        let target = try XCTUnwrap(queue)
        XCTAssertTrue(target === DispatchQueue.main)
        let callback = try XCTUnwrap(launch)
        let handle = ReleaseRefreshRegistration.TaskHandle(installExpiration: { expiration = $0 }, complete: {
            trace.append("complete")
            completions.append($0)
        })
        target.async { MainActor.assumeIsolated { callback(handle) } }
        try await PlaybackTestSupport.waitUntil { completions.count == 1 }
        XCTAssertNotNil(expiration)
        XCTAssertEqual(trace, ["check", "schedule", "complete"])
        XCTAssertEqual(completions, [true])
    }

    func testExpirationBoundaryCancelsAuthorizationAndNextCheckDeliversPersistedPendingReleases() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajana-RefreshBoundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let time = RecommendationFixtures.now
        let library = LibraryStore(directory: directory, now: { time })
        library.follow(FollowedArtist(id: "artist", name: "Artist", followedAt: time, knownReleaseIDs: ["old"]))
        let catalog = RecommendationCatalogMock()
        let page = RecommendationFixtures.page("artist", name: "Artist", releases: [
            RecommendationFixtures.release("first", title: "First", subtitle: "Single • 2026"),
            RecommendationFixtures.release("second", title: "Second", subtitle: "Single • 2026"),
        ])
        await catalog.setArtist(page)
        let notifier = ReleaseDeliveryNotifier()
        addTeardownBlock { await notifier.close() }
        await notifier.pauseNextAuthorization()
        let watcher = ReleaseWatcher(library: library, catalog: catalog, notifier: notifier, now: { time })
        var launch: ReleaseRefreshRegistration.LaunchHandler?
        var expiration: (@Sendable () -> Void)?
        var completed: [Bool] = []
        var recorded: [Int] = []
        var reschedules = 0
        XCTAssertTrue(ReleaseRefreshRegistration.register(identifier: "release-test", registrar: { _, queue, handler in
            XCTAssertTrue(queue === DispatchQueue.main)
            launch = handler
            return true
        }, operation: {
            recorded.append(await watcher.checkNow())
        }, reschedule: {
            reschedules += 1
        }))
        let callback = try XCTUnwrap(launch)
        callback(ReleaseRefreshRegistration.TaskHandle(installExpiration: { expiration = $0 }, complete: { completed.append($0) }))
        let authorization = try await notifier.authorizations.request(at: 0)
        XCTAssertEqual(library.pendingReleaseNotifications.map(\.id), ["first", "second"])
        let expire = try XCTUnwrap(expiration)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                XCTAssertFalse(Thread.isMainThread)
                expire()
                continuation.resume()
            }
        }
        try await notifier.authorizations.complete(authorization, with: .success(true))
        try await PlaybackTestSupport.waitUntil { completed.count == 1 }
        XCTAssertEqual(completed, [false])
        XCTAssertEqual(recorded, [2])
        XCTAssertEqual(reschedules, 1)
        XCTAssertEqual(library.pendingReleaseNotifications.map(\.id), ["first", "second"])
        let beforeRetry = await notifier.notified
        XCTAssertTrue(beforeRetry.isEmpty)

        let retryCount = await watcher.checkNow()
        XCTAssertEqual(retryCount, 0)
        let notified = await notifier.notified
        let requests = await catalog.artistRequests
        XCTAssertEqual(notified.map(\.id), ["first", "second"])
        XCTAssertEqual(requests, ["artist"])
        XCTAssertEqual(library.releases.map(\.id), ["first", "second"])
        XCTAssertTrue(library.pendingReleaseNotifications.isEmpty)
    }
}
