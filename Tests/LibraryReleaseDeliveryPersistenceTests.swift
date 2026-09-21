import XCTest
@testable import GanaBajana

@MainActor
final class LibraryReleaseDeliveryPersistenceTests: XCTestCase {
    private let time = RecommendationFixtures.now

    private func release(_ id: String, artist: String = "artist") -> ArtistRelease {
        ArtistRelease(id: id, title: "Release \(id)", subtitle: "Single • 2026",
                      artistID: artist, artistName: "Artist \(artist)", discoveredAt: time)
    }

    func testLegacyReleaseRecordsDoNotBecomeRetroactiveNotifications() throws {
        for explicitNull in [false, true] {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                let old = release("old")
                document.followedArtists = [FollowedArtist(id: "artist", name: "Artist", followedAt: time,
                                                           knownReleaseIDs: [old.id], hasEstablishedReleaseBaseline: true)]
                document.releases = [old]
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                if explicitNull { json["pendingReleaseNotificationIDs"] = NSNull() }
                else { json.removeValue(forKey: "pendingReleaseNotificationIDs") }
                let bytes = try JSONSerialization.data(withJSONObject: json)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: url, replacing: nil)
                let library = LibraryStore(directory: directory)
                XCTAssertNil(library.errorMessage)
                XCTAssertEqual(library.releases, [old])
                XCTAssertTrue(library.pendingReleaseNotifications.isEmpty)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                XCTAssertTrue(library.recordReleaseCheck(artistID: "artist", knownReleaseIDs: [old.id],
                                                         newReleases: [old], checkedAt: time))
                XCTAssertTrue(LibraryStore(directory: directory).pendingReleaseNotifications.isEmpty)
            }
        }
    }

    func testPendingDeliveryIsBoundedDeduplicatedAndSeparateFromSeenStateAndBaseline() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.follow(FollowedArtist(id: "artist", name: "Artist", followedAt: time, knownReleaseIDs: ["old"]))
            let releases = (1...61).map { release("new-\($0)") }
            XCTAssertTrue(library.recordReleaseCheck(artistID: "artist", knownReleaseIDs: releases.map(\.id),
                                                     newReleases: releases, checkedAt: time))
            let expected = Array(releases.prefix(60))
            XCTAssertEqual(library.releases, expected)
            XCTAssertEqual(library.pendingReleaseNotifications, expected)
            XCTAssertTrue(library.recordReleaseCheck(artistID: "artist", knownReleaseIDs: releases.map(\.id),
                                                     newReleases: expected, checkedAt: time))
            library.markReleasesSeen()
            XCTAssertEqual(library.unseenReleaseCount, 0)
            XCTAssertEqual(library.pendingReleaseNotifications.map(\.id), expected.map(\.id))
            XCTAssertTrue(library.acknowledgeReleaseNotification(id: "new-1"))
            XCTAssertTrue(library.acknowledgeReleaseNotification(id: "new-1"))
            let reopened = LibraryStore(directory: directory)
            XCTAssertEqual(reopened.releases.count, 60)
            XCTAssertEqual(reopened.pendingReleaseNotifications.map(\.id), Array(expected.dropFirst()).map(\.id))
            XCTAssertTrue(reopened.followedArtists.first?.knownReleaseIDs.contains("new-1") == true)
            XCTAssertTrue(reopened.followedArtists.first?.knownReleaseIDs.contains("new-61") == true)
        }
    }

    func testDisableAndUnfollowDurablyRetireOnlyTheIntendedPendingDeliveries() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            for artist in ["a", "b"] {
                library.follow(FollowedArtist(id: artist, name: "Artist \(artist)", followedAt: time, knownReleaseIDs: ["old-\(artist)"]))
                XCTAssertTrue(library.recordReleaseCheck(artistID: artist, knownReleaseIDs: ["new-\(artist)"],
                                                         newReleases: [release("new-\(artist)", artist: artist)], checkedAt: time))
            }
            library.unfollow(artistID: "a")
            let reopened = LibraryStore(directory: directory)
            XCTAssertEqual(reopened.pendingReleaseNotifications.map(\.id), ["new-b"])
            XCTAssertEqual(reopened.releases.map(\.id), ["new-b"])
            reopened.preferences.newReleaseAlerts = false
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try LibraryPersistence.decode(Data(contentsOf: url), now: Date())
            XCTAssertFalse(saved.preferences.newReleaseAlerts)
            XCTAssertTrue(saved.pendingReleaseNotificationIDs.isEmpty)
            reopened.preferences.newReleaseAlerts = true
            XCTAssertTrue(LibraryStore(directory: directory).pendingReleaseNotifications.isEmpty)
        }
    }

    func testAnOversizedUniquePendingQueueIsRejectedRatherThanSilentlyTruncatedOnLoad() throws {
        try withLibraryTestDirectory { directory in
            var document = LibraryDocument()
            document.releases = (1...61).map { release("release-\($0)") }
            document.followedArtists = [FollowedArtist(id: "artist", name: "Artist", followedAt: time,
                                                       knownReleaseIDs: document.releases.map(\.id), hasEstablishedReleaseBaseline: true)]
            document.pendingReleaseNotificationIDs = document.releases.map(\.id)
            let data = try LibraryPersistence.encode(document)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(data, to: url, replacing: nil)
            let library = LibraryStore(directory: directory)
            XCTAssertNotNil(library.errorMessage)
            XCTAssertTrue(library.requiresReload)
            library.preferences.newReleaseAlerts = false
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testMalformedPendingDeliveryStateBlocksLoadingAndRecoveryWithoutOverwriting() throws {
        let invalidValues: [Any] = ["release", ["missing"], [""], ["old", "old"], Array(repeating: "old", count: 61)]
        for invalid in invalidValues {
            try withLibraryTestDirectory { directory in
                let library = LibraryStore(directory: directory)
                library.follow(FollowedArtist(id: "artist", name: "Artist", followedAt: time, knownReleaseIDs: ["baseline"]))
                XCTAssertTrue(library.recordReleaseCheck(artistID: "artist", knownReleaseIDs: ["old"],
                                                         newReleases: [release("old")], checkedAt: time))
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                json["pendingReleaseNotificationIDs"] = invalid
                let bytes = try JSONSerialization.data(withJSONObject: json)
                try bytes.write(to: url, options: .atomic)
                XCTAssertEqual(library.reloadFromDisk(), .failed)
                XCTAssertTrue(library.requiresReload)
                XCTAssertFalse(library.canDeliverReleaseNotification(release("old")))
                let reopened = LibraryStore(directory: directory)
                XCTAssertNotNil(reopened.errorMessage)
                XCTAssertFalse(reopened.recordTip(transactionID: 1, credited: true))
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }
}
