import XCTest
@testable import GanaBajana

@MainActor
final class ReleaseWatcherTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures

    private struct Harness {
        let library: LibraryStore
        let catalog: RecommendationCatalogMock
        let notifier: ReleaseNotifierMock
        let clock: RecommendationTestClock
        let watcher: ReleaseWatcher
    }

    private func makeHarness(library: LibraryStore, authorized: Bool = true) -> Harness {
        let catalog = RecommendationCatalogMock()
        let notifier = ReleaseNotifierMock(authorized: authorized)
        let clock = RecommendationTestClock()
        let watcher = ReleaseWatcher(library: library, catalog: catalog, notifier: notifier, now: { clock.now })
        return Harness(library: library, catalog: catalog, notifier: notifier, clock: clock, watcher: watcher)
    }

    private func baselinePage(_ extra: [MusicCollection] = []) -> ArtistPage {
        Fixtures.page("UCa", name: "Artist A", releases: [
            Fixtures.release("r1", title: "Album One", subtitle: "Album • 2026"),
            Fixtures.release("r2", title: "Old Album", subtitle: "Album • 2019"),
        ] + extra)
    }

    private func known(_ library: LibraryStore, _ artistID: String) -> [String] {
        library.followedArtists.first { $0.id == artistID }?.knownReleaseIDs ?? []
    }

    func testFirstCheckSeedsTheBaselineWithoutAnnouncing() async throws {
        try await withRecommendationLibrary { library in
            let harness = makeHarness(library: library)
            await harness.catalog.setArtist(baselinePage())
            library.follow(FollowedArtist(id: "UCa", name: "Artist A"))

            let count = await harness.watcher.checkNow()
            XCTAssertEqual(count, 0)
            XCTAssertEqual(known(library, "UCa"), ["r1", "r2"])
            XCTAssertEqual(library.followedArtists.first?.lastCheckedAt, harness.clock.now)
            XCTAssertEqual(library.followedArtists.first?.hasEstablishedReleaseBaseline, true)
            XCTAssertTrue(library.releases.isEmpty)
            let notified = await harness.notifier.notified
            let authorizations = await harness.notifier.authorizationRequests
            XCTAssertTrue(notified.isEmpty)
            XCTAssertEqual(authorizations, 0, "Nothing to announce means no permission prompt")
        }
    }

    func testSecondCheckAnnouncesExactlyTheNewCurrentYearRelease() async throws {
        try await withRecommendationLibrary { library in
            let harness = makeHarness(library: library)
            await harness.catalog.setArtist(baselinePage())
            library.follow(FollowedArtist(id: "UCa", name: "Artist A"))
            _ = await harness.watcher.checkNow()

            await harness.catalog.setArtist(baselinePage([Fixtures.release("r3", title: "New Single", subtitle: "Single • 2026")]))
            harness.clock.advance(by: 7 * 3600)
            let count = await harness.watcher.checkNow()
            XCTAssertEqual(count, 1)
            XCTAssertEqual(known(library, "UCa"), ["r1", "r2", "r3"])
            XCTAssertEqual(library.releases.map(\.id), ["r3"])
            XCTAssertEqual(library.releases.first?.artistName, "Artist A")
            XCTAssertEqual(library.releases.first?.discoveredAt, harness.clock.now)
            XCTAssertEqual(library.unseenReleaseCount, 1)
            let notified = await harness.notifier.notified
            XCTAssertEqual(notified.map(\.id), ["r3"])
            XCTAssertEqual(notified.first?.title, "New Single")

            harness.clock.advance(by: 7 * 3600)
            let repeated = await harness.watcher.checkNow()
            XCTAssertEqual(repeated, 0, "A release is announced once")
            let notifiedAgain = await harness.notifier.notified
            XCTAssertEqual(notifiedAgain.count, 1)
        }
    }

    func testPreviousYearCountsAsNewButOlderCatalogReshufflesDoNot() async throws {
        try await withRecommendationLibrary { library in
            let harness = makeHarness(library: library)
            await harness.catalog.setArtist(baselinePage())
            library.follow(FollowedArtist(id: "UCa", name: "Artist A"))
            _ = await harness.watcher.checkNow()

            await harness.catalog.setArtist(baselinePage([
                Fixtures.release("r4", title: "Remaster", subtitle: "Album • 2015"),
                Fixtures.release("r5", title: "Last Year", subtitle: "EP • 2025 • 6 songs"),
                Fixtures.release("r6", title: "Undated", subtitle: "Album"),
            ]))
            let count = await harness.watcher.checkNow(force: true)
            XCTAssertEqual(count, 1)
            XCTAssertEqual(known(library, "UCa"), ["r1", "r2", "r4", "r5", "r6"], "Old and undated releases are remembered, not announced")
            XCTAssertEqual(library.releases.map(\.id), ["r5"])
            let notified = await harness.notifier.notified
            XCTAssertEqual(notified.map(\.id), ["r5"])
        }
    }

    func testUnfollowedArtistsAreSkippedEvenMidCheck() async throws {
        try await withRecommendationLibrary { library in
            let harness = makeHarness(library: library)
            await harness.catalog.setArtist(baselinePage())
            await harness.catalog.setArtist(Fixtures.page("UCb", name: "Artist B", releases: [Fixtures.release("b1", title: "B One", subtitle: "Album • 2026")]))
            await harness.catalog.setArtist(Fixtures.page("UCc", name: "Artist C", releases: [Fixtures.release("c1", title: "C One", subtitle: "Album • 2026")]))
            library.follow(FollowedArtist(id: "UCa", name: "Artist A"))
            library.follow(FollowedArtist(id: "UCb", name: "Artist B"))
            library.follow(FollowedArtist(id: "UCc", name: "Artist C", knownReleaseIDs: ["c0"]))
            library.unfollow(artistID: "UCb")
            await harness.catalog.setBeforeArtist { id in
                guard id == "UCc" else { return }
                await MainActor.run { library.unfollow(artistID: "UCc") }
            }

            let count = await harness.watcher.checkNow()
            XCTAssertEqual(count, 0, "The artist unfollowed while loading contributes nothing")
            let requests = await harness.catalog.artistRequests
            XCTAssertEqual(Set(requests), ["UCa", "UCc"])
            XCTAssertEqual(library.followedArtists.map(\.id), ["UCa"])
            XCTAssertTrue(library.releases.isEmpty)
            XCTAssertEqual(known(library, "UCa"), ["r1", "r2"])
        }
    }

    func testArtistsAreOnlyRecheckedAfterSixHoursUnlessForced() async throws {
        try await withRecommendationLibrary { library in
            let harness = makeHarness(library: library)
            await harness.catalog.setArtist(baselinePage())
            library.follow(FollowedArtist(id: "UCa", name: "Artist A"))
            _ = await harness.watcher.checkNow()
            var requests = await harness.catalog.artistRequests
            XCTAssertEqual(requests.count, 1)

            harness.clock.advance(by: 6 * 3600 - 1)
            _ = await harness.watcher.checkNow()
            requests = await harness.catalog.artistRequests
            XCTAssertEqual(requests.count, 1, "Still inside the throttle window")

            _ = await harness.watcher.checkNow(force: true)
            requests = await harness.catalog.artistRequests
            XCTAssertEqual(requests.count, 2, "Force bypasses the throttle")

            harness.clock.advance(by: 6 * 3600)
            _ = await harness.watcher.checkNow()
            requests = await harness.catalog.artistRequests
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(library.followedArtists.first?.lastCheckedAt, harness.clock.now)
        }
    }

    func testDisabledAlertsRecordReleasesWithoutNotifying() async throws {
        try await withRecommendationLibrary { library in
            let harness = makeHarness(library: library)
            var preferences = library.preferences
            preferences.newReleaseAlerts = false
            library.preferences = preferences
            await harness.catalog.setArtist(baselinePage())
            library.follow(FollowedArtist(id: "UCa", name: "Artist A", knownReleaseIDs: ["r2"]))

            let count = await harness.watcher.checkNow()
            XCTAssertEqual(count, 1)
            XCTAssertEqual(library.releases.map(\.id), ["r1"])
            XCTAssertEqual(known(library, "UCa"), ["r1", "r2"])
            let notified = await harness.notifier.notified
            let authorizations = await harness.notifier.authorizationRequests
            XCTAssertTrue(notified.isEmpty)
            XCTAssertEqual(authorizations, 0)
        }
    }

    func testDeniedNotificationPermissionStillRecordsReleases() async throws {
        try await withRecommendationLibrary { library in
            let harness = makeHarness(library: library, authorized: false)
            await harness.catalog.setArtist(baselinePage())
            library.follow(FollowedArtist(id: "UCa", name: "Artist A", knownReleaseIDs: ["r2"]))

            let count = await harness.watcher.checkNow()
            XCTAssertEqual(count, 1)
            XCTAssertEqual(library.releases.map(\.id), ["r1"])
            let notified = await harness.notifier.notified
            let authorizations = await harness.notifier.authorizationRequests
            XCTAssertTrue(notified.isEmpty)
            XCTAssertEqual(authorizations, 1)
        }
    }

    func testEachRunChecksAtMostEightArtistsOldestFirst() async throws {
        try await withRecommendationLibrary { library in
            let harness = makeHarness(library: library)
            let followedAt = Fixtures.now.addingTimeInterval(-86_400)
            for index in 0..<10 {
                let id = String(format: "UC%02d", index)
                await harness.catalog.setArtist(Fixtures.page(id, name: "Artist \(id)", releases: [Fixtures.release("\(id)-1", title: "One", subtitle: "Album • 2026")]))
                library.follow(FollowedArtist(id: id, name: "Artist \(id)", followedAt: followedAt.addingTimeInterval(Double(index))))
            }

            _ = await harness.watcher.checkNow()
            var requests = await harness.catalog.artistRequests
            XCTAssertEqual(Set(requests), Set((0..<8).map { String(format: "UC%02d", $0) }), "Earliest follows are checked first")
            XCTAssertEqual(library.followedArtists.filter { $0.lastCheckedAt == nil }.map(\.id).sorted(), ["UC08", "UC09"])

            harness.clock.advance(by: 60)
            _ = await harness.watcher.checkNow()
            requests = await harness.catalog.artistRequests
            XCTAssertEqual(Set(requests.dropFirst(8)), ["UC08", "UC09"], "Never-checked artists jump the queue")
            XCTAssertTrue(library.followedArtists.allSatisfy { $0.lastCheckedAt != nil })

            harness.clock.advance(by: 6 * 3600)
            _ = await harness.watcher.checkNow()
            requests = await harness.catalog.artistRequests
            XCTAssertEqual(requests.count, 18)
            XCTAssertEqual(Set(requests.dropFirst(10)), Set((0..<8).map { String(format: "UC%02d", $0) }), "The stalest checks come back first")
        }
    }

    func testOneBrokenArtistNeitherBlocksOthersNorMonopolizesLaterRuns() async throws {
        try await withRecommendationLibrary { library in
            let harness = makeHarness(library: library)
            await harness.catalog.setArtist(baselinePage())
            await harness.catalog.failArtist("UCbroken")
            library.follow(FollowedArtist(id: "UCbroken", name: "Broken", followedAt: Fixtures.now.addingTimeInterval(-7_200)))
            library.follow(FollowedArtist(id: "UCa", name: "Artist A", knownReleaseIDs: ["r2"]))

            let count = await harness.watcher.checkNow()
            XCTAssertEqual(count, 1)
            XCTAssertEqual(library.releases.map(\.id), ["r1"])
            let broken = try XCTUnwrap(library.followedArtists.first { $0.id == "UCbroken" })
            XCTAssertEqual(broken.lastCheckedAt, harness.clock.now, "A failed attempt still counts as an attempt")
            XCTAssertTrue(broken.knownReleaseIDs.isEmpty, "Failures never fake a baseline")
            XCTAssertFalse(broken.hasEstablishedReleaseBaseline)

            harness.clock.advance(by: 60)
            _ = await harness.watcher.checkNow()
            let requests = await harness.catalog.artistRequests
            XCTAssertEqual(requests.count, 2, "Within the throttle window the broken artist is left alone")
        }
    }

    func testOverlappingChecksDoNotRunTwice() async throws {
        try await withRecommendationLibrary { library in
            let harness = makeHarness(library: library)
            await harness.catalog.setArtist(baselinePage())
            library.follow(FollowedArtist(id: "UCa", name: "Artist A"))
            async let first = harness.watcher.checkNow()
            async let second = harness.watcher.checkNow()
            _ = await (first, second)
            let requests = await harness.catalog.artistRequests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testReleaseYearReadsTheFirstPlausibleFourDigitYear() {
        XCTAssertEqual(ReleaseWatcher.releaseYear(from: "Album • 2025"), 2025)
        XCTAssertEqual(ReleaseWatcher.releaseYear(from: "Single • 1998"), 1998)
        XCTAssertEqual(ReleaseWatcher.releaseYear(from: "Compilation • 2024 • 12 songs"), 2024)
        XCTAssertEqual(ReleaseWatcher.releaseYear(from: "2026"), 2026)
        XCTAssertNil(ReleaseWatcher.releaseYear(from: "EP"))
        XCTAssertNil(ReleaseWatcher.releaseYear(from: ""))
        XCTAssertNil(ReleaseWatcher.releaseYear(from: "12345 songs"))
        XCTAssertNil(ReleaseWatcher.releaseYear(from: "Album • 1899"))
        XCTAssertNil(ReleaseWatcher.releaseYear(from: "Album • 2100"))
        XCTAssertEqual(ReleaseWatcher.releaseYear(from: "Album • 20255 • 2023"), 2023, "Over-long digit runs are not years")
    }
}
