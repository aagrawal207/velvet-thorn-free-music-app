import Foundation
import XCTest
@testable import GanaBajana

/// R19 super likes through the integrated model: the heart wrappers, Don't Recommend, the import path and the taste
/// inputs the model hands to recommendations. Metrics are OSLog only and TipKit is never configured in unit hosts.
@MainActor
final class R19IntegrationTests: XCTestCase {
    private typealias F = R19TestFixture

    func testHeartWrappersPromoteDemoteAndRemoveThroughTheLibraryWithoutConfiguringTips() throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        let library = model.library
        let heartless = F.track("heartless")
        let other = F.track("other")
        XCTAssertFalse(TipSupport.isConfigured, "Unit hosts never configure TipKit, so the like donation must be a no-op")
        XCTAssertEqual(MusicAppModel.LikeSurface.player.rawValue, "player")
        XCTAssertEqual(MusicAppModel.LikeSurface.menu.rawValue, "menu")
        XCTAssertEqual(MusicAppModel.LikeSurface.more.rawValue, "more")
        XCTAssertEqual(MusicAppModel.LikeSurface.library.rawValue, "library")

        model.toggleLike(other, surface: .menu)
        XCTAssertTrue(library.isFavorite(other))
        XCTAssertFalse(library.isSuperLiked(other))
        XCTAssertFalse(TipSupport.isConfigured)

        model.toggleSuperLike(heartless, surface: .player)
        XCTAssertEqual(library.favorites.map(\.id), ["heartless", "other"], "Promoting an unliked song likes it at the top")
        XCTAssertTrue(library.isFavorite(heartless))
        XCTAssertTrue(library.isSuperLiked(heartless))
        XCTAssertEqual(library.superLikes.map(\.id), ["heartless"])

        model.toggleSuperLike(other, surface: .library)
        XCTAssertEqual(library.favorites.map(\.id), ["other", "heartless"], "Promoting a liked song moves it to the top")
        XCTAssertEqual(library.superLikes.map(\.id), ["other", "heartless"])
        XCTAssertEqual(library.superLikedIDs, ["other", "heartless"])

        model.toggleSuperLike(heartless, surface: .more)
        XCTAssertEqual(library.favorites.map(\.id), ["heartless", "other"], "Change to Like is a new reaction too")
        XCTAssertTrue(library.isFavorite(heartless))
        XCTAssertFalse(library.isSuperLiked(heartless))
        XCTAssertEqual(library.superLikes.map(\.id), ["other"])

        model.toggleLike(other, surface: .player)
        XCTAssertFalse(library.isFavorite(other), "The heart tap removes a super liked song from Liked Songs completely")
        XCTAssertFalse(library.isSuperLiked(other))
        XCTAssertEqual(library.favorites.map(\.id), ["heartless"])
        XCTAssertTrue(library.superLikes.isEmpty)
        XCTAssertNil(library.errorMessage)

