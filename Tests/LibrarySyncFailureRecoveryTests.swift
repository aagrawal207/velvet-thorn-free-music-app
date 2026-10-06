import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySyncFailureRecoveryTests: XCTestCase {
    func testListeningCheckpointDuringPreparationDoesNotBecomeALibraryErrorOrPopup() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .zero, retryDelays: [.seconds(1000)])
        defer { a.sync.setEnabled(false) }
        let b = harness.device(LibrarySyncTestData.b)
        b.library.toggleFavorite(libraryTestTrack("remote"))
        harness.cloud.accounts["account-a"] = [b.id: try LibrarySyncCodec.encodeReplica(b.library.cloudReplica(replicaID: b.id))]
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        a.transport.beforeAccountReturns = { check in
            if check == 3 { await gate.wait() }
        }
        var notices: [String] = []
        a.sync.onFailureNotification = { if let message = $0 { notices.append(message) } }
        a.sync.start()
        try await PlaybackTestSupport.waitUntil { gate.entered }
        XCTAssertTrue(a.library.recordListening(track: libraryTestTrack("playing"), sessionID: UUID(),
                                                startedAt: harness.clock.now, seconds: 5))
        let checkpointBytes = try Data(contentsOf: a.fileURL)
        gate.open()
        try await PlaybackTestSupport.waitUntil { !a.sync.isSyncing }
        XCTAssertNil(a.library.errorMessage, "A normal revision race must not enter RootView's library-error banner path")
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertTrue(notices.isEmpty)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertEqual(try Data(contentsOf: a.fileURL), checkpointBytes)
        XCTAssertEqual(a.library.events.first?.listenedSeconds, 5)
        a.transport.beforeAccountReturns = nil
        await a.sync.syncNow()
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertEqual(a.library.favorites.map(\.id), ["remote"])
        XCTAssertEqual(a.library.events.first?.listenedSeconds, 5)
        XCTAssertEqual(a.transport.writes.count, 1)
    }

    func testTransientRetriesAreBoundedAndCheckpointsRespectCooldown() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .zero, retryDelays: [.milliseconds(20), .milliseconds(30)])
        defer { a.sync.setEnabled(false) }
        a.transport.readError = URLError(.timedOut)
        var notices: [String?] = []
        a.sync.onFailureNotification = { notices.append($0) }
        a.sync.start()
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 3 && !a.sync.isSyncing }
        XCTAssertNotNil(a.sync.errorMessage)
        XCTAssertEqual(notices.compactMap { $0 }.count, 1)
        for index in 0..<10 {
            XCTAssertTrue(a.library.recordListening(track: libraryTestTrack("playing-\(index)"), sessionID: UUID(),
                                                    startedAt: harness.clock.now, seconds: 5))
            a.transport.emit(.filesChanged)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(a.transport.reads, 3)
        XCTAssertEqual(notices.compactMap { $0 }.count, 1)
        harness.clock.advance(by: 301)
        XCTAssertTrue(a.library.recordListening(track: libraryTestTrack("cooldown-probe"), sessionID: UUID(),
                                                startedAt: harness.clock.now, seconds: 5))
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 6 && !a.sync.isSyncing }
        XCTAssertEqual(notices.compactMap { $0 }.count, 1, "A sustained failure stays deduplicated across cooldown probes")
        await a.sync.syncNow()
        XCTAssertEqual(notices.compactMap { $0 }.count, 2, "An explicit Retry reports the actionable failure again")
        a.transport.readError = nil
        await a.sync.syncNow()
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertNotNil(a.sync.lastSyncDate)
        XCTAssertEqual(notices.filter { $0 == nil }.count, 1)
        a.transport.readError = URLError(.timedOut)
        a.sync.refresh()
        try await PlaybackTestSupport.waitUntil { notices.compactMap { $0 }.count == 3 && !a.sync.isSyncing }
    }

    func testTransientRetryRecoversAutomaticallyWithoutANotification() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .zero, retryDelays: [.milliseconds(100), .milliseconds(100)])
        defer { a.sync.setEnabled(false) }
        a.transport.readError = LibrarySyncError.changedDuringSync
        var notices: [String] = []
        a.sync.onFailureNotification = { if let message = $0 { notices.append(message) } }
        a.sync.start()
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 1 && !a.sync.isSyncing }
        XCTAssertNil(a.sync.errorMessage)
        a.transport.readError = nil
        try await PlaybackTestSupport.waitUntil { a.sync.lastSyncDate != nil && !a.sync.isSyncing }
        XCTAssertEqual(a.transport.reads, 2)
        XCTAssertTrue(notices.isEmpty)
        XCTAssertEqual(a.transport.writes.count, 1)
    }

    func testDownloadCompletionDuringARetryIsNotHeldBehindFailureCooldown() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .zero, retryDelays: [.milliseconds(100), .milliseconds(100)])
        defer { a.sync.setEnabled(false) }
        a.transport.readError = LibrarySyncError.unavailable
        var notices: [String] = []
        a.sync.onFailureNotification = { if let message = $0 { notices.append(message) } }
        a.sync.start()
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 1 && !a.sync.isSyncing }
        a.transport.readError = nil
        a.transport.pendingDownloads = 1
        a.transport.beforeReadReturns = {
            a.transport.beforeReadReturns = nil
            a.transport.pendingDownloads = 0
            a.transport.emit(.filesChanged)
        }
        try await PlaybackTestSupport.waitUntil { a.sync.lastSyncDate != nil && !a.sync.isSyncing }
        XCTAssertEqual(a.transport.reads, 3)
        XCTAssertEqual(a.transport.writes.count, 1)
        XCTAssertTrue(notices.isEmpty)
    }

    func testActionRequiredFailuresStayVisibleAndDistinctWithoutTimedRetries() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .zero, retryDelays: [.milliseconds(10), .milliseconds(10)])
        defer { a.sync.setEnabled(false) }
        var notices: [String] = []
        a.sync.onFailureNotification = { if let message = $0 { notices.append(message) } }
        a.transport.readError = LibrarySyncError.newerVersion
        a.sync.start()
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 1 && !a.sync.isSyncing }
        XCTAssertEqual(notices.count, 1)
        XCTAssertNotNil(a.sync.errorMessage)
        a.transport.emit(.filesChanged)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(a.transport.reads, 1)
        a.sync.refresh()
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 2 && !a.sync.isSyncing }
        XCTAssertEqual(notices.count, 1)
        a.transport.readError = CocoaError(.ubiquitousFileNotUploadedDueToQuota)
        a.sync.refresh()
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 3 && !a.sync.isSyncing }
        XCTAssertEqual(notices.count, 2)
        XCTAssertEqual(a.sync.statusText, "iCloud storage is full")
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        await a.sync.syncNow()
        XCTAssertEqual(notices.count, 3)
    }

    func testDisableCancelsPendingRetryAndIdentityChangeStillPausesTheAccount() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .zero, retryDelays: [.milliseconds(100)])
        a.transport.readError = LibrarySyncError.unavailable
        a.sync.start()
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 1 && !a.sync.isSyncing }
        a.sync.setEnabled(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(a.transport.reads, 1)
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        a.transport.account = "account-b"
        a.transport.emit(.identityChanged)
        try await PlaybackTestSupport.waitUntil { !a.sync.isEnabled }
        XCTAssertTrue(a.sync.statusText.contains("Account changed"))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(a.transport.reads, 2)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertNil(harness.cloud.accounts["account-b"])
    }

    func testTimeoutRecoveryRejectsTheLateReadWithoutReportingASuccessForIt() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .zero, timeout: .milliseconds(100), retryDelays: [.seconds(1000)])
        defer { a.sync.setEnabled(false) }
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        a.transport.beforeReadReturns = { await gate.wait() }
        var notices: [String] = []
        a.sync.onFailureNotification = { if let message = $0 { notices.append(message) } }
        a.sync.start()
        try await PlaybackTestSupport.waitUntil { gate.entered && !a.sync.isSyncing }
        XCTAssertTrue(a.sync.statusText.contains("timed out"))
        XCTAssertNil(a.sync.errorMessage)
        a.transport.beforeReadReturns = nil
        await a.sync.syncNow()
        XCTAssertNotNil(a.sync.lastSyncDate)
        let published = harness.cloud.accounts["account-a"]?[a.id]
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(a.transport.publicationAttempts, 1)
        XCTAssertEqual(harness.cloud.accounts["account-a"]?[a.id], published)
        XCTAssertTrue(notices.isEmpty)
    }

    func testCancellationDoesNotNotifyOrStartARetry() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .zero, retryDelays: [.milliseconds(10)])
        defer { a.sync.setEnabled(false) }
        a.transport.readError = CancellationError()
        var notices: [String] = []
        a.sync.onFailureNotification = { if let message = $0 { notices.append(message) } }
        a.sync.start()
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 1 && !a.sync.isSyncing }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(a.transport.reads, 1)
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertTrue(notices.isEmpty)
        XCTAssertTrue(a.sync.statusText.contains("cancelled"))
    }

    func testManualRequestJoiningAnAutomaticAttemptReportsItsFailure() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .zero, retryDelays: [.seconds(1000)])
        defer { a.sync.setEnabled(false) }
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        a.transport.beforePublication = { await gate.wait() }
        a.transport.publishError = URLError(.notConnectedToInternet)
        var notices: [String] = []
        a.sync.onFailureNotification = { if let message = $0 { notices.append(message) } }
        a.sync.start()
        try await PlaybackTestSupport.waitUntil { gate.entered }
        var requested = false
        let manual = Task { requested = true; await a.sync.syncNow() }
        try await PlaybackTestSupport.waitUntil { requested }
        gate.open()
        await manual.value
        XCTAssertEqual(a.transport.reads, 1)
        XCTAssertNotNil(a.sync.errorMessage)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(a.transport.writes.isEmpty)
    }

    func testFailureClassificationRetriesOnlyRecognizedTransientErrors() {
        let cases: [(any Error, LibrarySyncFailure)] = [
            (LibrarySyncError.localChangedDuringSync, .localChanged), (LibrarySyncError.changedDuringSync, .remoteChanged),
            (LibrarySyncError.unavailable, .unavailable), (URLError(.timedOut), .timeout),
            (URLError(.networkConnectionLost), .network), (URLError(.notConnectedToInternet), .network),
            (LibrarySyncError.newerVersion, .newerVersion), (LibrarySyncError.unsupportedVersion, .unsupportedVersion),
            (LibrarySyncError.invalidData("test"), .invalidData), (LibrarySyncError.tooLarge, .tooLarge),
            (LibrarySyncError.localStorage("test"), .localStorage), (LibraryStorageError.changedOnDisk, .localStorage),
            (LibraryStorageError.invalidData("remote validation"), .invalidData), (LibraryStorageError.tooLarge, .tooLarge),
            (CocoaError(.fileWriteNoPermission), .permission), (CocoaError(.ubiquitousFileNotUploadedDueToQuota), .quota),
            (CancellationError(), .cancelled), (LibrarySyncError.cancelled, .cancelled), (URLError(.cancelled), .cancelled),
            (URLError(.serverCertificateUntrusted), .unknown)
        ]
        let transient: Set<LibrarySyncFailure> = [.localChanged, .remoteChanged, .unavailable, .timeout, .network]
        for (error, reason) in cases {
            XCTAssertEqual(LibrarySyncFailure.reason(for: error), reason)
            XCTAssertEqual(reason.isTransient, transient.contains(reason))
        }
    }
}
