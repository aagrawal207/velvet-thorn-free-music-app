import XCTest
@testable import GanaBajana

final class LifetimeListeningTests: XCTestCase {
    func testCumulativeReceiptsCountOnePlayAndSeparateSessionsCountSeparately() throws {
        let song = libraryTestTrack(duration: 20)
        var event = ListeningEvent(id: UUID(), track: song, startedAt: LibrarySyncTestData.now, listenedSeconds: 5)
        var rollup = LifetimeListeningRollup()
        try rollup.include(event)
        try rollup.include(event)
        XCTAssertEqual(rollup.summary.seconds, 5)
        XCTAssertEqual(rollup.summary.plays, 0)
        event.listenedSeconds = 10
        try rollup.include(event)
        event.listenedSeconds = 8
        try rollup.include(event)
        XCTAssertEqual(rollup.summary.seconds, 10)
        XCTAssertEqual(rollup.summary.plays, 1)
        event.id = UUID()
        event.listenedSeconds = 30
        try rollup.include(event)
        XCTAssertEqual(rollup.summary.seconds, 40)
        XCTAssertEqual(rollup.summary.plays, 2)
        XCTAssertEqual(rollup.summary.coverageStartedAt, event.startedAt)
    }

    func testContributionMergeIsCommutativeAssociativeAndIdempotent() throws {
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: LibrarySyncTestData.now, listenedSeconds: 5)
        let a = LifetimeListeningContribution(event)
        var b = a
        b.seconds = 30
        b.qualified = true
        var c = a
        c.seconds = 55
        XCTAssertEqual(try a.joined(b), try b.joined(a))
        XCTAssertEqual(try a.joined(b).joined(c), try a.joined(b.joined(c)))
        XCTAssertEqual(try b.joined(b), b)
    }

    func testConflictingRecordingAndDateNeverBecomeOneSession() throws {
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: LibrarySyncTestData.now, listenedSeconds: 35)
        var rollup = LifetimeListeningRollup()
        try rollup.include(event)
        let before = rollup
        var different = event
        different.track = libraryTestTrack("other")
        XCTAssertThrowsError(try rollup.include(different))
        different = event
        different.startedAt += 1
        XCTAssertThrowsError(try rollup.include(different))
        XCTAssertEqual(rollup, before)
    }

    func testBoundsAndInvalidCountersFailClosed() throws {
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: LibrarySyncTestData.now, listenedSeconds: 35)
        var rollup = LifetimeListeningRollup()
        try rollup.include(event)
        for seconds in [-1.0, .infinity, .nan, LifetimeListeningRollup.maximumSeconds + 1] {
            var invalid = rollup
            invalid.sessions[event.id.uuidString]?.seconds = seconds
            XCTAssertThrowsError(try invalid.validate())
        }
        var invalid = rollup
        invalid.sessions["not-a-uuid"] = LifetimeListeningContribution(event)
        XCTAssertThrowsError(try invalid.validate())
        let receipt = LifetimeListeningContribution(event)
        var full = LifetimeListeningRollup()
        for _ in 0...LifetimeListeningRollup.maximumSessions { full.sessions[UUID().uuidString] = receipt }
        XCTAssertThrowsError(try full.validate())
    }

    func testReceiptsKeepNoTrackMetadataAndHeroExposesNoInventedRankings() throws {
        var rollup = LifetimeListeningRollup()
        try rollup.include(ListeningEvent(id: UUID(), track: libraryTestTrack("private-recording-id"),
                                         startedAt: LibrarySyncTestData.now, listenedSeconds: 120))
        let encoded = String(decoding: try LibrarySyncCodec.encode(rollup), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-recording-id"))
        XCTAssertFalse(encoded.contains("An Artist"))
        let hero = ListeningAnalytics.lifetimeHero(rollup.summary)
        XCTAssertEqual(hero.seconds, 120)
        XCTAssertEqual(hero.plays, 1)
        XCTAssertTrue(hero.topTracks.isEmpty)
        XCTAssertTrue(hero.days.isEmpty)
        XCTAssertEqual(hero.uniqueTracks, 0)
    }

    func testFutureDatedReceiptsAreExcludedUntilTheirDate() throws {
        var rollup = LifetimeListeningRollup()
        let now = LibrarySyncTestData.now
        try rollup.include(ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: now, listenedSeconds: 30))
        try rollup.include(ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: now.addingTimeInterval(100), listenedSeconds: 50))
        XCTAssertEqual(rollup.summary(through: now).seconds, 30)
        XCTAssertEqual(rollup.summary(through: now.addingTimeInterval(100)).seconds, 80)
    }
}

enum LifetimeListeningTestData {
    static func legacyBytes(events: [ListeningEvent], version: Int, journalVersion: Int? = nil) throws -> Data {
        var document = LibraryDocument()
        document.version = version
        document.events = events
        if let journalVersion {
            var state = LibrarySyncState()
            state.version = journalVersion
            for (index, event) in events.enumerated() {
                let revision = LibrarySyncTestData.revision(Int64(index))
                state.clock = revision
                state.put(LibrarySyncKey(.event, event.id.uuidString),
                          value: try LibrarySyncProjection.listeningValue(event), revision: revision)
            }
            document.syncState = state
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
        object.removeValue(forKey: "lifetimeListening")
        object.removeValue(forKey: "superLikedIDs")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
