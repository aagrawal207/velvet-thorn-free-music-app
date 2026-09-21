import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelFollowTests: XCTestCase {
    func testSuccessfulFollowEstablishesAnEmptyBaselineSoTheFirstReleaseIsNew() async throws {
        let context = try makeContext()
        let artist = MusicCollection(id: "UC-new-artist", title: "New artist", kind: .artist)
        await context.catalog.artists.enqueue(.success(ArtistPage(id: artist.id, name: artist.title)))
        await context.model.toggleFollow(artist)
        let followed = try XCTUnwrap(context.library.followedArtists.first)
        XCTAssertTrue(followed.hasEstablishedReleaseBaseline)
        XCTAssertTrue(followed.knownReleaseIDs.isEmpty)
        XCTAssertNotNil(followed.lastCheckedAt)
        XCTAssertEqual(LibraryStore(directory: context.directory).followedArtists.first?.hasEstablishedReleaseBaseline, true)

        let release = currentRelease("first-release")
        await context.catalog.artists.enqueue(.success(ArtistPage(id: artist.id, name: artist.title, releases: [release])))
        let count = await context.model.checkForNewReleases(force: true)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(context.library.releases.map(\.id), [release.id])
    }

    func testFailedFollowLookupLeavesTheBaselineUnestablishedUntilASuccessfulRead() async throws {
        let context = try makeContext()
        let artist = MusicCollection(id: "UC-unavailable-artist", title: "Unavailable artist", kind: .artist)
        await context.catalog.artists.enqueue(.failure(MusicServiceError.unavailable("Artist unavailable")))
        await context.model.toggleFollow(artist)
        let followed = try XCTUnwrap(context.library.followedArtists.first)
        XCTAssertFalse(followed.hasEstablishedReleaseBaseline)
        XCTAssertTrue(followed.knownReleaseIDs.isEmpty)
        XCTAssertNil(followed.lastCheckedAt)
        XCTAssertEqual(LibraryStore(directory: context.directory).followedArtists.first?.hasEstablishedReleaseBaseline, false)

        let release = currentRelease("existing-release")
        await context.catalog.artists.enqueue(.success(ArtistPage(id: artist.id, name: artist.title, releases: [release])))
        let count = await context.model.checkForNewReleases(force: true)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(context.library.releases.isEmpty)
        XCTAssertEqual(context.library.followedArtists.first?.knownReleaseIDs, [release.id])
        XCTAssertEqual(context.library.followedArtists.first?.hasEstablishedReleaseBaseline, true)
    }

    private func currentRelease(_ id: String) -> MusicCollection {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return MusicCollection(id: id, title: "First single", subtitle: "Single · \(year)", kind: .album)
    }

    private func makeContext() throws -> AppModelTestContext {
        let context = try AppModelTestContext()
        context.model.updatePreferences { $0.newReleaseAlerts = false }
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