        let saved = try LibraryPersistence.decode(Data(contentsOf: context.directory.appendingPathComponent(LibraryPersistence.fileName)),
                                                  now: Date())
        XCTAssertEqual(saved.favorites.map(\.id), ["heartless"])
        XCTAssertEqual(saved.superLikedIDs, [])
        XCTAssertEqual(saved.version, LibraryPersistence.currentVersion)
        XCTAssertFalse(TipSupport.isConfigured)
    }

    func testDontRecommendRemovesBothTiersAndAPromotionLiftsItAgain() throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        let library = model.library
        let heartless = F.track("heartless")
        let other = F.track("other")
        model.toggleSuperLike(heartless, surface: .menu)
        model.toggleSuperLike(other, surface: .menu)
        XCTAssertEqual(library.superLikes.map(\.id), ["other", "heartless"])

        model.toggleDislike(heartless)
        XCTAssertTrue(library.isDisliked(heartless))
        XCTAssertFalse(library.isFavorite(heartless))
        XCTAssertFalse(library.isSuperLiked(heartless))
        XCTAssertEqual(library.favorites.map(\.id), ["other"])
        XCTAssertEqual(library.superLikedIDs, ["other"])

        model.toggleSuperLike(heartless, surface: .player)
        XCTAssertFalse(library.isDisliked(heartless), "A super like is the newer, stronger reaction")
        XCTAssertEqual(library.favorites.map(\.id), ["heartless", "other"])
        XCTAssertEqual(library.superLikes.map(\.id), ["heartless", "other"])
        XCTAssertNil(library.errorMessage)
    }

    func testYouTubeImportKeepsAnExistingSuperLikeAndAddsPlainLikesOnly() async throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        let library = model.library
        let heartless = F.track("heartless")
        let local = F.track("local")
        let remote = F.track("remote")
        model.toggleSuperLike(heartless, surface: .player)
        model.toggleLike(local, surface: .menu)
        XCTAssertEqual(library.favorites.map(\.id), ["local", "heartless"])
        XCTAssertTrue(model.account.signIn(cookies: AccountFixtures.signedIn))

        // The account lists the super liked song again, a new song and a repeat; the importer sees plain likes only.
        let client = R19AccountLibraryStub(likes: [heartless, remote, heartless])
        let importer = YouTubeLibraryImporter(
            library: library, account: model.account, client: client,
            ledgerStore: YouTubeImportLedgerStore(url: context.directory.appendingPathComponent("youtube-import.json")),
            now: { F.now }
        )
        XCTAssertTrue(importer.hasSession)
        let commits = library.durableCommitCount

        await importer.run(YouTubeImportSelection(kinds: [.likes]))

        XCTAssertEqual(importer.runStatus, .finished)
        XCTAssertEqual(importer.progress[.likes]?.status, .done)
        XCTAssertEqual(importer.progress[.likes]?.fetched, 3)
        XCTAssertEqual(importer.progress[.likes]?.applied, 1, "Only the unknown song becomes a like")
        XCTAssertEqual(library.favorites.map(\.id), ["remote", "local", "heartless"])
        XCTAssertTrue(library.isSuperLiked(heartless), "An import never downgrades a super like")
        XCTAssertFalse(library.isSuperLiked(remote), "Imports create plain likes")
        XCTAssertFalse(library.isSuperLiked(local))
        XCTAssertEqual(library.superLikes.map(\.id), ["heartless"])
        XCTAssertEqual(library.durableCommitCount, commits + 1)
        XCTAssertEqual(importer.lastImportedAt, F.now)

        await importer.run(YouTubeImportSelection(kinds: [.likes]))
        XCTAssertEqual(importer.progress[.likes]?.applied, 0)
        XCTAssertEqual(library.durableCommitCount, commits + 1, "A repeat import changes nothing")
        XCTAssertEqual(library.favorites.map(\.id), ["remote", "local", "heartless"])
        XCTAssertTrue(library.isSuperLiked(heartless))
        XCTAssertNil(library.errorMessage)

        let saved = try LibraryPersistence.decode(Data(contentsOf: context.directory.appendingPathComponent(LibraryPersistence.fileName)),
                                                  now: Date())
        XCTAssertEqual(saved.superLikedIDs, ["heartless"])
        XCTAssertEqual(saved.favorites.map(\.id), ["remote", "local", "heartless"])
    }

    func testTheLibraryInputsBehindTheModelsTasteProfileCarryTheSuperLike() throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        let library = model.library
        let heartless = F.track("heartless", artist: "Kanye West")
        let other = F.track("other", artist: "Frank Ocean")
        model.toggleSuperLike(heartless, surface: .player)
        model.toggleLike(other, surface: .menu)

        // MusicAppModel.tasteProfile() is private; this mirrors its inputs from the same library.
        let profile = TasteProfile.build(events: library.events, favorites: library.favorites, playlists: library.playlists,
                                         recents: library.recentlyPlayed, disliked: library.disliked,
                                         superLikedIDs: library.superLikedIDs, now: F.now)
        XCTAssertEqual(profile.superLikedTrackIDs, ["heartless"])
        XCTAssertEqual(profile.trackAffinity["heartless"] ?? 0, TasteProfile.superLikeBoost, accuracy: 1e-9)
        XCTAssertEqual(profile.artistAffinity["kanye west"] ?? 0, TasteProfile.superLikeBoost, accuracy: 1e-9)
        XCTAssertEqual(profile.trackAffinity["other"] ?? 0, TasteProfile.favoriteBoost, accuracy: 1e-9)
        XCTAssertEqual(profile.topTracks(limit: 1).map(\.id), ["heartless"])

        model.toggleSuperLike(heartless, surface: .library)
        let demoted = TasteProfile.build(events: library.events, favorites: library.favorites, playlists: library.playlists,
                                         recents: library.recentlyPlayed, disliked: library.disliked,
                                         superLikedIDs: library.superLikedIDs, now: F.now)
        XCTAssertTrue(demoted.superLikedTrackIDs.isEmpty)
        XCTAssertEqual(demoted.trackAffinity["heartless"] ?? 0, TasteProfile.favoriteBoost, accuracy: 1e-9)
    }
}

/// Nonisolated fixtures so the importer's `@Sendable` clock closure can read them.
private enum R19TestFixture {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func track(_ id: String, artist: String = "Fixture artist") -> Track {
        Track(id: id, title: "Song \(id)", artists: [artist], duration: 200, isAudioRecording: true)
    }
}

/// Canned account pages. Only liked songs are requested here; the other listings answer empty without a request error.
private struct R19AccountLibraryStub: YouTubeAccountLibraryProviding {
    let likes: [Track]

    func likedSongs(continuation: String?) async throws -> YouTubeLibraryPage<Track> { YouTubeLibraryPage(items: likes) }
    func playlists(continuation: String?) async throws -> YouTubeLibraryPage<MusicCollection> { YouTubeLibraryPage(items: []) }
    func playlistTracks(id: String, continuation: String?) async throws -> YouTubeLibraryPage<Track> { YouTubeLibraryPage(items: []) }
    func subscribedArtists(continuation: String?) async throws -> YouTubeLibraryPage<MusicCollection> { YouTubeLibraryPage(items: []) }
    func history(continuation: String?) async throws -> YouTubeLibraryPage<Track> { YouTubeLibraryPage(items: []) }
}
