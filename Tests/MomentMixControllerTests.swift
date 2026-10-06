import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class MomentMixControllerTests: XCTestCase {
    private typealias F = MomentMixFixtures

    func testStoredEventsUnlockCardsThenDislikesAndPerMixSwitchRemoveThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory, now: { F.now })
        let controller = MomentMixController(store: MomentMixStore(now: F.start), now: { F.now }, calendar: { F.calendar })
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        let events = F.recurring
        for (index, event) in events.enumerated() {
            XCTAssertTrue(library.recordListening(track: event.track, sessionID: event.id,
                                                  startedAt: event.startedAt, seconds: event.listenedSeconds))
            controller.synchronize(library: library, historyEpoch: nil)
            await controller.waitForPendingPreparation()
            XCTAssertEqual(controller.collections.count, index < 2 ? 0 : 1)
        }
        let mix = try XCTUnwrap(controller.collections.first)
        XCTAssertEqual(Set(mix.tracks.map(\.id)), Set(events.map { $0.track.id }))
        let context = try XCTUnwrap(controller.summaries.first).context
        controller.setMixEnabled(false, context: context)
        XCTAssertTrue(controller.collections.isEmpty)
        XCTAssertTrue(controller.settingsContexts.contains(context))
        controller.setMixEnabled(true, context: context)
        XCTAssertEqual(controller.collections.count, 1)
        library.toggleDislike(events[0].track)
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        XCTAssertTrue(controller.collections.isEmpty, "Only two eligible songs remain")
        XCTAssertNil(controller.capture(), "Fixture controllers never read native routes")
        XCTAssertFalse(controller.canEnableMotion)
    }

    func testDurableClearCallbackAndHistoryPreferenceHideCards() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory, now: { F.now })
        let controller = MomentMixController(store: MomentMixStore(now: F.start), now: { F.now }, calendar: { F.calendar })
        for event in F.recurring {
            _ = library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 30)
        }
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        XCTAssertEqual(controller.collections.count, 1)
        library.preferences.saveListeningHistory = false
        controller.synchronize(library: library, historyEpoch: nil)
        XCTAssertTrue(controller.collections.isEmpty)
        XCTAssertFalse(controller.store.canLearn)
        library.onHistoryCleared = { controller.reset(historyEpoch: UUID()) }
        library.clearHistory()
        XCTAssertTrue(controller.store.snapshot.evidence.isEmpty)
        XCTAssertTrue(controller.store.snapshot.selectedTrackIDs.isEmpty)
        XCTAssertFalse(controller.store.resetPending)
        XCTAssertTrue(library.events.isEmpty)
    }

    func testDailyRecordingOrderSurvivesLibraryGrowthAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory, now: { F.now })
        let disk = MomentMixMemoryPersistence()
        let controller = MomentMixController(store: MomentMixStore(persistence: disk, now: F.start),
                                            now: { F.now }, calendar: { F.calendar })
        for event in F.recurring {
            _ = library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 30)
        }
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        let original = try XCTUnwrap(controller.collections.first).tracks.map(\.id)
        _ = library.addFavorites((0..<20).map { F.track("favorite\($0)") })
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        XCTAssertEqual(controller.collections.first?.tracks.map(\.id), original)
        let reopened = MomentMixController(store: MomentMixStore(persistence: disk, now: F.now),
                                          now: { F.now }, calendar: { F.calendar })
        reopened.synchronize(library: library, historyEpoch: nil)
        await reopened.waitForPendingPreparation()
        XCTAssertEqual(reopened.collections.first?.tracks.map(\.id), original)
    }

    func testFailedLocalStoreResetImmediatelyHidesExistingHomeCollections() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory, now: { F.now })
        let disk = MomentMixMemoryPersistence()
        let controller = MomentMixController(store: MomentMixStore(persistence: disk, now: F.start),
                                            now: { F.now }, calendar: { F.calendar })
        for event in F.recurring {
            _ = library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 30)
        }
        controller.synchronize(library: library, historyEpoch: nil)
        await controller.waitForPendingPreparation()
        XCTAssertEqual(controller.collections.count, 1)
        disk.failWrite = true
        controller.reset(historyEpoch: UUID())
        XCTAssertTrue(controller.collections.isEmpty)
        XCTAssertTrue(controller.summaries.isEmpty)
        XCTAssertTrue(controller.store.resetPending)
        XCTAssertNotNil(controller.store.errorMessage)
    }

    func testUnavailableLibraryDoesNotEraseValidMomentFileUsingPlaceholderEpoch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a directory".utf8).write(to: file)
        let library = LibraryStore(directory: file, now: { F.now })
        XCTAssertFalse(library.hasLoadedDocument)
        let disk = MomentMixMemoryPersistence()
        let store = MomentMixStore(persistence: disk, now: F.start)
        _ = store.synchronizePrivacy(historyEnabled: true, historyEpoch: UUID(), now: F.start)
        _ = store.observe(events: F.recurring, now: F.now, calendar: F.calendar)
        let bytes = disk.data
        let controller = MomentMixController(store: store, now: { F.now }, calendar: { F.calendar })
        controller.synchronize(library: library, historyEpoch: nil)
        XCTAssertFalse(store.canLearn)
        XCTAssertTrue(controller.collections.isEmpty)
        XCTAssertEqual(store.snapshot.evidence.count, 3)
        XCTAssertEqual(disk.data, bytes)
    }
}
