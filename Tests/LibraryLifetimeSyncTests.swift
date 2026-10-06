import XCTest
@testable import GanaBajana

@MainActor
final class LibraryLifetimeSyncTests: XCTestCase {
    func testIndependentMigrationsUnionPartiallyOverlappingHistoryWithoutDoubleCounting() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let shared = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: harness.clock.now, listenedSeconds: 40)
        let onlyA = ListeningEvent(id: UUID(), track: libraryTestTrack("a"), startedAt: harness.clock.now, listenedSeconds: 50)
        let onlyB = ListeningEvent(id: UUID(), track: libraryTestTrack("b"), startedAt: harness.clock.now, listenedSeconds: 60)
        for (id, events) in [(LibrarySyncTestData.a, [shared, onlyA]), (LibrarySyncTestData.b, [shared, onlyB])] {
            let directory = harness.root.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try LifetimeListeningTestData.legacyBytes(events: events, version: 3, journalVersion: 2)
                .write(to: directory.appendingPathComponent(LibraryPersistence.fileName))
        }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let beforeA = try a.state()
        let beforeB = try b.state()
        try a.library.mergeCloudState(beforeB)
        try b.library.mergeCloudState(beforeA)
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 150)
        XCTAssertEqual(a.library.lifetimeListeningSummary.plays, 3)
        XCTAssertEqual(a.library.lifetimeListeningSummary, b.library.lifetimeListeningSummary)
        let commits = a.library.durableCommitCount
        try a.library.mergeCloudState(beforeB)
        try a.library.mergeCloudState(b.state())
        XCTAssertEqual(a.library.durableCommitCount, commits)
        XCTAssertEqual(try a.saved().lifetimeListening.summary, a.library.lifetimeListeningSummary)
    }

    func testConcurrentSharedSessionExtensionsTakeMaximumWhileIndependentSessionsAdd() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let song = libraryTestTrack()
        let session = UUID()
        XCTAssertTrue(a.library.recordListening(track: song, sessionID: session, startedAt: harness.clock.now, seconds: 20))
        try b.library.mergeCloudState(a.state())
        XCTAssertTrue(a.library.recordListening(track: song, sessionID: session, startedAt: harness.clock.now, seconds: 15))
        XCTAssertTrue(b.library.recordListening(track: song, sessionID: session, startedAt: harness.clock.now, seconds: 5))
        XCTAssertTrue(a.library.recordListening(track: song, sessionID: UUID(), startedAt: harness.clock.now, seconds: 40))
        XCTAssertTrue(b.library.recordListening(track: song, sessionID: UUID(), startedAt: harness.clock.now, seconds: 45))
        let stateA = try a.state()
        let stateB = try b.state()
        try a.library.mergeCloudState(stateB)
        try b.library.mergeCloudState(stateA)
        for library in [a.library, b.library] {
            XCTAssertEqual(library.lifetimeListeningSummary.seconds, 120)
            XCTAssertEqual(library.lifetimeListeningSummary.plays, 3)
            XCTAssertEqual(library.events.first(where: { $0.id == session })?.listenedSeconds, 35)
            try library.mergeCloudState(stateA)
            try library.mergeCloudState(stateB)
            XCTAssertEqual(library.lifetimeListeningSummary.seconds, 120)
        }
    }

    func testClearGenerationRejectsLateOfflineRollupsAndAllowsNewHistory() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let song = libraryTestTrack()
        let session = UUID()
        let started = harness.clock.now
        XCTAssertTrue(a.library.recordListening(track: song, sessionID: session, startedAt: started, seconds: 40))
        let old = try a.state()
        try b.library.mergeCloudState(old)
        a.library.clearHistory()
        let cleared = try a.state()
        harness.clock.advance(by: 100)
        XCTAssertTrue(b.library.recordListening(track: song, sessionID: session, startedAt: started, seconds: 15))
        let stale = try b.state()
        try a.library.mergeCloudState(stale)
        try b.library.mergeCloudState(cleared)
        for library in [a.library, b.library] {
            XCTAssertEqual(library.lifetimeListeningSummary, LifetimeListeningSummary())
            XCTAssertTrue(library.events.isEmpty)
        }
        XCTAssertTrue(b.library.recordListening(track: song, sessionID: UUID(), startedAt: harness.clock.now, seconds: 5))
        try a.library.mergeCloudState(b.state())
        try a.library.mergeCloudState(old)
        try a.library.mergeCloudState(stale)
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 5)
        XCTAssertEqual(a.library.lifetimeListeningSummary.coverageStartedAt, harness.clock.now)
    }

    func testPrunedReceiptsSurviveTwoDeviceSyncAndRepeatedOldReplicaReplay() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        XCTAssertTrue(a.library.recordListening(track: libraryTestTrack(), sessionID: UUID(),
                                               startedAt: harness.clock.now, seconds: 80))
        let old = try a.state()
        harness.clock.advance(by: 500 * 86_400)
        try b.library.mergeCloudState(old)
        try a.library.mergeCloudState(b.state())
        for library in [a.library, b.library] {
            XCTAssertTrue(library.events.isEmpty)
            XCTAssertEqual(library.lifetimeListeningSummary.seconds, 80)
            for _ in 0..<3 { try library.mergeCloudState(old) }
            XCTAssertTrue(library.events.isEmpty)
            XCTAssertEqual(library.lifetimeListeningSummary.seconds, 80)
        }
        let saved = try a.state()
        XCTAssertEqual(saved.registers.filter { $0.key.collection == .lifetimeSession }.count, 1)
        XCTAssertTrue(saved.registers.keys.allSatisfy { $0.collection != .event })
    }

    func testLegacyReplicaVersionsMigrateReceiptsWithoutRestampingTheEvent() throws {
        for version in 1...2 {
            let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: LibrarySyncTestData.now, listenedSeconds: 35)
            var state = try LibrarySyncTestData.single(.event, event.id.uuidString, value: event,
                                                      revision: LibrarySyncTestData.revision(10))
            state.version = version
            var replica = LibrarySyncReplica(replicaID: LibrarySyncTestData.a, state: state)
            replica.version = version
            let data = try LibrarySyncCodec.encodeReplica(replica)
            let read = try LibrarySyncCodec.decodeReplica(data, expectedReplicaID: replica.replicaID, now: LibrarySyncTestData.now)
            let joined = try LibrarySyncMerge.joined(LibrarySyncState(), read.state)
            let eventRegister = try XCTUnwrap(joined.registers[LibrarySyncKey(.event, event.id.uuidString)])
            let receipt = try XCTUnwrap(joined.registers[LibrarySyncKey(.lifetimeSession, event.id.uuidString)])
            XCTAssertEqual(receipt.revision, eventRegister.revision)
            XCTAssertEqual(eventRegister.revision, LibrarySyncTestData.revision(10))
            XCTAssertEqual(try LibraryLifetimeSync.materialize(joined).summary.seconds, 35)
        }
    }

    func testMalformedOrConflictingRemoteReceiptPreservesLocalBytesAndTotals() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: harness.clock.now, listenedSeconds: 35)
        XCTAssertTrue(a.library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 35))
        let bytes = try Data(contentsOf: a.fileURL)
        for kind in 0..<3 {
            var receipt = LifetimeListeningContribution(event)
            if kind == 1 { receipt.identity = String(repeating: "0", count: 64) }
            else if kind == 0 { receipt.seconds = -1 }
            var incoming = try LibrarySyncTestData.single(.lifetimeSession, event.id.uuidString, value: receipt,
                                                          revision: LibrarySyncTestData.revision(100))
            if kind == 2 {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibrarySyncCodec.encode(receipt)) as? [String: Any])
                object["futureCounter"] = 1
                incoming.registers[LibrarySyncKey(.lifetimeSession, event.id.uuidString)]?.value = try JSONSerialization.data(withJSONObject: object)
            }
            XCTAssertThrowsError(try a.library.mergeCloudState(incoming))
            XCTAssertEqual(try Data(contentsOf: a.fileURL), bytes)
            XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 35)
        }
    }

    func testFutureCorruptAndOldVersionSmuggledRollupsAreNotOverwritten() throws {
        for kind in 0..<5 {
            try withLibraryTestDirectory { directory in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(LibraryDocument())) as? [String: Any])
                switch kind {
                case 0: object["version"] = LibraryPersistence.currentVersion + 1
                case 1: object["lifetimeListening"] = ["sessions": ["invalid": ["seconds": -1]]]
                case 2: object["version"] = 3
                case 3: object.removeValue(forKey: "lifetimeListening")
                default: object["lifetimeListening"] = ["sessions": [:], "futureCounter": 10] as [String: Any]
                }
                let bytes = try JSONSerialization.data(withJSONObject: object)
                let file = directory.appendingPathComponent(LibraryPersistence.fileName)
                try bytes.write(to: file)
                let library = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
                XCTAssertTrue(library.requiresReload)
                library.clearHistory()
                library.toggleFavorite(libraryTestTrack())
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            }
        }
    }
}
