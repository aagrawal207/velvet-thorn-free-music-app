import UserNotifications
import XCTest
@testable import GanaBajana

@MainActor
final class ReleaseNotificationRoutingTests: XCTestCase {
    func testDefaultTapOpensExactReleaseAndPreservesPlaybackFromCoveredScreen() async throws {
        let song = AppModelFixtures.track("current")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song, song], currentIndex: 1, position: 37))
        let model = context.model
        model.setReleaseNotificationNavigationReady(true)
        model.selectedTab = .search
        model.isPlayerPresented = true
        model.isSettingsPresented = true
        let controls = context.player.controlRevision
        let presenter = ForegroundNotificationPresenter { model.receiveReleaseNotification($0) }

        await presenter.handle(request: request("release.saavn:album:chosen", title: "Chosen Single"),
                               actionIdentifier: UNNotificationDefaultActionIdentifier).value

        XCTAssertEqual(model.selectedTab, .library)
        XCTAssertEqual(model.navigationPaths[.library]?.map(\.id), ["saavn:album:chosen"])
        XCTAssertEqual(model.navigationPaths[.library]?.last?.title, "Chosen Single")
        XCTAssertEqual(model.navigationPaths[.library]?.last?.kind, .album)
        XCTAssertFalse(model.isPlayerPresented)
        XCTAssertFalse(model.isSettingsPresented)
        XCTAssertEqual(context.player.queue, [song, song])
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.position, 37)
        XCTAssertEqual(context.player.controlRevision, controls)
        XCTAssertFalse(context.player.isPlaying)
    }

    func testColdLaunchKeepsLatestTapUntilNavigationIsReadyAndConsumesItOnce() async throws {
        let context = try makeContext()
        let model = context.model
        let presenter = ForegroundNotificationPresenter { model.receiveReleaseNotification($0) }
        await presenter.handle(request: request("release.first"), actionIdentifier: UNNotificationDefaultActionIdentifier).value
        await presenter.handle(request: request("release.latest"), actionIdentifier: UNNotificationDefaultActionIdentifier).value
        XCTAssertTrue(model.navigationPaths.isEmpty)
        model.setReleaseNotificationNavigationReady(false)
        XCTAssertTrue(model.navigationPaths.isEmpty, "Welcome must finish before navigation")
        model.setReleaseNotificationNavigationReady(true)
        XCTAssertEqual(model.navigationPaths[.library]?.map(\.id), ["latest"])

        model.openLibrary()
        model.setReleaseNotificationNavigationReady(false)
        model.setReleaseNotificationNavigationReady(true)
        XCTAssertEqual(model.navigationPaths[.library], [], "Readiness changes cannot replay a consumed tap")
    }

    func testLegacyAlertUsesSavedMetadataAndMissingReleaseStillOpensByID() async throws {
        let context = try makeContext()
        let release = ArtistRelease(id: "MPREsaved", title: "Saved Album", subtitle: "Album • 2026",
                                    artistID: "UCsaved", artistName: "Saved Artist", discoveredAt: Date())
        context.library.follow(FollowedArtist(id: release.artistID, name: release.artistName))
        XCTAssertTrue(context.library.recordReleaseCheck(artistID: release.artistID, knownReleaseIDs: [release.id],
                                                         newReleases: [release], checkedAt: Date()))
        let model = context.model
        model.setReleaseNotificationNavigationReady(true)
        let presenter = ForegroundNotificationPresenter { model.receiveReleaseNotification($0) }
        await presenter.handle(request: request(release.notificationIdentifier), actionIdentifier: UNNotificationDefaultActionIdentifier).value
        XCTAssertEqual(model.navigationPaths[.library]?.last?.title, "Saved Album")
        XCTAssertEqual(model.navigationPaths[.library]?.last?.subtitle, "Album • 2026")
        await presenter.handle(request: request("release.MPREremoved"), actionIdentifier: UNNotificationDefaultActionIdentifier).value
        XCTAssertEqual(model.navigationPaths[.library]?.map(\.id), ["MPREremoved"])
        XCTAssertEqual(model.navigationPaths[.library]?.last?.title, "New Release")
    }

    func testDismissUnknownActionsAndMalformedIdentifiersDoNotNavigate() async throws {
        let context = try makeContext()
        let model = context.model
        model.setReleaseNotificationNavigationReady(true)
        model.selectedTab = .recap
        let presenter = ForegroundNotificationPresenter { model.receiveReleaseNotification($0) }
        for action in [UNNotificationDismissActionIdentifier, "unknown"] {
            await presenter.handle(request: request("release.valid"), actionIdentifier: action).value
        }
        for id in ["other.valid", "release.", "release. ", "release.id\n", "release." + String(repeating: "x", count: 513)] {
            await presenter.handle(request: request(id), actionIdentifier: UNNotificationDefaultActionIdentifier).value
        }
        XCTAssertEqual(model.selectedTab, .recap)
        XCTAssertTrue(model.navigationPaths.isEmpty)
    }

    func testRepeatedTapReplacesDestinationRatherThanStackingDuplicates() async throws {
        let context = try makeContext()
        let model = context.model
        model.setReleaseNotificationNavigationReady(true)
        model.openCachedSongs()
        let presenter = ForegroundNotificationPresenter { model.receiveReleaseNotification($0) }
        for _ in 0..<2 {
            await presenter.handle(request: request("release.chosen"), actionIdentifier: UNNotificationDefaultActionIdentifier).value
        }
        XCTAssertFalse(model.showsLibraryCachedSongs)
        XCTAssertEqual(model.navigationPaths[.library]?.map(\.id), ["chosen"])
    }

    private func request(_ id: String, title: String? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        if let title { content.userInfo = ["releaseTitle": title] }
        return UNNotificationRequest(identifier: id, content: content, trigger: nil)
    }

    private func makeContext(snapshot: PlaybackSnapshot = PlaybackSnapshot()) throws -> AppModelTestContext {
        let context = try AppModelTestContext(snapshot: snapshot)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
