import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class MomentMixMemoryPersistence: MomentMixPersistence {
    var data: Data?
    var failWrite = false
    var failRead = false
    var writes = 0
    func read() throws -> Data? {
        if failRead { throw MomentMixStorageFailure() }
        return data
    }
    func write(_ data: Data) throws {
        if failWrite { throw MomentMixStorageFailure() }
        self.data = data
        writes += 1
    }
}

@MainActor
final class MomentMixStoreTests: XCTestCase {
    private typealias F = MomentMixFixtures

    private func store(_ disk: MomentMixMemoryPersistence? = nil) -> MomentMixStore {
        let store = MomentMixStore(persistence: disk, now: F.start)
        XCTAssertTrue(store.synchronizePrivacy(historyEnabled: true, historyEpoch: nil, now: F.start))
        return store
    }

    func testOnlyQualifiedCumulativeEventsAreSavedOnceAcrossRevisionsAndRelaunch() throws {
        let disk = MomentMixMemoryPersistence()
        let persisted = self.store(disk)
        var event = F.recurring[0]
        event.listenedSeconds = 5
        let capture = persisted.capture(route: .car, now: event.startedAt)
        XCTAssertTrue(persisted.observe(events: [event], localEventIDs: [event.id], capture: capture,
                                       now: event.startedAt.addingTimeInterval(5), calendar: F.calendar))
        XCTAssertTrue(persisted.snapshot.evidence.isEmpty)
        event.listenedSeconds = 30
        XCTAssertTrue(persisted.observe(events: [event], now: event.startedAt.addingTimeInterval(30), calendar: F.calendar))
        let writes = disk.writes
        event.listenedSeconds = 120
        XCTAssertTrue(persisted.observe(events: [event, event], now: F.now, calendar: F.calendar))
        XCTAssertEqual(persisted.snapshot.evidence.count, 1)
        XCTAssertEqual(disk.writes, writes)
        let reopened = MomentMixStore(persistence: disk, now: F.now)
        XCTAssertTrue(reopened.synchronizePrivacy(historyEnabled: true, historyEpoch: nil, now: F.now))
        XCTAssertTrue(reopened.observe(events: [event], now: F.now, calendar: F.calendar))
        XCTAssertEqual(reopened.snapshot.evidence, persisted.snapshot.evidence)
        XCTAssertEqual(reopened.snapshot.evidence.first?.context.route, .car)
    }

    func testFreshLocalCaptureIsRetainedUntilQualificationAndOldOrRemoteEventsStayGeneral() throws {
        let store = self.store()
        var event = F.recurring[0]
        let start = event.startedAt
        event.listenedSeconds = 5
        let capture = store.capture(route: .car, now: start.addingTimeInterval(5))
        _ = store.observe(events: [event], localEventIDs: [event.id], capture: capture, now: start.addingTimeInterval(5), calendar: F.calendar)
        event.listenedSeconds = 30
        _ = store.observe(events: [event], now: start.addingTimeInterval(30), calendar: F.calendar)
        XCTAssertEqual(store.snapshot.evidence.first?.context.route, .car)
        let events = [event] + Array(F.recurring.suffix(2))
        let late = store.capture(route: .headphones, now: F.now)
        _ = store.observe(events: events, localEventIDs: Set(events.map(\.id)), capture: late, now: F.now, calendar: F.calendar)
        XCTAssertEqual(store.snapshot.evidence.filter { $0.context.route == .general }.count, 2)
    }

    func testShortSongQualificationUsesExistingHalfDurationRule() {
        let store = self.store()
        var event = F.recurring[0]
        event.track.duration = 20
        event.listenedSeconds = 9
        _ = store.observe(events: [event], now: F.now, calendar: F.calendar)
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
        event.listenedSeconds = 10
        _ = store.observe(events: [event], now: F.now, calendar: F.calendar)
        XCTAssertEqual(store.snapshot.evidence.count, 1)
    }

    func testStagedContextGivesNoCreditUntilDurableEventAndIsBounded() {
        let disk = MomentMixMemoryPersistence(), store = self.store(disk)
        let events = (0..<129).map { F.event("pending\($0)", at: F.now) }
        let capture = store.capture(route: .car, now: F.now)!
        let writes = disk.writes
        store.stageContext(for: events, capture: capture)
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
        XCTAssertEqual(disk.writes, writes)
        _ = store.observe(events: events, now: F.now.addingTimeInterval(30), calendar: F.calendar)
        XCTAssertEqual(store.snapshot.evidence.filter { $0.context.route == .car }.count, 128)
        XCTAssertEqual(store.snapshot.evidence.filter { $0.context.route == .general }.count, 1)
    }

