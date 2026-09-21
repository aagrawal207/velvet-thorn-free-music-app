import XCTest
@testable import GanaBajana

@MainActor
final class LibraryReleasePersistenceTests: XCTestCase {
    func testLegacyBaselinesUseKnownIDsRatherThanFailedAttemptTimestamps() throws {
        let time = RecommendationFixtures.now
        let cases: [(known: [String], checkedAt: Date?, established: Bool)] = [
            ([], nil, false), ([], time, false), (["old"], nil, true), (["old"], time, true),
        ]
        for explicitNull in [false, true] {
            for example in cases {
                try withLibraryTestDirectory { directory in
                    var document = LibraryDocument()
                    let song = libraryTestTrack()
                    document.favorites = [song]
                    document.followedArtists = [FollowedArtist(id: "artist", name: "Artist", followedAt: time,
                                                               knownReleaseIDs: example.known, lastCheckedAt: example.checkedAt)]
                    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                    var artists = try XCTUnwrap(json["followedArtists"] as? [[String: Any]])
                    if explicitNull { artists[0]["hasEstablishedReleaseBaseline"] = NSNull() }
                    else { artists[0].removeValue(forKey: "hasEstablishedReleaseBaseline") }
                    json["followedArtists"] = artists
                    let bytes = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                    let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                    try LibraryPersistence.write(bytes, to: url, replacing: nil)

                    let library = LibraryStore(directory: directory, now: { time })
                    XCTAssertNil(library.errorMessage)
                    let artist = try XCTUnwrap(library.followedArtists.first)
                    XCTAssertEqual(artist.hasEstablishedReleaseBaseline, example.established)
                    XCTAssertEqual(artist.knownReleaseIDs, example.known)
                    XCTAssertEqual(artist.lastCheckedAt, example.checkedAt)
                    XCTAssertEqual(try Data(contentsOf: url), bytes, "A migration must not rewrite a library just to open it")

                    library.preferences.appearance = .light
                    let restored = LibraryStore(directory: directory, now: { time })
                    XCTAssertNil(restored.errorMessage)
                    XCTAssertEqual(restored.followedArtists.first, artist)
                    XCTAssertEqual(restored.favorites, [song])
                    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                    let savedArtists = try XCTUnwrap(saved["followedArtists"] as? [[String: Any]])
                    XCTAssertEqual(savedArtists.first?["hasEstablishedReleaseBaseline"] as? Bool, example.established)
                }
            }
        }
    }

    func testExplicitBaselineMarkerRoundTripsAndNewFollowsDefaultToUnknown() throws {
        let time = RecommendationFixtures.now
        XCTAssertFalse(FollowedArtist(id: "new", name: "New artist").hasEstablishedReleaseBaseline)
        for established in [false, true] {
            for known in [[], ["old"]] as [[String]] {
                var document = LibraryDocument()
                let artist = FollowedArtist(id: "artist", name: "Artist", followedAt: time,
                                            knownReleaseIDs: known, lastCheckedAt: time,
                                            hasEstablishedReleaseBaseline: established)
                document.followedArtists = [artist]
                let restored = try LibraryPersistence.decode(LibraryPersistence.encode(document), now: time)
                XCTAssertEqual(restored.followedArtists, [artist])
            }
        }
    }

    func testMalformedBaselineMarkerBlocksWritesAndPreservesTheWholeLibrary() throws {
        let time = RecommendationFixtures.now
        let malformed: [Any] = ["true", 1, [], ["established": true]]
        for value in malformed {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                document.favorites = [libraryTestTrack()]
                document.followedArtists = [FollowedArtist(id: "artist", name: "Artist", followedAt: time)]
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                var artists = try XCTUnwrap(json["followedArtists"] as? [[String: Any]])
                artists[0]["hasEstablishedReleaseBaseline"] = value
                json["followedArtists"] = artists
                let bytes = try JSONSerialization.data(withJSONObject: json)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: url, replacing: nil)

                let library = LibraryStore(directory: directory, now: { time })
                let error = try XCTUnwrap(library.errorMessage)
                XCTAssertTrue(library.followedArtists.isEmpty)
                library.preferences.newReleaseAlerts = false
                XCTAssertFalse(library.recordTip(transactionID: 1, credited: true))
                XCTAssertFalse(library.recordReleaseCheck(artistID: "artist", knownReleaseIDs: ["new"],
                                                          newReleases: [], checkedAt: time))
                XCTAssertEqual(library.errorMessage, error)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }

    func testReleaseCheckAcknowledgesOnlyPersistedBaselineAndKeepsItThroughFailures() throws {
        try withLibraryTestDirectory { directory in
            let time = RecommendationFixtures.now
            let library = LibraryStore(directory: directory, now: { time })
            library.follow(FollowedArtist(id: "artist", name: "Artist", followedAt: time))
            XCTAssertEqual(library.followedArtists.first?.hasEstablishedReleaseBaseline, false)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let backup = directory.appendingPathComponent("saved-library.json")
            try FileManager.default.moveItem(at: url, to: backup)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

            XCTAssertFalse(library.recordReleaseCheck(artistID: "artist", knownReleaseIDs: [],
                                                      newReleases: [], checkedAt: time))
            XCTAssertNotNil(library.errorMessage)
            XCTAssertEqual(library.followedArtists.first?.hasEstablishedReleaseBaseline, false)
            XCTAssertNil(library.followedArtists.first?.lastCheckedAt)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: backup, to: url)

            XCTAssertTrue(library.recordReleaseCheck(artistID: "artist", knownReleaseIDs: [],
                                                     newReleases: [], checkedAt: time))
            XCTAssertNil(library.errorMessage)
            let restored = LibraryStore(directory: directory, now: { time })
            XCTAssertEqual(restored.followedArtists.first?.hasEstablishedReleaseBaseline, true)
            XCTAssertEqual(restored.followedArtists.first?.knownReleaseIDs, [])
            XCTAssertEqual(restored.followedArtists.first?.lastCheckedAt, time)
            let failedAt = time.addingTimeInterval(60)
            XCTAssertTrue(restored.recordReleaseCheck(artistID: "artist", knownReleaseIDs: [], newReleases: [],
                                                      checkedAt: failedAt, catalogReadSucceeded: false))
            let afterFailure = LibraryStore(directory: directory, now: { failedAt })
            XCTAssertEqual(afterFailure.followedArtists.first?.hasEstablishedReleaseBaseline, true)
            XCTAssertEqual(afterFailure.followedArtists.first?.knownReleaseIDs, [])
            XCTAssertEqual(afterFailure.followedArtists.first?.lastCheckedAt, failedAt)
            XCTAssertFalse(afterFailure.recordReleaseCheck(artistID: "unfollowed", knownReleaseIDs: [],
                                                           newReleases: [], checkedAt: failedAt))
        }
    }
}
