import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySyncSchemaCompatibilityTests: XCTestCase {
    func testLegacyRandomTombstoneDoesNotBecomeAnInvalidLocalJournalAfterDefaultChange() throws {
        for (libraryVersion, version) in [(1, 1), (2, 1), (3, 2), (4, 3), (LibraryPersistence.currentVersion, LibrarySyncState.currentVersion)] {
            let revision = LibrarySyncTestData.revision(1)
            var journal = LibrarySyncState()
            journal.clock = revision
            journal.put(LibrarySyncKey(.preference, "shuffleStyle"), value: nil, revision: revision)
            journal.version = version
            var document = LibraryDocument()
            document.version = libraryVersion
            document.preferences.shuffleStyle = .random
            document.syncState = journal
            let bytes = try (libraryVersion < LibraryPersistence.currentVersion
                             ? LibrarySyncTestData.legacyDocumentBytes(document) : LibrarySyncCodec.encode(document))
            let decoded = try LibraryPersistence.decode(bytes, now: LibrarySyncTestData.now)
            XCTAssertEqual(decoded.preferences.shuffleStyle, .random)
            XCTAssertEqual(decoded.syncState?.registers, journal.registers)
            XCTAssertEqual(decoded.syncState?.clock, revision)
            try withLibraryTestDirectory { directory in
                let file = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: file, replacing: nil)
                let library = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
                XCTAssertNil(library.errorMessage)
                let unchanged = library.preferences
                library.preferences = unchanged
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            }
            let replica = LibrarySyncReplica(version: version, replicaID: LibrarySyncTestData.a, state: journal)
            let remote = try LibrarySyncCodec.decodeReplica(LibrarySyncCodec.encodeReplica(replica),
                expectedReplicaID: LibrarySyncTestData.a, now: LibrarySyncTestData.now)
            XCTAssertEqual(try LibrarySyncTestData.rendered(remote.state).preferences.shuffleStyle, .random)
            XCTAssertEqual(remote.state.registers, journal.registers)
        }
        XCTAssertEqual(try LibrarySyncCodec.decode(UserPreferences.self, from: Data("{}".utf8)).shuffleStyle, .fewerRepeats)
    }

    func testSavedRandomAndMigrationMarkerRoundTripWithoutInventingAnEdit() throws {
        for marker in [false, true] {
            var preferences = UserPreferences()
            preferences.shuffleStyle = .random
            preferences.shuffleDefaultMigrated = marker
            let fields = try LibrarySyncPreferences.fields(preferences)
            var decoded = try LibrarySyncPreferences.applying(fields, to: UserPreferences())
            XCTAssertFalse(decoded.migrateShuffleDefault())
            XCTAssertEqual(decoded, preferences)
            XCTAssertEqual(try LibrarySyncPreferences.fields(decoded), fields)
            let incoming = try LibrarySyncTestData.single(.preference, "shuffleStyle", value: "random",
                                                         revision: LibrarySyncTestData.revision(1))
            var document = LibraryDocument()
            document.preferences = preferences
            let prepared = try LibraryCloudMergePreparation.make(incoming: incoming, document: document,
                baselineData: nil, generation: UUID(), now: LibrarySyncTestData.now, writer: LibrarySyncTestData.b)
            XCTAssertEqual(prepared.candidate.preferences.shuffleStyle, .random)
            XCTAssertEqual(prepared.candidate.preferences.shuffleDefaultMigrated, marker)
        }
    }

    func testCurrentPreferenceLeavesAndAllDailyMixKindsSurviveReplicaAndLocalRoundTrips() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        var preferences = a.library.preferences
        preferences.shuffleStyle = .random
        preferences.shuffleDefaultMigrated = true
        preferences.genreNudges[.hipHop] = .more
        preferences.genreNudges[.pop] = .less
        preferences.equalizer = EqualizerSettings(isEnabled: true, preset: .custom,
                                                 gains: [-12, -9.5, -4, -0.5, 0, 0.5, 3, 6, 9.5, 12], preamp: -3.5)
        preferences.downloadsOverCellular = true
        preferences.autoDownloadLikedSongs = true
        preferences.sponsorBlockSkipping = true
        preferences.enabledCatalogSources = []
        a.library.preferences = preferences
        XCTAssertNil(a.library.errorMessage)
        for kind in GeneratedPlaylistKind.allCases {
            a.library.saveMix(GeneratedPlaylist(kind: kind, tracks: [libraryTestTrack(kind.rawValue)],
                generatedAt: LibrarySyncTestData.now, periodKey: "2026-09-19", seedArtists: [], focus: "Saved focus"))
        }
        XCTAssertNil(a.library.errorMessage)
        let bytes = try LibrarySyncCodec.encodeReplica(a.library.cloudReplica(replicaID: a.id))
        let incoming = try LibrarySyncCodec.decodeReplica(bytes, expectedReplicaID: a.id, now: LibrarySyncTestData.now)
        try b.library.mergeCloudState(incoming.state)
        XCTAssertEqual(b.library.preferences, preferences)
        XCTAssertEqual(Set(b.library.mixes.map(\.kind)), Set(GeneratedPlaylistKind.allCases))
        XCTAssertEqual(Set(try b.saved().mixes.map(\.kind)), Set(GeneratedPlaylistKind.allCases))
        XCTAssertEqual(try b.saved().syncState?.registers, incoming.state.registers)
    }

    func testUnknownAndLenientlyRewrittenRemotePreferencesStillBlockPublicationAndPreserveBytes() async throws {
        for (field, value, reason) in [
            ("futurePreference", "true", LibrarySyncFailure.newerVersion),
            ("genreNudges/futureFamily", "\"more\"", .newerVersion),
            ("genreNudges/hipHop", "\"unknown\"", .invalidData),
            ("equalizer/preamp", "99", .invalidData),
            ("equalizer/gains", "[1]", .invalidData),
            ("enabledCatalogSources", "[\"futureSource\"]", .invalidData),
            ("shuffleStyle", "null", .invalidData)
        ] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            a.library.toggleFavorite(libraryTestTrack("kept-local"))
            let localBytes = try Data(contentsOf: a.fileURL)
            let revision = LibrarySyncTestData.revision(1)
            var state = LibrarySyncState()
            state.clock = revision
            state.put(LibrarySyncKey(.preference, field), value: Data(value.utf8), revision: revision)
            let bytes = try LibrarySyncCodec.encodeReplica(LibrarySyncReplica(replicaID: LibrarySyncTestData.b, state: state))
            XCTAssertThrowsError(try LibrarySyncCodec.decodeReplica(bytes, expectedReplicaID: LibrarySyncTestData.b,
                                                                   now: LibrarySyncTestData.now)) {
                XCTAssertEqual(LibrarySyncFailure.reason(for: $0), reason, field)
            }
            harness.cloud.accounts["account-a"] = [LibrarySyncTestData.b: bytes]
            await a.sync.syncNow()
            XCTAssertNotNil(a.sync.errorMessage, field)
            XCTAssertEqual(a.transport.publicationAttempts, 0, field)
            XCTAssertEqual(try Data(contentsOf: a.fileURL), localBytes, field)
            XCTAssertEqual(harness.cloud.accounts["account-a"]?[LibrarySyncTestData.b], bytes, field)
        }
    }
}
