import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySyncCheckpointTests: XCTestCase {
    func testTenThousandSessionCheckpointBenchmarkUsesNoFullProjectionWhileSyncIsOff() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let time = LibrarySyncTestData.now
        let document = try seededDocument(eventCount: 10_000)
        let file = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        try LibraryPersistence.write(LibraryPersistence.encode(document), to: file, replacing: nil)
        var fullProjections = 0
        let library = LibraryStore(directory: harness.root, now: { time }, writerID: LibrarySyncTestData.b,
                                   projectSyncValues: { document in
            fullProjections += 1
            return try LibrarySyncProjection.values(document)
        })
        let transport = LibrarySyncTestTransport(cloud: harness.cloud)
        let sync = ICloudLibrarySync(library: library, transport: transport,
                                    configuration: LibrarySyncTestConfiguration(replicaID: LibrarySyncTestData.b))
        sync.setEnabled(false)
        XCTAssertFalse(sync.isEnabled)
        XCTAssertNil(library.errorMessage)
        let before = try library.cloudReplica(replicaID: LibrarySyncTestData.b).state
        let event = document.events[5_000]

        let listeningMS = millisecondsPerCommit { _ in
            XCTAssertTrue(library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 15))
            XCTAssertNil(library.errorMessage)
        }
        let recentMS = millisecondsPerCommit { index in
            library.recordRecent(track: event.track, position: Double(index))
            XCTAssertNil(library.errorMessage)
        }
        let playbackMS = millisecondsPerCommit { index in
            library.updatePlayback(PlaybackSnapshot(queue: [event.track], position: Double(index), originalQueue: [event.track]))
            XCTAssertNil(library.errorMessage)
        }
        let tipMS = millisecondsPerCommit { index in
            XCTAssertTrue(library.recordTip(transactionID: UInt64(index), credited: true))
        }
        XCTAssertTrue(library.acknowledgeReleaseNotification(id: "release"))
        XCTAssertEqual(fullProjections, 0, "Steady-state listening, recents and device-only writes must not encode the shared projection")
        XCTAssertEqual(transport.reads, 0)
        XCTAssertEqual(library.events.count, 10_000)
        XCTAssertEqual(library.events.first { $0.id == event.id }?.listenedSeconds, 105)
        let after = try library.cloudReplica(replicaID: LibrarySyncTestData.b).state
        let changed = Set([LibrarySyncKey(.event, event.id.uuidString), LibrarySyncKey(.recent, event.track.id)])
        for (key, register) in before.registers where !changed.contains(key) {
            XCTAssertEqual(after.registers[key], register)
        }
        let reopened = LibraryStore(directory: harness.root, now: { time })
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.events.first { $0.id == event.id }?.listenedSeconds, 105)
        XCTAssertEqual(reopened.recentlyPlayed.first?.position, 5)
        XCTAssertEqual(reopened.playback.position, 5)
        XCTAssertEqual(reopened.tipCount, 5)
        XCTAssertTrue(reopened.pendingReleaseNotifications.isEmpty)
        let size = try Data(contentsOf: file).count
        print("Library sync checkpoint benchmark: 10000 retained sessions; \(size) bytes; full commit projections \(fullProjections); listening \(listeningMS) ms, recent \(recentMS) ms, playback \(playbackMS) ms, tip \(tipMS) ms per commit (5 writes each).")
    }

    func testGeneralSharedEditsReuseExactlyOneBeforeAndAfterProjection() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let document = try seededDocument(eventCount: 10)
        let file = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        try LibraryPersistence.write(LibraryPersistence.encode(document), to: file, replacing: nil)
        var fullProjections = 0
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now }, projectSyncValues: { document in
            fullProjections += 1
            return try LibrarySyncProjection.values(document)
        })
        library.preferences.appearance = .light
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(fullProjections, 2)
        library.setLyricsOffset(1.25, for: "song")
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(fullProjections, 4)
        let reloaded = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        XCTAssertEqual(reloaded.preferences.appearance, .light)
        XCTAssertEqual(reloaded.lyricsOffset(for: "song"), 1.25)
    }

    func testLegacyListeningBootstrapProjectsOnceAndSubsequentCheckpointsStayTargeted() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        var document = try seededDocument(eventCount: 5)
        document.version = 1
        document.syncState = nil
        document.preferences.appearance = .light
        let file = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        try LibraryPersistence.write(LibraryPersistence.encode(document), to: file, replacing: nil)
        var fullProjections = 0
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now }, projectSyncValues: { document in
            fullProjections += 1
            return try LibrarySyncProjection.values(document)
        })
        let event = document.events[0]
        XCTAssertTrue(library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 5))
        XCTAssertEqual(fullProjections, 1)
        XCTAssertTrue(library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 7))
        library.recordRecent(track: event.track, position: 12)
        XCTAssertEqual(fullProjections, 1)
        let reopened = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.events.first { $0.id == event.id }?.listenedSeconds, 42)
        XCTAssertEqual(reopened.preferences.appearance, .light)
        XCTAssertEqual(reopened.favorites, document.favorites)
        XCTAssertEqual(reopened.followedArtists, document.followedArtists)
        XCTAssertEqual(reopened.releases, document.releases)
    }

    func testTargetedCheckpointExpiresHistoryRegistersWithoutFullProjectionOrPrivacyCallback() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let time = LibrarySyncTestData.now
        let clock = harness.clock
        var document = try seededDocument(eventCount: 1)
        let expired = ListeningEvent(id: UUID(), track: libraryTestTrack("old"), startedAt: time.addingTimeInterval(-390 * 86_400), listenedSeconds: 20)
        document.events.append(expired)
        document.recentlyPlayed = [RecentListen(track: expired.track, playedAt: expired.startedAt, position: 2)]
        document.syncState = try LibrarySyncJournal.seed(document, now: time, writer: LibrarySyncTestData.a)
        let file = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        try LibraryPersistence.write(LibraryPersistence.encode(document), to: file, replacing: nil)
        let library = LibraryStore(directory: harness.root, now: { clock.now }, writerID: LibrarySyncTestData.b,
                                   projectSyncValues: { _ in throw LibrarySyncError.invalidData("unexpected full projection") })
        var privacyCallbacks = 0
        library.onHistoryCleared = { privacyCallbacks += 1 }
        clock.advance(by: 20 * 86_400)
        let event = document.events[0]
        XCTAssertTrue(library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 5))
        let state = try library.cloudReplica(replicaID: LibrarySyncTestData.b).state
        XCTAssertEqual(library.events.map(\.id), [event.id])
        XCTAssertTrue(library.recentlyPlayed.isEmpty)
        XCTAssertNil(state.registers[LibrarySyncKey(.event, expired.id.uuidString)])
        XCTAssertNil(state.registers[LibrarySyncKey(.recent, expired.track.id)])
        XCTAssertEqual(privacyCallbacks, 0)
        let oldID = UUID()
        XCTAssertTrue(library.recordListening(track: event.track, sessionID: oldID, startedAt: time.addingTimeInterval(-800 * 86_400), seconds: 5))
        XCTAssertNil(try library.cloudReplica(replicaID: LibrarySyncTestData.b).state.registers[LibrarySyncKey(.event, oldID.uuidString)])
        XCTAssertEqual(privacyCallbacks, 0)
        XCTAssertNoThrow(try LibraryPersistence.decode(Data(contentsOf: file), now: clock.now))
    }

    func testDeviceOnlyCommitStillCompactsExpiredHistoryWithoutProjectingOrChangingOtherRegisters() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let clock = harness.clock
        let document = try seededDocument(eventCount: 1)
        let file = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        try LibraryPersistence.write(LibraryPersistence.encode(document), to: file, replacing: nil)
        let library = LibraryStore(directory: harness.root, now: { clock.now }, projectSyncValues: { _ in
            throw LibrarySyncError.invalidData("unexpected full projection")
        })
        clock.advance(by: 410 * 86_400)
        library.updatePlayback(PlaybackSnapshot(queue: document.favorites, position: 9, originalQueue: document.favorites))
        XCTAssertNil(library.errorMessage)
        XCTAssertTrue(library.events.isEmpty)
        let state = try library.cloudReplica(replicaID: LibrarySyncTestData.b).state
        XCTAssertFalse(state.registers.keys.contains { $0.collection == .event })
        for (key, register) in try XCTUnwrap(document.syncState).registers where key.collection != .event {
            XCTAssertEqual(state.registers[key], register)
        }
        XCTAssertNoThrow(try LibraryPersistence.decode(Data(contentsOf: file), now: clock.now))
    }

    func testFailedTargetedWriteDoesNotAcknowledgeOrAdvanceRevisionAndRetryCommitsOnce() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let document = try seededDocument(eventCount: 1)
        let file = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        let original = try LibraryPersistence.encode(document)
        try LibraryPersistence.write(original, to: file, replacing: nil)
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now }, writerID: LibrarySyncTestData.b,
                                   projectSyncValues: { _ in throw LibrarySyncError.invalidData("unexpected full projection") })
        let backup = harness.root.appendingPathComponent("backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let event = document.events[0]
        XCTAssertFalse(library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 7))
        XCTAssertEqual(library.events.first?.listenedSeconds, 30)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        XCTAssertTrue(library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 7))
        let after = try library.cloudReplica(replicaID: LibrarySyncTestData.b).state
        XCTAssertEqual(after.clock?.counter, try XCTUnwrap(document.syncState?.clock).counter + 1)
        XCTAssertEqual(library.events.first?.listenedSeconds, 37)
        XCTAssertEqual(try LibraryPersistence.decode(Data(contentsOf: file), now: LibrarySyncTestData.now).events.first?.listenedSeconds, 37)
    }

    private func seededDocument(eventCount: Int) throws -> LibraryDocument {
        let time = LibrarySyncTestData.now
        let track = libraryTestTrack("checkpoint")
        var document = LibraryDocument()
        document.favorites = [track]
        document.playback = PlaybackSnapshot(queue: [track], originalQueue: [track])
        document.followedArtists = [FollowedArtist(id: "artist", name: "Artist", followedAt: time,
                                                   knownReleaseIDs: ["release"], hasEstablishedReleaseBaseline: true)]
        document.releases = [ArtistRelease(id: "release", title: "Release", subtitle: "", artistID: "artist",
                                          artistName: "Artist", discoveredAt: time)]
        document.pendingReleaseNotificationIDs = ["release"]
        document.events = (0..<eventCount).map { index in
            ListeningEvent(id: UUID(), track: track, startedAt: time.addingTimeInterval(-Double(index + 1) * 900), listenedSeconds: 30)
        }
        document.syncState = try LibrarySyncJournal.seed(document, now: time, writer: LibrarySyncTestData.a)
        return document
    }

    private func millisecondsPerCommit(_ body: (Int) -> Void) -> Double {
        let start = ContinuousClock.now
        for index in 1...5 { body(index) }
        let elapsed = start.duration(to: .now).components
        return (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) / 5
    }
}
