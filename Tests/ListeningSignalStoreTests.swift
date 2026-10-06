import XCTest
@testable import GanaBajana

@MainActor
final class ListeningSignalStoreTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ListeningSignalStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent(ListeningSignalStore.fileName)
    }

    private func signal(_ number: Int, at endedAt: Date? = nil, title: String = "Song",
                        artists: [String] = ["Artist"]) -> ListeningSignal {
        ListeningSignal(trackID: "saavn:\(number)", title: title, artists: artists,
                        endedAt: endedAt ?? date.addingTimeInterval(Double(number)), listenedSeconds: 4, duration: 200,
                        ending: .skipped, origin: .generated, rapid: false)
    }

    /// A long coalescing delay keeps writes under the test's control through `flush()`.
    private func makeStore(_ url: URL?, epoch: UUID? = nil, now: Date? = nil, deferLoading: Bool = false) -> ListeningSignalStore {
        let clock = now ?? date.addingTimeInterval(3_600)
        return ListeningSignalStore(url: url, historyEpoch: epoch, deferLoading: deferLoading,
                                    saveDelay: .seconds(60), now: { clock })
    }

    private func document(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testWritesCoalesceAtomicallyAndPublishOnlyAfterDurability() throws {
        let url = try temporaryURL()
        let epoch = UUID()
        let store = makeStore(url, epoch: epoch)
        XCTAssertEqual(store.revision, 0)
        for number in 0..<3 { XCTAssertTrue(store.record(signal(number), historyEpoch: epoch, enabled: true)) }
        XCTAssertTrue(store.signals.isEmpty, "Signals become visible with the coalesced write")
        XCTAssertEqual(store.revision, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        store.flush()
        XCTAssertEqual(store.signals, (0..<3).map { signal($0) })
        XCTAssertEqual(store.revision, 1)
        store.flush()
        XCTAssertEqual(store.revision, 1, "An idle flush is not a durable change")
        let raw = try document(at: url)
        XCTAssertEqual(raw["version"] as? Int, 1)
        XCTAssertEqual(raw["historyEpoch"] as? String, epoch.uuidString)
        XCTAssertEqual((raw["signals"] as? [Any])?.count, 3)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let folder = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(folder, [ListeningSignalStore.fileName], "The atomic install leaves no temporary file behind")
        XCTAssertEqual(makeStore(url, epoch: epoch).signals, store.signals)
    }

    func testCoalescedWriteLandsAfterItsDelayWithoutAFlush() async throws {
        let url = try temporaryURL()
        let now = date.addingTimeInterval(60)
        let store = ListeningSignalStore(url: url, saveDelay: .milliseconds(100), now: { now })
        XCTAssertTrue(store.record(signal(1), historyEpoch: nil, enabled: true))
        XCTAssertTrue(store.record(signal(2), historyEpoch: nil, enabled: true))
        try await PlaybackTestSupport.waitUntil(timeout: 3) { !store.signals.isEmpty }
        XCTAssertEqual(store.signals, [signal(1), signal(2)])
        XCTAssertEqual(store.revision, 1, "Both signals arrived in one write")
        XCTAssertEqual((try document(at: url)["signals"] as? [Any])?.count, 2)
    }

    func testBoundsKeepTheNewest2048WithinNinetyDays() throws {
        let url = try temporaryURL()
        let now = date.addingTimeInterval(100 * 86_400)
        let store = makeStore(url, now: now)
        XCTAssertTrue(store.record(signal(-2, at: now.addingTimeInterval(-91 * 86_400)), historyEpoch: nil, enabled: true))
        XCTAssertTrue(store.record(signal(-1, at: now.addingTimeInterval(-90 * 86_400 - 1)), historyEpoch: nil, enabled: true))
        let recent = (0..<2_100).map { signal($0, at: now.addingTimeInterval(Double($0 - 2_100))) }
        for item in recent { XCTAssertTrue(store.record(item, historyEpoch: nil, enabled: true)) }
        store.flush()
        XCTAssertEqual(store.signals.count, ListeningSignalStore.capacity)
        XCTAssertEqual(store.signals, Array(recent.suffix(ListeningSignalStore.capacity)))
        XCTAssertEqual(makeStore(url, now: now).signals, store.signals)

        let later = now.addingTimeInterval(90 * 86_400 - 1_000)
        let relaunched = makeStore(url, now: later)
        XCTAssertEqual(relaunched.signals, recent.filter { $0.endedAt >= later.addingTimeInterval(-ListeningSignalStore.retention) })
        XCTAssertEqual(relaunched.signals.count, 1_000)
        relaunched.flush()
        XCTAssertEqual((try document(at: url)["signals"] as? [Any])?.count, 1_000, "Expired signals leave the file too")
    }

    func testOversizedNamesAreTrimmedAndTheOldestGiveWayToTheReadCap() throws {
        let url = try temporaryURL()
        let store = makeStore(url)
        let long = String(repeating: "é", count: 500)
        for number in 0..<200 {
            XCTAssertTrue(store.record(signal(number, title: long, artists: Array(repeating: long, count: 40)),
                                       historyEpoch: nil, enabled: true))
        }
        store.flush()
        XCTAssertFalse(store.isBlocked)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, ListeningSignalStore.maximumBytes)
        XCTAssertLessThan(store.signals.count, 200)
        XCTAssertGreaterThan(store.signals.count, 20)
        XCTAssertEqual(store.signals.last?.trackID, signal(199).trackID, "The newest signals survive")
        XCTAssertTrue(store.signals.allSatisfy {
            $0.title.count == ListeningSignalStore.maximumTextCharacters && $0.artists.count == ListeningSignalStore.maximumArtists
        })
        XCTAssertEqual(makeStore(url).signals, store.signals)
    }

    func testUnreadableFilesArePreservedAndBlockRecordingUntilAReloadSucceeds() throws {
        let url = try temporaryURL()
        let writer = makeStore(url)
        writer.record(signal(1), historyEpoch: nil, enabled: true)
        writer.flush()
        let good = try Data(contentsOf: url)
        let raw = try document(at: url)
        let rows = try XCTUnwrap(raw["signals"] as? [[String: Any]])
        var future = raw
        future["version"] = 2
        var unsupported = raw
        unsupported["version"] = 0
        var unknownField = raw
        var tagged = rows[0]
        tagged["providerRequest"] = "https://example.com/signed-media?token=secret"
        unknownField["signals"] = [tagged]
        var unknownEnding = raw
        var abandoned = rows[0]
        abandoned["ending"] = "abandoned"
        unknownEnding["signals"] = [abandoned]
        var negativeSeconds = raw
        var negative = rows[0]
        negative["listenedSeconds"] = -1
        negativeSeconds["signals"] = [negative]
        let rejected = try [future, unsupported, unknownField, unknownEnding, negativeSeconds].map {
            try JSONSerialization.data(withJSONObject: $0)
        } + [Data("not json".utf8), Data(repeating: 32, count: ListeningSignalStore.maximumBytes + 1)]

        for (index, data) in rejected.enumerated() {
            try data.write(to: url, options: .atomic)
            let store = makeStore(url)
            XCTAssertTrue(store.isBlocked)
            XCTAssertNotNil(store.errorMessage)
            if index == 0 { XCTAssertEqual(store.errorMessage?.contains("newer version"), true) }
            XCTAssertTrue(store.signals.isEmpty)
            XCTAssertFalse(store.record(signal(2), historyEpoch: nil, enabled: true))
            store.flush()
            store.synchronize(historyEpoch: UUID(), enabled: false)
            store.flush()
            XCTAssertEqual(try Data(contentsOf: url), data, "The unreadable file is never overwritten")

            try good.write(to: url, options: .atomic)
            store.synchronize(historyEpoch: nil, enabled: true)
            XCTAssertFalse(store.record(signal(2), historyEpoch: nil, enabled: true), "Blocked until an explicit reload")
            XCTAssertEqual(try Data(contentsOf: url), good)
            store.reload(historyEpoch: nil, enabled: true)
            XCTAssertFalse(store.isBlocked)
            XCTAssertNil(store.errorMessage)
            XCTAssertTrue(store.signals.isEmpty, "The erase requested while blocked wins over the recovered file")
            XCTAssertTrue(store.record(signal(3), historyEpoch: nil, enabled: true))
            store.flush()
            XCTAssertEqual(makeStore(url).signals, [signal(3)])
            try good.write(to: url, options: .atomic)
        }

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let directory = makeStore(url)
        XCTAssertTrue(directory.isBlocked, "A folder in the file's place is not an empty store")
        XCTAssertFalse(directory.record(signal(4), historyEpoch: nil, enabled: true))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testForeignWriteBlocksTheStaleStoreAndPreservesTheOtherCopy() throws {
        let url = try temporaryURL()
        let first = makeStore(url)
        first.record(signal(1), historyEpoch: nil, enabled: true)
        first.flush()
        let other = makeStore(url)
        other.record(signal(2), historyEpoch: nil, enabled: true)
        other.flush()
        let foreign = try Data(contentsOf: url)

        XCTAssertTrue(first.record(signal(3), historyEpoch: nil, enabled: true))
        first.flush()
        XCTAssertTrue(first.isBlocked)
        XCTAssertNotNil(first.errorMessage)
        XCTAssertEqual(first.signals, [signal(1)], "A failed write publishes nothing")
        XCTAssertEqual(try Data(contentsOf: url), foreign)
        XCTAssertFalse(first.record(signal(4), historyEpoch: nil, enabled: true))
        first.flush()
        XCTAssertEqual(try Data(contentsOf: url), foreign)

        first.reload(historyEpoch: nil, enabled: true)
        XCTAssertFalse(first.isBlocked)
        XCTAssertEqual(first.signals, [signal(1), signal(2)])
        XCTAssertEqual(first.signals, other.signals)
    }

    func testHistoryOffErasesAtOnceAndDurablyAndRecordsNothingUntilEnabled() throws {
        let url = try temporaryURL()
        let epoch = UUID()
        let store = makeStore(url, epoch: epoch)
        store.record(signal(1), historyEpoch: epoch, enabled: true)
        store.flush()
        let revision = store.revision

        store.synchronize(historyEpoch: epoch, enabled: false)
        XCTAssertTrue(store.signals.isEmpty)
        XCTAssertGreaterThan(store.revision, revision)
        XCTAssertEqual((try document(at: url)["signals"] as? [Any])?.count, 0)
        XCTAssertFalse(store.record(signal(2), historyEpoch: epoch, enabled: false))
        store.flush()
        XCTAssertEqual((try document(at: url)["signals"] as? [Any])?.count, 0)

        store.synchronize(historyEpoch: epoch, enabled: true)
        XCTAssertTrue(store.record(signal(3), historyEpoch: epoch, enabled: true))
        store.flush()
        XCTAssertEqual(makeStore(url, epoch: epoch).signals, [signal(3)])
        XCTAssertFalse(store.record(signal(4), historyEpoch: epoch, enabled: false), "A missed preference callback still stops recording")
        XCTAssertTrue(store.signals.isEmpty)
        XCTAssertEqual((try document(at: url)["signals"] as? [Any])?.count, 0)
    }

    func testNewEpochErasesAndARelaunchUnderAnotherEpochClearsAMissedReset() throws {
        let url = try temporaryURL()
        let epoch = UUID()
        let store = makeStore(url, epoch: epoch)
        store.record(signal(1), historyEpoch: epoch, enabled: true)
        store.flush()
        let cleared = UUID()
        store.synchronize(historyEpoch: cleared, enabled: true)
        XCTAssertTrue(store.signals.isEmpty)
        var raw = try document(at: url)
        XCTAssertEqual(raw["historyEpoch"] as? String, cleared.uuidString)
        XCTAssertEqual((raw["signals"] as? [Any])?.count, 0)

        store.record(signal(2), historyEpoch: cleared, enabled: true)
        store.flush()
        XCTAssertEqual(makeStore(url, epoch: cleared).signals, [signal(2)])
        let relaunched = makeStore(url, epoch: UUID())
        XCTAssertTrue(relaunched.signals.isEmpty)
        XCTAssertFalse(relaunched.isBlocked)
        raw = try document(at: url)
        XCTAssertEqual((raw["signals"] as? [Any])?.count, 0)
    }

    func testDeferredStoreNeitherLoadsNorRecordsUntilTheLibraryEpochIsTrustworthy() throws {
        let url = try temporaryURL()
        let epoch = UUID()
        let writer = makeStore(url, epoch: epoch)
        writer.record(signal(1), historyEpoch: epoch, enabled: true)
        writer.flush()
        let saved = try Data(contentsOf: url)

        let waiting = makeStore(url, deferLoading: true)
        XCTAssertTrue(waiting.signals.isEmpty)
        XCTAssertFalse(waiting.record(signal(2), historyEpoch: nil, enabled: true))
        waiting.flush()
        XCTAssertEqual(try Data(contentsOf: url), saved, "An unknown library epoch is not a history reset")
        waiting.synchronize(historyEpoch: epoch, enabled: true)
        XCTAssertEqual(waiting.signals, [signal(1)])
        XCTAssertEqual(try Data(contentsOf: url), saved)
        waiting.synchronize(historyEpoch: UUID(), enabled: true)
        XCTAssertTrue(waiting.signals.isEmpty, "A genuine clear after recovery still erases")
    }

    func testFailedEraseStaysPendingAndWinsOverRecoveredSignals() throws {
        let url = try temporaryURL()
        let epoch = UUID()
        let store = makeStore(url, epoch: epoch)
        store.record(signal(1), historyEpoch: epoch, enabled: true)
        store.flush()
        let other = makeStore(url, epoch: epoch)
        other.record(signal(2), historyEpoch: epoch, enabled: true)
        other.flush()
        let foreign = try Data(contentsOf: url)

        store.synchronize(historyEpoch: epoch, enabled: false)
        XCTAssertTrue(store.signals.isEmpty, "Erasure is visible even though its write failed")
        XCTAssertTrue(store.isBlocked)
        XCTAssertEqual(try Data(contentsOf: url), foreign)
        store.synchronize(historyEpoch: epoch, enabled: true)
        XCTAssertFalse(store.record(signal(3), historyEpoch: epoch, enabled: true))
        XCTAssertTrue(store.signals.isEmpty)

        store.reload(historyEpoch: epoch, enabled: true)
        XCTAssertFalse(store.isBlocked)
        XCTAssertTrue(store.signals.isEmpty)
        XCTAssertTrue(makeStore(url, epoch: epoch).signals.isEmpty)
    }

    func testMemoryOnlyStoresPublishAtOnceStayIsolatedAndStillErase() {
        let memory = makeStore(nil)
        let other = makeStore(nil)
        XCTAssertTrue(memory.record(signal(1), historyEpoch: nil, enabled: true))
        XCTAssertEqual(memory.signals, [signal(1)])
        XCTAssertEqual(memory.revision, 1)
        XCTAssertTrue(other.signals.isEmpty)

        memory.synchronize(historyEpoch: nil, enabled: false)
        XCTAssertTrue(memory.signals.isEmpty)
        XCTAssertFalse(memory.record(signal(2), historyEpoch: nil, enabled: false))
        memory.synchronize(historyEpoch: nil, enabled: true)
        XCTAssertTrue(memory.record(signal(3), historyEpoch: nil, enabled: true))
        XCTAssertEqual(memory.signals, [signal(3)])
        memory.synchronize(historyEpoch: UUID(), enabled: true)
        XCTAssertTrue(memory.signals.isEmpty)
        XCTAssertFalse(memory.isBlocked)

        let deferred = makeStore(nil, deferLoading: true)
        XCTAssertFalse(deferred.record(signal(4), historyEpoch: nil, enabled: true))
        deferred.synchronize(historyEpoch: nil, enabled: true)
        XCTAssertTrue(deferred.record(signal(5), historyEpoch: nil, enabled: true))
        XCTAssertEqual(deferred.signals, [signal(5)])
    }

    func testInvalidSignalsAreRejectedWithoutTouchingTheFile() throws {
        let url = try temporaryURL()
        let store = makeStore(url)
        var blank = signal(1)
        blank.trackID = " "
        var beforeEpoch = signal(2)
        beforeEpoch.endedAt = Date(timeIntervalSince1970: -1)
        var unknownSeconds = signal(3)
        unknownSeconds.listenedSeconds = .nan
        for item in [blank, beforeEpoch, unknownSeconds] {
            XCTAssertFalse(store.record(item, historyEpoch: nil, enabled: true))
        }
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "No signal, no file")

        var unknownDuration = signal(4)
        unknownDuration.duration = -5
        XCTAssertTrue(store.record(unknownDuration, historyEpoch: nil, enabled: true))
        store.flush()
        XCTAssertEqual(store.signals.map(\.trackID), [unknownDuration.trackID])
        XCTAssertNil(store.signals.first?.duration, "An invalid duration is kept as unknown")
        XCTAssertFalse(store.isBlocked)
    }
}
