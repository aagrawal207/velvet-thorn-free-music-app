import XCTest
@testable import GanaBajana

@MainActor
final class ReleaseWatcherRegressionTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures

    func testSuccessfulEmptyBaselineSurvivesReopenAndFailureThenAnnouncesFirstRelease() async throws {
        let context = try makeContext()
        context.follow(known: [])
        await context.catalog.artists.enqueue(.success(page(releases: [])))
        let baselineCount = await context.watcher.checkNow()
        XCTAssertEqual(baselineCount, 0)
        XCTAssertEqual(context.library.followedArtists.first?.hasEstablishedReleaseBaseline, true)
        XCTAssertEqual(context.library.followedArtists.first?.knownReleaseIDs, [])

        let clock = context.clock
        let reopened = LibraryStore(directory: context.directory, now: { clock.now })
        let watcher = ReleaseWatcher(library: reopened, catalog: context.catalog, notifier: context.notifier, now: { clock.now })
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.followedArtists.first?.hasEstablishedReleaseBaseline, true)
        await context.catalog.artists.enqueue(.failure(RecommendationTestFailure.provider("Temporary catalog outage")))
        let failedCount = await watcher.checkNow(force: true)
        XCTAssertEqual(failedCount, 0)
        XCTAssertEqual(reopened.followedArtists.first?.hasEstablishedReleaseBaseline, true)
        XCTAssertEqual(reopened.followedArtists.first?.knownReleaseIDs, [])

        await context.catalog.artists.enqueue(.success(page(releases: [release("first")])))
        let firstReleaseCount = await watcher.checkNow(force: true)
        XCTAssertEqual(firstReleaseCount, 1)
        XCTAssertEqual(reopened.releases.map(\.id), ["first"])
        await context.catalog.artists.enqueue(.success(page(releases: [release("first")])))
        let repeatedCount = await watcher.checkNow(force: true)
        XCTAssertEqual(repeatedCount, 0)
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), ["first"])
        XCTAssertEqual(LibraryStore(directory: context.directory, now: { clock.now }).releases.map(\.id), ["first"])
    }

    func testFailedInitialLookupSurvivesReopenAndSeedsBackCatalogWithoutFalseAlerts() async throws {
        let context = try makeContext()
        context.follow(known: [])
        await context.catalog.artists.enqueue(.failure(RecommendationTestFailure.provider("Initial lookup failed")))
        let failedCount = await context.watcher.checkNow()
        XCTAssertEqual(failedCount, 0)
        XCTAssertEqual(context.library.followedArtists.first?.lastCheckedAt, context.clock.now)
        XCTAssertEqual(context.library.followedArtists.first?.hasEstablishedReleaseBaseline, false)

        let clock = context.clock
        let reopened = LibraryStore(directory: context.directory, now: { clock.now })
        let watcher = ReleaseWatcher(library: reopened, catalog: context.catalog, notifier: context.notifier, now: { clock.now })
        let backCatalog = [release("already-out"), Fixtures.release("older", title: "Older album", subtitle: "Album • 2019")]
        await context.catalog.artists.enqueue(.success(page(releases: backCatalog)))
        let seedCount = await watcher.checkNow(force: true)
        XCTAssertEqual(seedCount, 0)
        XCTAssertTrue(reopened.releases.isEmpty)
        XCTAssertEqual(reopened.followedArtists.first?.knownReleaseIDs, ["already-out", "older"])
        XCTAssertEqual(reopened.followedArtists.first?.hasEstablishedReleaseBaseline, true)
        let beforeNewRelease = await context.notifier.notified
        let authorizationsBeforeNewRelease = await context.notifier.authorizationRequests
        XCTAssertTrue(beforeNewRelease.isEmpty)
        XCTAssertEqual(authorizationsBeforeNewRelease, 0)

        await context.catalog.artists.enqueue(.success(page(releases: backCatalog + [release("new")])))
        let newCount = await watcher.checkNow(force: true)
        XCTAssertEqual(newCount, 1)
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), ["new"])
    }

    func testFailedEmptyBaselineWriteDoesNotTurnTheNextBackCatalogReadIntoAnAlert() async throws {
        let context = try makeContext()
        context.follow(known: [])
        let task = context.start()
        let request = try await context.catalog.artists.request(at: 0)
        let backup = context.directory.appendingPathComponent("saved-library.json")
        try FileManager.default.moveItem(at: context.fileURL, to: backup)
        try FileManager.default.createDirectory(at: context.fileURL, withIntermediateDirectories: false)
        try await context.catalog.artists.complete(request, with: .success(page(releases: [])))
        let failedCount = await task.value
        XCTAssertEqual(failedCount, 0)
        XCTAssertNotNil(context.library.errorMessage)
        XCTAssertNil(context.library.followedArtists.first?.lastCheckedAt)
        XCTAssertEqual(context.library.followedArtists.first?.hasEstablishedReleaseBaseline, false)

        try FileManager.default.removeItem(at: context.fileURL)
        try FileManager.default.moveItem(at: backup, to: context.fileURL)
        await context.catalog.artists.enqueue(.success(page(releases: [release("already-out")])))
        let seedCount = await context.watcher.checkNow()
        XCTAssertEqual(seedCount, 0)
        XCTAssertNil(context.library.errorMessage)
        XCTAssertEqual(context.library.followedArtists.first?.hasEstablishedReleaseBaseline, true)
        XCTAssertEqual(context.library.followedArtists.first?.knownReleaseIDs, ["already-out"])
        XCTAssertTrue(context.library.releases.isEmpty)
        let notified = await context.notifier.notified
        XCTAssertTrue(notified.isEmpty)
    }

    func testExternalConflictDuringCatalogReadRequiresReopenBeforeOneAnnouncement() async throws {
        let context = try makeContext()
        context.follow()
        let pending = context.start()
        let request = try await context.catalog.artists.request(at: 0)
        let clock = context.clock
        let external = LibraryStore(directory: context.directory, now: { clock.now })
        let favorite = libraryTestTrack("external-favorite")
        external.toggleFavorite(favorite)
        XCTAssertTrue(external.recordTip(transactionID: 42, credited: true))
        XCTAssertNil(external.errorMessage)
        let externalBytes = try Data(contentsOf: context.fileURL)
        let catalogPage = page(releases: [release("old"), release("new")])
        try await context.catalog.artists.complete(request, with: .success(catalogPage))
        let failedCount = await pending.value
        XCTAssertEqual(failedCount, 0)
        XCTAssertNotNil(context.library.errorMessage)
        XCTAssertNil(context.library.followedArtists.first?.lastCheckedAt)
        XCTAssertEqual(context.library.followedArtists.first?.knownReleaseIDs, ["old"])
        XCTAssertTrue(context.library.releases.isEmpty)
        XCTAssertEqual(try Data(contentsOf: context.fileURL), externalBytes)
        let earlyNotifications = await context.notifier.notified
        let earlyAuthorizations = await context.notifier.authorizationRequests
        XCTAssertTrue(earlyNotifications.isEmpty)
        XCTAssertEqual(earlyAuthorizations, 0)

        await context.catalog.artists.enqueue(.success(catalogPage))
        let staleRetryCount = await context.watcher.checkNow(force: true)
        XCTAssertEqual(staleRetryCount, 0)
        XCTAssertEqual(try Data(contentsOf: context.fileURL), externalBytes)
        let reopened = LibraryStore(directory: context.directory, now: { clock.now })
        let watcher = ReleaseWatcher(library: reopened, catalog: context.catalog, notifier: context.notifier, now: { clock.now })
        await context.catalog.artists.enqueue(.success(catalogPage))
        let recoveredCount = await watcher.checkNow()
        XCTAssertEqual(recoveredCount, 1)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.favorites, [favorite])
        XCTAssertEqual(reopened.tipCredit(for: 42), true)
        XCTAssertEqual(reopened.releases.map(\.id), ["new"])
        await context.catalog.artists.enqueue(.success(catalogPage))
        let repeatedCount = await watcher.checkNow(force: true)
        XCTAssertEqual(repeatedCount, 0)
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), ["new"])
    }

    func testStorageFailureDuringCatalogReadRetriesWithoutAnEarlyOrDuplicateAnnouncement() async throws {
        let context = try makeContext()
        context.follow()
        let pending = context.start()
        let request = try await context.catalog.artists.request(at: 0)
        let saved = try Data(contentsOf: context.fileURL)
        let backup = context.directory.appendingPathComponent("saved-library.json")
        try FileManager.default.moveItem(at: context.fileURL, to: backup)
        try FileManager.default.createDirectory(at: context.fileURL, withIntermediateDirectories: false)
        let catalogPage = page(releases: [release("old"), release("new")])
        try await context.catalog.artists.complete(request, with: .success(catalogPage))
        let failedCount = await pending.value
        XCTAssertEqual(failedCount, 0)
        XCTAssertNotNil(context.library.errorMessage)
        XCTAssertEqual(context.library.followedArtists.first?.knownReleaseIDs, ["old"])
        XCTAssertNil(context.library.followedArtists.first?.lastCheckedAt)
        XCTAssertTrue(context.library.releases.isEmpty)
        XCTAssertEqual(try Data(contentsOf: backup), saved)
        let earlyNotifications = await context.notifier.notified
        let earlyAuthorizations = await context.notifier.authorizationRequests
        XCTAssertTrue(earlyNotifications.isEmpty)
        XCTAssertEqual(earlyAuthorizations, 0)

        try FileManager.default.removeItem(at: context.fileURL)
        try FileManager.default.moveItem(at: backup, to: context.fileURL)
        await context.catalog.artists.enqueue(.success(catalogPage))
        let recoveredCount = await context.watcher.checkNow()
        XCTAssertEqual(recoveredCount, 1)
        XCTAssertNil(context.library.errorMessage)
        let clock = context.clock
        let reopened = LibraryStore(directory: context.directory, now: { clock.now })
        XCTAssertEqual(reopened.releases.map(\.id), ["new"])
        XCTAssertEqual(reopened.followedArtists.first?.knownReleaseIDs, ["new", "old"])
        let watcher = ReleaseWatcher(library: reopened, catalog: context.catalog, notifier: context.notifier, now: { clock.now })
        await context.catalog.artists.enqueue(.success(catalogPage))
        let repeatedCount = await watcher.checkNow(force: true)
        XCTAssertEqual(repeatedCount, 0)
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), ["new"])
    }

    func testOnlyRetainedReleasesAreCountedAndAnnouncedWhenACatalogPageExceedsTheLibraryLimit() async throws {
        let context = try makeContext()
        context.follow()
        let releases = (1...61).map { release("new-\($0)") }
        await context.catalog.artists.enqueue(.success(page(releases: releases)))
        let count = await context.watcher.checkNow()
        XCTAssertEqual(count, 60)
        let expectedIDs = (1...60).map { "new-\($0)" }
        XCTAssertEqual(context.library.releases.map(\.id), expectedIDs)
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), expectedIDs)
        let clock = context.clock
        XCTAssertEqual(LibraryStore(directory: context.directory, now: { clock.now }).releases.map(\.id), expectedIDs)
    }

    func testDisablingAlertsDuringAuthorizationSuppressesDelivery() async throws {
        try await assertAuthorizationChange(.disableAlerts)
    }

    func testUnfollowingDuringAuthorizationSuppressesDelivery() async throws {
        try await assertAuthorizationChange(.unfollow)
    }

    func testCancellationDuringAuthorizationSuppressesDeliveryEvenIfPermissionArrivesLate() async throws {
        try await assertAuthorizationChange(.cancel)
    }

    func testDisablingAlertsDuringFirstSubmissionStopsLaterNotifications() async throws {
        try await assertSubmissionChange(.disableAlerts)
    }

    func testUnfollowingDuringFirstSubmissionStopsThatArtistsRemainingNotifications() async throws {
        try await assertSubmissionChange(.unfollow)
    }

    func testCancellationDuringFirstSubmissionStopsLaterNotifications() async throws {
        try await assertSubmissionChange(.cancel)
    }

    func testUnfollowingOneArtistDuringDeliveryStillNotifiesTheOtherFollowedArtist() async throws {
        for duringAuthorization in [true, false] {
            let context = try makeContext()
            context.follow(id: "a")
            context.follow(id: "b")
            if duringAuthorization { await context.notifier.pauseNextAuthorization() }
            else { await context.notifier.pauseNextSubmission() }
            let task = context.start()
            for index in 0..<2 {
                let request = try await context.catalog.artists.request(at: index)
                let additions = request.input == "a" ? [release("a1"), release("a2")] : [release("b1")]
                try await context.catalog.artists.complete(request, with: .success(page(id: request.input, releases: additions)))
            }

            if duringAuthorization {
                let request = try await context.notifier.authorizations.request(at: 0)
                context.library.unfollow(artistID: "a")
                try await context.notifier.authorizations.complete(request, with: .success(true))
            } else {
                let request = try await context.notifier.submissions.request(at: 0)
                XCTAssertEqual(request.input.id, "a1")
                context.library.unfollow(artistID: "a")
                try await context.notifier.submissions.complete(request, with: .success(()))
            }
            let count = await task.value
            XCTAssertEqual(count, 3, "The return value counts persisted releases, not notification delivery")
            XCTAssertEqual(context.library.releases.map(\.id), ["b1"])
            let notified = await context.notifier.notified
            XCTAssertEqual(notified.map(\.id), duringAuthorization ? ["b1"] : ["a1", "b1"])
        }
    }

    func testUnfollowAndRefollowDuringAuthorizationDoesNotDeliverTheRemovedRelease() async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("new")])))
        await context.notifier.pauseNextAuthorization()
        let task = context.start()
        let request = try await context.notifier.authorizations.request(at: 0)
        XCTAssertEqual(context.library.releases.map(\.id), ["new"])
        context.library.unfollow(artistID: "artist")
        context.follow(known: ["old", "new"])
        try await context.notifier.authorizations.complete(request, with: .success(true))
        let count = await task.value
        XCTAssertEqual(count, 1)
        XCTAssertTrue(context.library.isFollowing(artistID: "artist"))
        XCTAssertTrue(context.library.releases.isEmpty)
        let notified = await context.notifier.notified
        XCTAssertTrue(notified.isEmpty)
    }

    func testCancellationDuringCatalogReadDoesNotPersistLateResultsAndCanRetry() async throws {
        let context = try makeContext()
        context.follow()
        let saved = try Data(contentsOf: context.fileURL)
        let task = context.start()
        let request = try await context.catalog.artists.request(at: 0)
        task.cancel()
        let catalogPage = page(releases: [release("old"), release("new")])
        try await context.catalog.artists.complete(request, with: .success(catalogPage))
        let cancelledCount = await task.value
        XCTAssertEqual(cancelledCount, 0)
        XCTAssertEqual(try Data(contentsOf: context.fileURL), saved)
        let earlyNotifications = await context.notifier.notified
        XCTAssertTrue(earlyNotifications.isEmpty)
        await context.catalog.artists.enqueue(.success(catalogPage))
        let retryCount = await context.watcher.checkNow()
        XCTAssertEqual(retryCount, 1)
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), ["new"])
    }

    func testCancelledAuthorizationRetriesPersistedPendingReleasesOnTheNextForcedCheck() async throws {
        let context = try makeContext()
        context.follow()
        let catalogPage = page(releases: [release("first"), release("second")])
        await context.catalog.artists.enqueue(.success(catalogPage))
        await context.notifier.pauseNextAuthorization()
        let task = context.start()
        let authorization = try await context.notifier.authorizations.request(at: 0)
        XCTAssertEqual(context.library.pendingReleaseNotifications.map(\.id), ["first", "second"])
        task.cancel()
        try await context.notifier.authorizations.complete(authorization, with: .success(true))
        let recorded = await task.value
        XCTAssertEqual(recorded, 2)
        let beforeRetry = await context.notifier.notified
        XCTAssertTrue(beforeRetry.isEmpty)

        let clock = context.clock
        let reopened = LibraryStore(directory: context.directory, now: { clock.now })
        XCTAssertEqual(reopened.pendingReleaseNotifications.map(\.id), ["first", "second"])
        let watcher = ReleaseWatcher(library: reopened, catalog: context.catalog, notifier: context.notifier, now: { clock.now })
        await context.catalog.artists.enqueue(.success(catalogPage))
        let newlyRecorded = await watcher.checkNow(force: true)
        XCTAssertEqual(newlyRecorded, 0, "Retrying delivery does not rediscover or duplicate a release")
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), ["first", "second"])
        XCTAssertTrue(reopened.pendingReleaseNotifications.isEmpty)
        XCTAssertEqual(reopened.releases.map(\.id), ["first", "second"])
        XCTAssertEqual(reopened.followedArtists.first?.knownReleaseIDs, ["first", "old", "second"])
        let repeated = await watcher.checkNow()
        XCTAssertEqual(repeated, 0)
        let afterRepeat = await context.notifier.notified
        XCTAssertEqual(afterRepeat.count, 2)
    }

    func testCancelledPartialBatchRetriesOnlyTheUnacknowledgedReleaseInsideTheCatalogThrottle() async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first"), release("second")])))
        await context.notifier.pauseNextSubmission()
        let task = context.start()
        let submission = try await context.notifier.submissions.request(at: 0)
        XCTAssertEqual(submission.input.id, "first")
        task.cancel()
        try await context.notifier.submissions.complete(submission, with: .success(()))
        let recorded = await task.value
        XCTAssertEqual(recorded, 2)
        let firstBatch = await context.notifier.notified
        XCTAssertEqual(firstBatch.map(\.id), ["first"])
        XCTAssertEqual(context.library.pendingReleaseNotifications.map(\.id), ["second"])

        let retryCount = await context.watcher.checkNow()
        XCTAssertEqual(retryCount, 0)
        let catalogRequests = await context.catalog.artists.requests
        XCTAssertEqual(catalogRequests.count, 1, "Pending delivery is independent of the six-hour catalog throttle")
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), ["first", "second"])
        let requestIDs = await context.notifier.requestedIdentifiers
        XCTAssertEqual(requestIDs, ["release.first", "release.second"])
        XCTAssertTrue(context.library.pendingReleaseNotifications.isEmpty)
        XCTAssertEqual(context.library.releases.count, 2)
    }

    func testFailedSubmissionStaysPendingWhileASuccessfulSiblingIsAcknowledged() async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first"), release("second")])))
        await context.notifier.pauseNextSubmission()
        let task = context.start()
        let submission = try await context.notifier.submissions.request(at: 0)
        try await context.notifier.submissions.complete(submission, with: .failure(RecommendationTestFailure.provider("Submission failed")))
        let recorded = await task.value
        XCTAssertEqual(recorded, 2)
        let firstBatch = await context.notifier.notified
        XCTAssertEqual(firstBatch.map(\.id), ["second"])
        XCTAssertEqual(context.library.pendingReleaseNotifications.map(\.id), ["first"])

        let retryCount = await context.watcher.checkNow()
        XCTAssertEqual(retryCount, 0)
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), ["second", "first"])
        let requestIDs = await context.notifier.requestedIdentifiers
        XCTAssertEqual(requestIDs, ["release.first", "release.second", "release.first"])
        XCTAssertTrue(context.library.pendingReleaseNotifications.isEmpty)
        XCTAssertEqual(context.library.releases.count, 2)
    }

    func testFailedDeliveryAcknowledgementRecoversWithoutSubmittingTheAcceptedStableIDAgain() async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first"), release("second")])))
        await context.notifier.pauseNextSubmission()
        let task = context.start()
        let submission = try await context.notifier.submissions.request(at: 0)
        let backup = context.directory.appendingPathComponent("pending-deliveries.json")
        try FileManager.default.moveItem(at: context.fileURL, to: backup)
        try FileManager.default.createDirectory(at: context.fileURL, withIntermediateDirectories: false)
        try await context.notifier.submissions.complete(submission, with: .success(()))
        let recorded = await task.value
        XCTAssertEqual(recorded, 2)
        XCTAssertNotNil(context.library.errorMessage)
        XCTAssertEqual(context.library.pendingReleaseNotifications.map(\.id), ["first", "second"])
        let firstBatch = await context.notifier.notified
        XCTAssertEqual(firstBatch.map(\.id), ["first"])
        try FileManager.default.removeItem(at: context.fileURL)
        try FileManager.default.moveItem(at: backup, to: context.fileURL)

        XCTAssertEqual(context.library.reloadFromDisk(), .reloaded)
        let retryCount = await context.watcher.checkNow()
        XCTAssertEqual(retryCount, 0)
        let notified = await context.notifier.notified
        let requestIDs = await context.notifier.requestedIdentifiers
        XCTAssertEqual(notified.map(\.id), ["first", "second"])
        XCTAssertEqual(requestIDs, ["release.first", "release.second"], "The production notifier recognizes the accepted request ID")
        XCTAssertTrue(context.library.pendingReleaseNotifications.isEmpty)
        XCTAssertEqual(context.library.releases.count, 2)
        let clock = context.clock
        XCTAssertTrue(LibraryStore(directory: context.directory, now: { clock.now }).pendingReleaseNotifications.isEmpty)
    }

    func testExplicitDisableRetiresPendingAlertsAcrossReenableAndReopen() async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first"), release("second")])))
        await context.notifier.pauseNextAuthorization()
        let task = context.start()
        let authorization = try await context.notifier.authorizations.request(at: 0)
        context.library.preferences.newReleaseAlerts = false
        context.library.preferences.newReleaseAlerts = true
        try await context.notifier.authorizations.complete(authorization, with: .success(true))
        _ = await task.value
        XCTAssertTrue(context.library.pendingReleaseNotifications.isEmpty)
        let clock = context.clock
        let reopened = LibraryStore(directory: context.directory, now: { clock.now })
        let watcher = ReleaseWatcher(library: reopened, catalog: context.catalog, notifier: context.notifier, now: { clock.now })
        let retried = await watcher.checkNow()
        XCTAssertEqual(retried, 0)
        XCTAssertTrue(reopened.pendingReleaseNotifications.isEmpty)
        XCTAssertEqual(reopened.releases.count, 2)
        let notified = await context.notifier.notified
        XCTAssertTrue(notified.isEmpty)
    }

    func testExternalDisableDuringAuthorizationBlocksStaleDeliveryAndReloadRetiresIt() async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first"), release("second")])))
        await context.notifier.pauseNextAuthorization()
        let task = context.start()
        let authorization = try await context.notifier.authorizations.request(at: 0)
        let clock = context.clock
        let external = LibraryStore(directory: context.directory, now: { clock.now })
        external.preferences.newReleaseAlerts = false
        let disabled = try Data(contentsOf: context.fileURL)
        try await context.notifier.authorizations.complete(authorization, with: .success(true))
        _ = await task.value
        XCTAssertTrue(context.library.requiresReload)
        XCTAssertEqual(try Data(contentsOf: context.fileURL), disabled)
        let earlyNotifications = await context.notifier.notified
        XCTAssertTrue(earlyNotifications.isEmpty)

        XCTAssertEqual(context.library.reloadFromDisk(), .reloaded)
        context.library.preferences.newReleaseAlerts = true
        let retried = await context.watcher.checkNow()
        XCTAssertEqual(retried, 0)
        XCTAssertTrue(context.library.pendingReleaseNotifications.isEmpty)
        let notified = await context.notifier.notified
        XCTAssertTrue(notified.isEmpty)
    }

    func testPendingDeliveryStillRunsWhenTheNextForcedCatalogReadFails() async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first")])))
        await context.notifier.pauseNextAuthorization()
        let task = context.start()
        let authorization = try await context.notifier.authorizations.request(at: 0)
        task.cancel()
        try await context.notifier.authorizations.complete(authorization, with: .success(true))
        _ = await task.value
        await context.catalog.artists.enqueue(.failure(RecommendationTestFailure.provider("Catalog unavailable")))
        let count = await context.watcher.checkNow(force: true)
        XCTAssertEqual(count, 0)
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), ["first"])
        XCTAssertTrue(context.library.pendingReleaseNotifications.isEmpty)
        XCTAssertEqual(context.library.releases.map(\.id), ["first"])
    }

    func testDisablingAlertsDuringIdentifierLookupPreventsActualSubmission() async throws {
        try await assertIdentifierLookupRetirement(.disableAlerts)
    }

    func testUnfollowingDuringIdentifierLookupPreventsActualSubmission() async throws {
        try await assertIdentifierLookupRetirement(.unfollow)
    }

    func testDisableThenReenableDuringIdentifierLookupDoesNotReviveRetiredPendingIDs() async throws {
        try await assertIdentifierLookupRetirement(.disableAlerts, reenableAlerts: true)
    }

    func testEligibleReleaseStartsSubmissionOnMainActorAfterIdentifierLookup() async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first")])))
        context.notifier.pauseNextIdentifierLookup()
        let library = context.library
        var starts: [String] = []
        context.notifier.onSubmissionStarted { release in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(library.canDeliverReleaseNotification(release))
            starts.append(release.id)
        }
        let task = context.start()
        let lookup = try await context.notifier.identifierLookups.request(at: 0)
        XCTAssertEqual(library.pendingReleaseNotifications.map(\.id), ["first"])
        let beforeLookup = await context.notifier.requestedIdentifiers
        XCTAssertTrue(beforeLookup.isEmpty)
        library.toggleFavorite(libraryTestTrack("favorite-during-lookup"))
        try await context.notifier.identifierLookups.complete(lookup, with: .success([]))

        let count = await task.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(starts, ["first"])
        let requested = await context.notifier.requestedIdentifiers
        let notified = await context.notifier.notified
        XCTAssertEqual(requested, ["release.first"])
        XCTAssertEqual(notified.map(\.id), ["first"])
        XCTAssertTrue(library.pendingReleaseNotifications.isEmpty)
        XCTAssertEqual(library.releases.map(\.id), ["first"])
        XCTAssertEqual(library.favorites.map(\.id), ["favorite-during-lookup"])
        XCTAssertNil(library.errorMessage)
    }

    func testAlreadyAcceptedIdentityFromIdentifierLookupAcknowledgesWithoutResubmission() async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first")])))
        context.notifier.pauseNextIdentifierLookup()
        let task = context.start()
        let lookup = try await context.notifier.identifierLookups.request(at: 0)
        XCTAssertEqual(context.library.pendingReleaseNotifications.map(\.id), ["first"])
        try await context.notifier.identifierLookups.complete(lookup, with: .success(["release.first"]))
        let count = await task.value
        XCTAssertEqual(count, 1)
        let requested = await context.notifier.requestedIdentifiers
        let notified = await context.notifier.notified
        XCTAssertTrue(requested.isEmpty)
        XCTAssertTrue(notified.isEmpty)
        XCTAssertTrue(context.library.pendingReleaseNotifications.isEmpty)
        let clock = context.clock
        let reopened = LibraryStore(directory: context.directory, now: { clock.now })
        XCTAssertTrue(reopened.pendingReleaseNotifications.isEmpty)
        XCTAssertEqual(reopened.releases.map(\.id), ["first"])
        XCTAssertEqual(reopened.followedArtists.first?.knownReleaseIDs, ["first", "old"])
        let repeated = await context.watcher.checkNow()
        XCTAssertEqual(repeated, 0)
        let afterRepeat = await context.notifier.requestedIdentifiers
        XCTAssertTrue(afterRepeat.isEmpty)
    }

    func testCancellationDuringIdentifierLookupKeepsPendingDeliveryForTheNextCheck() async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first"), release("second")])))
        context.notifier.pauseNextIdentifierLookup()
        let task = context.start()
        let lookup = try await context.notifier.identifierLookups.request(at: 0)
        task.cancel()
        try await context.notifier.identifierLookups.complete(lookup, with: .success([]))
        let count = await task.value
        XCTAssertEqual(count, 2)
        let beforeRetry = await context.notifier.requestedIdentifiers
        XCTAssertTrue(beforeRetry.isEmpty)
        XCTAssertEqual(context.library.pendingReleaseNotifications.map(\.id), ["first", "second"])
        let retryCount = await context.watcher.checkNow()
        XCTAssertEqual(retryCount, 0)
        let requested = await context.notifier.requestedIdentifiers
        let notified = await context.notifier.notified
        XCTAssertEqual(requested, ["release.first", "release.second"])
        XCTAssertEqual(notified.map(\.id), ["first", "second"])
        XCTAssertTrue(context.library.pendingReleaseNotifications.isEmpty)
        XCTAssertEqual(context.library.releases.count, 2)
    }

    private enum DeliveryChange { case disableAlerts, unfollow, cancel }

    private func assertIdentifierLookupRetirement(_ change: DeliveryChange, reenableAlerts: Bool = false) async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first"), release("second")])))
        context.notifier.pauseNextIdentifierLookup()
        let task = context.start()
        let lookup = try await context.notifier.identifierLookups.request(at: 0)
        XCTAssertEqual(context.library.pendingReleaseNotifications.map(\.id), ["first", "second"])
        let beforeLookup = await context.notifier.requestedIdentifiers
        XCTAssertTrue(beforeLookup.isEmpty)
        apply(change, context: context, task: task)
        if reenableAlerts { context.library.preferences.newReleaseAlerts = true }
        let retired = try Data(contentsOf: context.fileURL)
        let saved = try LibraryPersistence.decode(retired, now: context.clock.now)
        XCTAssertTrue(saved.pendingReleaseNotificationIDs.isEmpty)
        try await context.notifier.identifierLookups.complete(lookup, with: .success([]))

        let count = await task.value
        XCTAssertEqual(count, 2)
        let requested = await context.notifier.requestedIdentifiers
        let notified = await context.notifier.notified
        XCTAssertTrue(requested.isEmpty, "A retired pending ID must never reach the platform submission boundary")
        XCTAssertTrue(notified.isEmpty)
        XCTAssertTrue(context.library.pendingReleaseNotifications.isEmpty)
        XCTAssertEqual(try Data(contentsOf: context.fileURL), retired)
        XCTAssertNil(context.library.errorMessage)
    }

    private func apply(_ change: DeliveryChange, context: ReleaseWatcherRegressionContext, task: Task<Int, Never>) {
        switch change {
        case .disableAlerts:
            context.library.preferences.newReleaseAlerts = false
            XCTAssertFalse(context.library.preferences.newReleaseAlerts)
        case .unfollow:
            context.library.unfollow(artistID: "artist")
            XCTAssertFalse(context.library.isFollowing(artistID: "artist"))
        case .cancel:
            task.cancel()
        }
    }

    private func assertAuthorizationChange(_ change: DeliveryChange) async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first"), release("second")])))
        await context.notifier.pauseNextAuthorization()
        let task = context.start()
        let request = try await context.notifier.authorizations.request(at: 0)
        XCTAssertEqual(context.library.releases.map(\.id), ["first", "second"])
        apply(change, context: context, task: task)
        try await context.notifier.authorizations.complete(request, with: .success(true))
        let count = await task.value
        XCTAssertEqual(count, 2)
        let notified = await context.notifier.notified
        XCTAssertTrue(notified.isEmpty)
        XCTAssertNil(context.library.errorMessage)
    }

    private func assertSubmissionChange(_ change: DeliveryChange) async throws {
        let context = try makeContext()
        context.follow()
        await context.catalog.artists.enqueue(.success(page(releases: [release("first"), release("second")])))
        await context.notifier.pauseNextSubmission()
        let task = context.start()
        let request = try await context.notifier.submissions.request(at: 0)
        XCTAssertEqual(request.input.id, "first")
        XCTAssertEqual(context.library.releases.map(\.id), ["first", "second"])
        apply(change, context: context, task: task)
        try await context.notifier.submissions.complete(request, with: .success(()))
        let count = await task.value
        XCTAssertEqual(count, 2)
        let notified = await context.notifier.notified
        XCTAssertEqual(notified.map(\.id), ["first"])
        XCTAssertNil(context.library.errorMessage)
    }

    private func makeContext() throws -> ReleaseWatcherRegressionContext {
        let context = try ReleaseWatcherRegressionContext()
        addTeardownBlock { await context.close() }
        return context
    }

    private func page(id: String = "artist", releases: [MusicCollection]) -> ArtistPage {
        Fixtures.page(id, name: "Artist \(id)", releases: releases)
    }

    private func release(_ id: String) -> MusicCollection {
        Fixtures.release(id, title: "Release \(id)", subtitle: "Single • 2026")
    }
}

