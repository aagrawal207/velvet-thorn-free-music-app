import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class MomentMixHistoryPreparationTests: XCTestCase {
    private typealias F = MomentMixFixtures

    func testSameRevisionReusesPreparationButSameCountQualificationChangeRebuilds() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory, now: { F.now })
        let events = F.recurring
        for (index, event) in events.enumerated() {
            XCTAssertTrue(library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt,
                                                  seconds: index == 2 ? 29 : 30))
        }
        let controller = MomentMixController(store: MomentMixStore(now: F.start), now: { F.now }, calendar: { F.calendar })
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        XCTAssertTrue(controller.collections.isEmpty)
        XCTAssertEqual(controller.historyPreparationCount, 1)
        let revision = library.historyRevision
        for _ in 0..<10 { controller.synchronize(library: library, historyEpoch: nil) }
        await controller.waitForPendingPreparation()
        XCTAssertEqual(controller.historyPreparationCount, 1)
        let event = events[2]
        XCTAssertTrue(library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 1))
        XCTAssertNotEqual(library.historyRevision, revision)
        XCTAssertEqual(library.events.count, 3)
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        XCTAssertEqual(controller.historyPreparationCount, 2)
        XCTAssertEqual(controller.collections.count, 1)
    }

    func testClearWhilePreparationIsSuspendedCannotRestoreOldEvidence() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory, now: { F.now })
        for event in F.recurring {
            _ = library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 30)
        }
        let gate = MomentPreparationGate()
        let controller = MomentMixController(store: MomentMixStore(now: F.start), now: { F.now }, calendar: { F.calendar },
            prepareHistory: { events, floor, now, calendar in
                await gate.pauseFirst()
                return MomentHistorySelection.prepare(events: events, learningSince: floor, now: now, calendar: calendar)
            })
        controller.synchronize(library: library, historyEpoch: library.listeningHistoryEpoch)
        await gate.waitForEntry()
        library.onHistoryCleared = { controller.reset(historyEpoch: library.listeningHistoryEpoch) }
        library.clearHistory()
        XCTAssertTrue(controller.store.snapshot.evidence.isEmpty)
        await gate.release()
        await controller.waitForPendingPreparation()
        XCTAssertTrue(controller.store.snapshot.evidence.isEmpty)
        XCTAssertTrue(controller.store.snapshot.selectedTrackIDs.isEmpty)
        XCTAssertTrue(controller.collections.isEmpty)
    }

    func testNewRevisionDuringPreparationIsCoalescedAndOldResultRejected() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory, now: { F.now })
        let events = F.recurring
        for (index, event) in events.enumerated() {
            _ = library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: index == 2 ? 29 : 30)
        }
        let gate = MomentPreparationGate()
        let controller = MomentMixController(store: MomentMixStore(now: F.start), now: { F.now }, calendar: { F.calendar },
            prepareHistory: { events, floor, now, calendar in
                await gate.pauseFirst()
                return MomentHistorySelection.prepare(events: events, learningSince: floor, now: now, calendar: calendar)
            })
        controller.synchronize(library: library, historyEpoch: nil)
        await gate.waitForEntry()
        _ = library.recordListening(track: events[2].track, sessionID: events[2].id, startedAt: events[2].startedAt, seconds: 1)
        for _ in 0..<10 { controller.synchronize(library: library, historyEpoch: nil) }
        XCTAssertEqual(controller.historyPreparationCount, 1, "Only one immutable history preparation may run at a time")
        await gate.release()
        await controller.waitForPendingPreparation()
        XCTAssertEqual(controller.historyPreparationCount, 2)
        XCTAssertEqual(controller.store.snapshot.evidence.count, 3)
        XCTAssertEqual(controller.collections.count, 1)
    }

    func testFutureClockCalendarAndLearningFloorFenceReuse() {
        let future = F.event("future", at: F.now.addingTimeInterval(1))
        let selection = MomentHistorySelection.prepare(events: F.recurring + [future], learningSince: F.start, now: F.now, calendar: F.calendar)
        XCTAssertTrue(selection.canReuse(learningSince: F.start, now: F.now, calendar: F.calendar))
        XCTAssertFalse(selection.canReuse(learningSince: F.start, now: F.now.addingTimeInterval(1), calendar: F.calendar))
        XCTAssertFalse(selection.canReuse(learningSince: F.start, now: F.now.addingTimeInterval(-1), calendar: F.calendar))
        XCTAssertFalse(selection.canReuse(learningSince: F.now, now: F.now, calendar: F.calendar))
        var calendar = F.calendar
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertFalse(selection.canReuse(learningSince: F.start, now: F.now, calendar: calendar))
    }

    func testFutureEventBecomesEligibleWithoutAnotherLibraryRevision() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory, now: { F.now.addingTimeInterval(2) })
        let future = F.event("future", at: F.now.addingTimeInterval(1))
        for event in Array(F.recurring.prefix(2)) + [future] {
            _ = library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 30)
        }
        var clock = F.now
        let controller = MomentMixController(store: MomentMixStore(now: F.start), now: { clock }, calendar: { F.calendar })
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        XCTAssertTrue(controller.collections.isEmpty)
        let revision = library.historyRevision
        clock = F.now.addingTimeInterval(1)
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        XCTAssertEqual(library.historyRevision, revision)
        XCTAssertEqual(controller.historyPreparationCount, 2)
        XCTAssertEqual(controller.collections.count, 1)
    }

    func testExpiryWithinSameTimeBucketReusesMemoButPrunesDurableEvidence() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory, now: { F.now })
        let oldest = F.event("oldest", at: F.now.addingTimeInterval(-60 * 86_400))
        for event in [oldest] + Array(F.recurring.prefix(2)) {
            _ = library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 30)
        }
        var clock = F.now
        let controller = MomentMixController(store: MomentMixStore(now: F.now.addingTimeInterval(-61 * 86_400)),
                                            now: { clock }, calendar: { F.calendar })
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        XCTAssertEqual(controller.store.snapshot.evidence.count, 3)
        let revision = library.historyRevision
        clock = F.now.addingTimeInterval(1)
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        XCTAssertEqual(library.historyRevision, revision)
        XCTAssertEqual(controller.historyPreparationCount, 1)
        XCTAssertEqual(controller.store.snapshot.evidence.count, 2)
        XCTAssertFalse(controller.store.snapshot.evidence.contains { $0.eventID == oldest.id })
    }

    func testBoundedSelectionExpiresAtExactBoundaryWithoutResortingHistory() {
        let start = F.now.addingTimeInterval(-61 * 86_400)
        let oldest = F.event("oldest", at: F.now.addingTimeInterval(-60 * 86_400))
        let events = (0..<2_100).map { F.event("song\($0)", at: F.now.addingTimeInterval(-Double($0))) }
        let bounded = MomentHistorySelection.prepare(events: events, learningSince: start, now: F.now, calendar: F.calendar)
        XCTAssertEqual(bounded.events(at: F.now).count, 2_048)
        XCTAssertEqual(Set(bounded.events(at: F.now).map { $0.track.id }), Set((0..<2_048).map { "song\($0)" }))
        let boundary = MomentHistorySelection.prepare(events: [oldest], learningSince: start, now: F.now, calendar: F.calendar)
        XCTAssertEqual(boundary.events(at: F.now).count, 1)
        XCTAssertTrue(boundary.canReuse(learningSince: start, now: F.now.addingTimeInterval(1), calendar: F.calendar))
        XCTAssertTrue(boundary.events(at: F.now.addingTimeInterval(1)).isEmpty)
    }
}

private actor MomentPreparationGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseFirst() async {
        guard !entered else { return }
        entered = true
        entry?.resume()
        entry = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