    func testMotionPreferenceIsRequiredForActiveEvidenceAndDisableForgetsIt() {
        let store = self.store()
        XCTAssertEqual(store.capture(route: .active, now: F.now)?.route, .general)
        XCTAssertTrue(store.setMotionEnabled(true))
        let event = F.event("active", at: F.now)
        let capture = store.capture(route: .active, now: F.now)
        _ = store.observe(events: [event], localEventIDs: [event.id], capture: capture, now: F.now, calendar: F.calendar)
        XCTAssertEqual(store.snapshot.evidence.first?.context.route, .active)
        XCTAssertTrue(store.setMotionEnabled(false))
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
    }

    func testInvalidFutureAndUnqualifiedEventsAreExcluded() {
        let store = self.store()
        let events = [F.event("nan", at: F.now, seconds: .nan), F.event("negative", at: F.now, seconds: -1),
                      F.event("future", at: F.now.addingTimeInterval(1)), F.event("short", at: F.now, seconds: 29)]
        _ = store.observe(events: events, now: F.now, calendar: F.calendar)
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
    }

    func testNoCollectionWhileHistoryIsOffAndNoBackfillOnEnable() {
        let store = self.store()
        _ = store.synchronizePrivacy(historyEnabled: false, historyEpoch: nil, now: F.start)
        XCTAssertNil(store.capture(route: .car, now: F.now))
        XCTAssertFalse(store.observe(events: F.recurring, now: F.now, calendar: F.calendar))
        _ = store.synchronizePrivacy(historyEnabled: true, historyEpoch: nil, now: F.now)
        _ = store.observe(events: F.recurring, now: F.now, calendar: F.calendar)
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
    }

    func testHistoryOffSurvivesRelaunchWithoutBackfill() {
        let disk = MomentMixMemoryPersistence()
        let persisted = self.store(disk)
        _ = persisted.synchronizePrivacy(historyEnabled: false, historyEpoch: nil, now: F.start)
        let reopened = MomentMixStore(persistence: disk, now: F.now)
        _ = reopened.synchronizePrivacy(historyEnabled: true, historyEpoch: nil, now: F.now)
        _ = reopened.observe(events: F.recurring, now: F.now, calendar: F.calendar)
        XCTAssertTrue(reopened.snapshot.evidence.isEmpty)
    }

    func testOptOutClearsLearningAndPreservesPerMixChoice() {
        let store = self.store()
        let context = MomentContext.at(F.recurring[0].startedAt, calendar: F.calendar)
        _ = store.observe(events: F.recurring, now: F.now, calendar: F.calendar)
        XCTAssertTrue(store.setMixEnabled(false, context: context))
        XCTAssertTrue(store.setLearningEnabled(false, now: F.now))
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
        XCTAssertFalse(store.canLearn)
        XCTAssertTrue(store.snapshot.preferences.disabledMixIDs.contains(context.id))
        _ = store.setLearningEnabled(true, now: F.now)
        _ = store.observe(events: F.recurring, now: F.now, calendar: F.calendar)
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
    }

    func testFailedWriteDoesNotPublishAndRetryCountsOnce() {
        let disk = MomentMixMemoryPersistence(), store = self.store(disk)
        let revision = store.revision
        disk.failWrite = true
        XCTAssertFalse(store.observe(events: F.recurring, now: F.now, calendar: F.calendar))
        XCTAssertEqual(store.revision, revision)
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        disk.failWrite = false
        XCTAssertTrue(store.observe(events: F.recurring, now: F.now, calendar: F.calendar))
        XCTAssertEqual(store.snapshot.evidence.count, 3)
        XCTAssertNil(store.errorMessage)
    }

    func testFailedPreferenceWriteKeepsPreviousChoice() {
        let disk = MomentMixMemoryPersistence(), store = self.store(disk)
        disk.failWrite = true
        XCTAssertFalse(store.setLearningEnabled(false, now: F.now))
        XCTAssertTrue(store.snapshot.preferences.learningEnabled)
        XCTAssertTrue(store.canLearn)
    }

    func testFailedResetHidesEvidenceRetiresCapturesAndBlocksUntilDurableRetry() {
        let disk = MomentMixMemoryPersistence(), store = self.store(disk)
        _ = store.observe(events: F.recurring, now: F.now, calendar: F.calendar)
        let capture = store.capture(route: .car, now: F.now)
        let epoch = UUID()
        disk.failWrite = true
        XCTAssertFalse(store.reset(historyEpoch: epoch, now: F.now))
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
        XCTAssertTrue(store.resetPending)
        XCTAssertFalse(store.canLearn)
        XCTAssertFalse(store.observe(events: F.recurring, capture: capture, now: F.now, calendar: F.calendar))
        disk.failWrite = false
        XCTAssertTrue(store.retryReset())
        let newEvent = F.event("new", at: F.now)
        _ = store.observe(events: [newEvent], localEventIDs: [newEvent.id], capture: capture, now: F.now, calendar: F.calendar)
        XCTAssertEqual(store.snapshot.evidence.first?.context.route, .general)
        XCTAssertEqual(store.snapshot.evidence.count, 1)
    }

