import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class WidgetSnapshotTests: XCTestCase {
    func testProjectionPreservesSavedOrderDeduplicatesAndBoundsEveryListWithFullCollectionCounts() throws {
        let recent = ["r3", "r1", "r3", "r8", "r2", "r7", "r6", "r5"].map { libraryTestTrack($0) }
        let liked = ["l8", "l3", "l2", "l1", "l5", "l0", "l9", "l4"].map { libraryTestTrack($0) }
        let weekly = GeneratedPlaylist(kind: .discoverWeekly, tracks: (0..<11).map { libraryTestTrack("w\($0)") },
                                       generatedAt: RecommendationFixtures.now, periodKey: "week", seedArtists: ["Private seed"])
        let daily = GeneratedPlaylist(kind: .dailyMix, tracks: (0..<9).map { libraryTestTrack("d\($0)") },
                                      generatedAt: RecommendationFixtures.now, periodKey: "day", seedArtists: [])
        var duplicate = daily
        duplicate.tracks = [libraryTestTrack("wrong-period")]
        duplicate.periodKey = "other-day"

        let snapshot = WidgetLibrarySnapshot.projection(recentlyPlayed: recent, likedSongs: liked,
                                                        mixes: [weekly, daily, duplicate])

        XCTAssertEqual(snapshot.recentlyPlayed.map(\.id), ["r3", "r1", "r8", "r2", "r7", "r6"])
        XCTAssertEqual(snapshot.likedSongs.map(\.id), ["l8", "l3", "l2", "l1", "l5", "l0"])
        XCTAssertEqual(snapshot.likedSongCount, 8)
        XCTAssertEqual(snapshot.mixes.map(\.kind), [.discoverWeekly, .dailyMix])
        XCTAssertEqual(snapshot.mixes[0].tracks.map(\.id), ["w0", "w1", "w2", "w3", "w4", "w5"])
        XCTAssertEqual(snapshot.mixes[1].tracks.map(\.id), ["d0", "d1", "d2", "d3", "d4", "d5"])
        XCTAssertEqual(snapshot.mixSongCounts, ["discoverWeekly": 11, "dailyMix": 9])
        XCTAssertTrue(snapshot.mixes.allSatisfy { $0.seedArtists.isEmpty })
        XCTAssertNoThrow(try snapshot.validate())
    }

    func testProjectionBoundsUnicodeMetadataAndCreditsWithoutTruncatingRecordingIdentifiers() throws {
        var detailed = libraryTestTrack("曲 / ?#%")
        detailed.title = String(repeating: "🎵 संगीत ", count: 300)
        detailed.credits = (0..<30).map { ArtistCredit(name: "\($0) " + String(repeating: "歌手", count: 300), id: "private-artist-\($0)") }
        let invalid = [String(repeating: "x", count: 257), " leading", "trailing ", "bad\nID", ""]
            .map { libraryTestTrack($0) }

        let snapshot = WidgetLibrarySnapshot.projection(recentlyPlayed: invalid + [detailed], likedSongs: [], mixes: [])

        let track = try XCTUnwrap(snapshot.recentlyPlayed.first)
        XCTAssertEqual(snapshot.recentlyPlayed.count, 1)
        XCTAssertEqual(track.id, "曲 / ?#%")
        XCTAssertLessThanOrEqual(track.title.utf8.count, 384)
        XCTAssertFalse(track.title.contains("�"))
        XCTAssertEqual(track.credits.count, 4)
        XCTAssertTrue(track.credits.allSatisfy { $0.name.utf8.count <= 192 && $0.id == nil })
        XCTAssertNoThrow(try snapshot.validate())
    }

    func testProjectionStripsURLsArtistIdentifiersAndNonessentialMetadata() throws {
        let track = Track(id: "song", title: "Song", credits: [ArtistCredit(name: "Artist", id: "private-artist")],
                          albumTitle: "Private album", albumID: "private-album", duration: 315,
                          artworkURL: URL(string: "https://private.invalid/cover?token=secret"), language: .hindi,
                          isExplicit: true, isAudioRecording: true, playCount: 987)
        let mix = GeneratedPlaylist(kind: .dailyMix, tracks: [track], generatedAt: RecommendationFixtures.now,
                                    periodKey: "saved-day", seedArtists: ["Private seed"])
        let snapshot = WidgetLibrarySnapshot.projection(recentlyPlayed: [track], likedSongs: [track], mixes: [mix])
        let projected = try XCTUnwrap(snapshot.displayedTracks.first)

        XCTAssertEqual(projected.credits, [ArtistCredit(name: "Artist")])
        XCTAssertNil(projected.artworkURL)
        XCTAssertNil(projected.albumTitle)
        XCTAssertNil(projected.albumID)
        XCTAssertNil(projected.duration)
        XCTAssertNil(projected.language)
        XCTAssertNil(projected.isAudioRecording)
        XCTAssertNil(projected.playCount)
        XCTAssertTrue(projected.isExplicit)
        XCTAssertEqual(snapshot.displayedTracks.count, 1)
        let encoded = String(decoding: try WidgetSnapshotStore.encode(snapshot), as: UTF8.self)
        for privateValue in ["private", "secret", "Private album", "Private seed", "https"] {
            XCTAssertFalse(encoded.contains(privateValue), privateValue)
        }
    }

    func testHistoryOffHidesRecentsAndRetainsExplicitLikesAndSavedMixes() throws {
        let mix = GeneratedPlaylist(kind: .dailyMix, tracks: [libraryTestTrack("mixed")],
                                    generatedAt: RecommendationFixtures.now, periodKey: "day", seedArtists: [])
        let snapshot = WidgetLibrarySnapshot.projection(recentlyPlayed: [libraryTestTrack("private-recent")],
                                                        likedSongs: [libraryTestTrack("liked")], mixes: [mix], historyEnabled: false)
        XCTAssertFalse(snapshot.historyEnabled)
        XCTAssertTrue(snapshot.recentlyPlayed.isEmpty)
        XCTAssertEqual(snapshot.likedSongs.map(\.id), ["liked"])
        XCTAssertEqual(snapshot.mixes.first?.tracks.map(\.id), ["mixed"])
        XCTAssertFalse(snapshot.displayedTracks.contains { $0.id == "private-recent" })
        XCTAssertNoThrow(try snapshot.validate())
    }

    func testArtworkRetainsOnlyDisplayedIDsWithinTheTotalBudgetInDisplayOrder() throws {
        let mixes = [GeneratedPlaylistKind.dailyMix, .discoverWeekly].enumerated().map { index, kind in
            GeneratedPlaylist(kind: kind, tracks: (0..<6).map { libraryTestTrack("m\(index)-\($0)") },
                              generatedAt: RecommendationFixtures.now, periodKey: "period", seedArtists: [])
        }
        let snapshot = WidgetLibrarySnapshot.projection(recentlyPlayed: (0..<6).map { libraryTestTrack("r\($0)") },
                                                        likedSongs: (0..<6).map { libraryTestTrack("l\($0)") }, mixes: mixes)
        let image = WidgetSnapshotTestData.jpeg(paddedTo: 24 * 1024)
        var candidates = Dictionary(uniqueKeysWithValues: snapshot.displayedTracks.map { ($0.id, image) })
        candidates["private-undisplayed"] = image

        let populated = snapshot.withArtwork(candidates)

        XCTAssertEqual(populated.artwork.count, 21)
        XCTAssertEqual(Set(populated.artwork.keys), Set(snapshot.displayedTracks.prefix(21).map(\.id)))
        XCTAssertLessThanOrEqual(populated.artwork.values.reduce(0) { $0 + $1.count }, 512 * 1024)
        XCTAssertLessThanOrEqual(try WidgetSnapshotStore.encode(populated).count, 1024 * 1024)
        XCTAssertNoThrow(try populated.validate())
    }

    func testMalformedOversizedAndOverPixelArtworkCannotReachTheProjection() throws {
        var snapshot = WidgetSnapshotTestData.snapshot()
        let valid = WidgetSnapshotTestData.jpeg()
        let invalid = [Data(), Data("not a JPEG".utf8), Data(valid.dropLast()), valid + Data([0]),
                       WidgetSnapshotTestData.jpeg(width: 241), Data(count: 24 * 1024 + 1)]
        XCTAssertTrue(WidgetLibrarySnapshot.isValidArtwork(valid))
        for data in invalid {
            XCTAssertFalse(WidgetLibrarySnapshot.isValidArtwork(data))
            XCTAssertTrue(snapshot.withArtwork(["song-a": data]).artwork.isEmpty)
            snapshot.artwork = ["song-a": data]
            XCTAssertThrowsError(try snapshot.validate())
        }
    }

    func testHiddenContentDuplicateRowsExtraCountsAndUnboundedMetadataFailValidation() throws {
        let baseline = WidgetSnapshotTestData.snapshot()
        let image = WidgetSnapshotTestData.jpeg()
        let mutations: [(inout WidgetLibrarySnapshot) -> Void] = [
            { $0.version = 2 },
            { $0.historyEnabled = false },
            { $0.availability = .unavailable },
            { $0.availability = .needsApp },
            { $0.recentlyPlayed.append($0.recentlyPlayed[0]) },
            { $0.recentlyPlayed = Array(repeating: $0.recentlyPlayed[0], count: 7) },
            { $0.likedSongCount = -1 },
            { $0.mixSongCounts["not-displayed"] = 10 },
            { $0.artwork["not-displayed"] = image },
            { $0.recentlyPlayed[0].credits[0].id = "private-artist" },
            { $0.recentlyPlayed[0].credits = Array(repeating: ArtistCredit(name: "Artist"), count: 5) },
            { $0.recentlyPlayed[0].title = String(repeating: "a", count: 385) },
            { $0.recentlyPlayed[0].id = String(repeating: "a", count: 257) },
            { $0.recentlyPlayed[0].duration = 90 },
            { $0.recentlyPlayed[0].artworkURL = URL(string: "https://example.invalid/private") },
        ]
        for mutate in mutations {
            var invalid = baseline
            mutate(&invalid)
            XCTAssertThrowsError(try invalid.validate())
        }
    }

    func testDefaultInitializerDerivesCountsAndEmptyStateContainsNoPrivateContent() throws {
        let track = Track(id: "song", title: "Song")
        let mix = GeneratedPlaylist(kind: .dailyMix, tracks: [track], generatedAt: RecommendationFixtures.now,
                                    periodKey: "day", seedArtists: [])
        let snapshot = WidgetLibrarySnapshot(likedSongs: [track], mixes: [mix])
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(snapshot.likedSongCount, 1)
        XCTAssertEqual(snapshot.mixSongCounts, ["dailyMix": 1])
        XCTAssertEqual(snapshot.accent, .coral)
        XCTAssertNoThrow(try snapshot.validate())
        XCTAssertEqual(WidgetLibrarySnapshot.empty.availability, .needsApp)
        XCTAssertTrue(WidgetLibrarySnapshot.empty.displayedTracks.isEmpty)
        XCTAssertTrue(WidgetLibrarySnapshot.empty.artwork.isEmpty)
        XCTAssertNoThrow(try WidgetLibrarySnapshot.empty.validate())
    }
}

enum WidgetSnapshotTestData {
    static func snapshot(_ id: String = "song-a") -> WidgetLibrarySnapshot {
        WidgetLibrarySnapshot.projection(recentlyPlayed: [libraryTestTrack(id)], likedSongs: [libraryTestTrack(id)],
                                         mixes: [], updatedAt: RecommendationFixtures.now)
    }

    static func artworkTrack(_ id: String) -> Track {
        var track = libraryTestTrack(id)
        track.artworkURL = URL(string: "https://widget-artwork.invalid/\(id).png")
        return track
    }

    @MainActor
    static func jpeg(width: Int = 64, height: Int = 64, paddedTo: Int = 0) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let image = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.7) { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard paddedTo >= image.count + 4 else { return image }
        let length = paddedTo - image.count - 2
        var padded = Data([0xFF, 0xD8, 0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 255)])
        padded.append(Data(count: length - 2))
        padded.append(image.dropFirst(2))
        return padded
    }
}