@MainActor
private final class ReleaseWatcherRegressionContext {
    let directory: URL
    let clock: RecommendationTestClock
    let library: LibraryStore
    let catalog = AppModelCatalogProvider()
    let notifier = ReleaseDeliveryNotifier()
    let watcher: ReleaseWatcher
    private var tasks: [Task<Int, Never>] = []
    var fileURL: URL { directory.appendingPathComponent(LibraryPersistence.fileName) }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajana-ReleaseRegressionTests-\(UUID())", isDirectory: true)
        let clock = RecommendationTestClock()
        self.clock = clock
        library = LibraryStore(directory: directory, now: { clock.now })
        watcher = ReleaseWatcher(library: library, catalog: catalog, notifier: notifier, now: { clock.now })
        if let error = library.errorMessage { throw RecommendationTestFailure.storage(error) }
    }

    func follow(id: String = "artist", known: [String] = ["old"]) {
        library.follow(FollowedArtist(id: id, name: "Artist \(id)", followedAt: clock.now, knownReleaseIDs: known))
        XCTAssertNil(library.errorMessage)
        XCTAssertTrue(library.isFollowing(artistID: id))
    }

    func start() -> Task<Int, Never> {
        let watcher = self.watcher
        let task = Task { await watcher.checkNow() }
        tasks.append(task)
        return task
    }

    func close() async {
        tasks.forEach { $0.cancel() }
        await catalog.close()
        await notifier.close()
        for task in tasks { _ = await task.value }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class ReleaseDeliveryNotifier: ReleaseNotifying {
    let authorizations = AppModelRequestGate<Void, Bool>()
    let submissions: AppModelRequestGate<ArtistRelease, Void>
    let identifierLookups: AppModelRequestGate<Void, Set<String>>
    private let submitter: ReleaseSubmissionProbe
    private var shouldPauseAuthorization = false
    private var authorizationRequestCount = 0
    var authorizationRequests: Int { get async { authorizationRequestCount } }
    var notified: [ArtistRelease] { get async { submitter.notified } }
    var requestedIdentifiers: [String] { get async { submitter.requestedIdentifiers } }

    init() {
        let submissions = AppModelRequestGate<ArtistRelease, Void>()
        self.submissions = submissions
        let identifierLookups = AppModelRequestGate<Void, Set<String>>()
        self.identifierLookups = identifierLookups
        submitter = ReleaseSubmissionProbe(submissions: submissions, identifierLookups: identifierLookups)
    }

    func pauseNextAuthorization() async { shouldPauseAuthorization = true }
    func pauseNextSubmission() async { submitter.pauseNextSubmission() }
    func pauseNextIdentifierLookup() { submitter.pauseNextIdentifierLookup() }
    func onSubmissionStarted(_ check: @escaping @MainActor (ArtistRelease) -> Void) { submitter.onSubmissionStarted = check }

    func requestAuthorizationIfNeeded() async -> Bool {
        authorizationRequestCount += 1
        guard shouldPauseAuthorization else { return true }
        shouldPauseAuthorization = false
        return (try? await authorizations.receive(())) ?? false
    }

    func existingIdentifiers() async -> Set<String> {
        await LocalReleaseNotifier(submitter: submitter).existingIdentifiers()
    }

    func submit(_ release: ArtistRelease, completion: @escaping @Sendable (Bool) -> Void) {
        LocalReleaseNotifier(submitter: submitter).submit(release, completion: completion)
    }

    func close() async {
        await authorizations.close()
        await submitter.close()
    }
}

@MainActor
private final class ReleaseSubmissionProbe: ReleaseNotificationSubmitting {
    private let submissions: AppModelRequestGate<ArtistRelease, Void>
    private let identifierLookups: AppModelRequestGate<Void, Set<String>>
    private var shouldPauseSubmission = false
    private var shouldPauseIdentifierLookup = false
    private var identifiers: Set<String> = []
    private var completions: [Task<Void, Never>] = []
    private(set) var notified: [ArtistRelease] = []
    private(set) var requestedIdentifiers: [String] = []
    var onSubmissionStarted: (@MainActor (ArtistRelease) -> Void)?

    init(submissions: AppModelRequestGate<ArtistRelease, Void>, identifierLookups: AppModelRequestGate<Void, Set<String>>) {
        self.submissions = submissions
        self.identifierLookups = identifierLookups
    }

    func pauseNextSubmission() { shouldPauseSubmission = true }
    func pauseNextIdentifierLookup() { shouldPauseIdentifierLookup = true }

    func existingIdentifiers() async -> Set<String> {
        guard shouldPauseIdentifierLookup else { return identifiers }
        shouldPauseIdentifierLookup = false
        return (try? await identifierLookups.receive(())) ?? []
    }

    func submit(_ release: ArtistRelease, completion: @escaping @Sendable (Bool) -> Void) {
        XCTAssertTrue(Thread.isMainThread)
        onSubmissionStarted?(release)
        requestedIdentifiers.append(release.notificationIdentifier)
        if shouldPauseSubmission {
            shouldPauseSubmission = false
            completions.append(Task { @MainActor in
                do {
                    try await submissions.receive(release)
                    identifiers.insert(release.notificationIdentifier)
                    notified.append(release)
                    completion(true)
                } catch { completion(false) }
            })
        } else {
            identifiers.insert(release.notificationIdentifier)
            notified.append(release)
            completion(true)
        }
    }

    func close() async {
        onSubmissionStarted = nil
        await identifierLookups.close()
        await submissions.close()
        for completion in completions { await completion.value }
    }
}