    func testEpochMismatchAfterFailedResetAndRelaunchCannotResurrectOldEvidence() {
        let disk = MomentMixMemoryPersistence(), store = self.store(disk)
        _ = store.observe(events: F.recurring, now: F.now, calendar: F.calendar)
        let epoch = UUID()
        disk.failWrite = true
        _ = store.reset(historyEpoch: epoch, now: F.now)
        let reopened = MomentMixStore(persistence: disk, now: F.now)
        XCTAssertFalse(reopened.synchronizePrivacy(historyEnabled: true, historyEpoch: epoch, now: F.now))
        XCTAssertTrue(reopened.snapshot.evidence.isEmpty)
        XCTAssertFalse(reopened.canLearn)
        disk.failWrite = false
        XCTAssertTrue(reopened.retryReset())
    }

    func testCorruptFutureAndExternallyChangedFilesArePreserved() throws {
        for data in [Data("broken".utf8), try JSONEncoder().encode(MomentMixSnapshot(version: 2, learningSince: F.start))] {
            let disk = MomentMixMemoryPersistence()
            disk.data = data
            let store = MomentMixStore(persistence: disk, now: F.start)
            XCTAssertFalse(store.setLearningEnabled(false, now: F.now))
            XCTAssertFalse(store.reset(historyEpoch: UUID(), now: F.now))
            XCTAssertEqual(disk.data, data)
            XCTAssertEqual(disk.writes, 0)
            XCTAssertNotNil(store.errorMessage)
        }
        let disk = MomentMixMemoryPersistence(), store = self.store(disk)
        let external = Data("external".utf8)
        disk.data = external
        XCTAssertFalse(store.observe(events: F.recurring, now: F.now, calendar: F.calendar))
        XCTAssertEqual(disk.data, external)
    }

    func testUnreadableFileAndExplicitRecoveryKeepPendingReset() {
        let disk = MomentMixMemoryPersistence(), store = self.store(disk)
        _ = store.observe(events: F.recurring, now: F.now, calendar: F.calendar)
        disk.failRead = true
        let unreadable = MomentMixStore(persistence: disk, now: F.now)
        XCTAssertFalse(unreadable.synchronizePrivacy(historyEnabled: true, historyEpoch: nil, now: F.now))
        XCTAssertFalse(unreadable.canLearn)
        XCTAssertFalse(unreadable.reset(historyEpoch: nil, now: F.now))
        disk.failRead = false
        XCTAssertTrue(unreadable.reload())
        XCTAssertFalse(unreadable.resetPending)
        XCTAssertTrue(unreadable.snapshot.evidence.isEmpty)
    }

    func testRetentionAndCountBoundsAreIdempotent() {
        let store = self.store()
        let events = (0..<2_100).map { F.event("song\($0)", at: F.now.addingTimeInterval(-Double($0))) }
        _ = store.observe(events: events, now: F.now, calendar: F.calendar)
        XCTAssertEqual(store.snapshot.evidence.count, 2_048)
        let revision = store.revision
        _ = store.observe(events: Array(events.reversed()), now: F.now, calendar: F.calendar)
        XCTAssertEqual(store.revision, revision)
        _ = store.observe(events: events, now: F.now.addingTimeInterval(61 * 86_400), calendar: F.calendar)
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
    }

    func testRemovedDurableEventsRetireTheirContext() {
        let store = self.store()
        _ = store.observe(events: F.recurring, now: F.now, calendar: F.calendar)
        _ = store.observe(events: [], now: F.now, calendar: F.calendar)
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
    }

    func testExactSixtyDayBoundaryIsIncludedThenExpires() {
        let start = F.now.addingTimeInterval(-61 * 86_400)
        let store = MomentMixStore(now: start)
        _ = store.synchronizePrivacy(historyEnabled: true, historyEpoch: nil, now: start)
        let event = F.event("boundary", at: F.now.addingTimeInterval(-60 * 86_400))
        _ = store.observe(events: [event], now: F.now, calendar: F.calendar)
        XCTAssertEqual(store.snapshot.evidence.count, 1)
        _ = store.observe(events: [event], now: F.now.addingTimeInterval(1), calendar: F.calendar)
        XCTAssertTrue(store.snapshot.evidence.isEmpty)
    }
}
