import Foundation
import XCTest
@testable import GanaBajana

/// R20 super-like extras: the Home shelf's source and cap, its hidden-when-empty rule, the Storage count and the
/// row glyph's VoiceOver wording. Rendering and navigation belong to `GanaBajanaR20UITests`.
@MainActor
final class SuperLikeExtrasTests: XCTestCase {
    private func track(_ index: Int) -> Track { libraryTestTrack("super-\(index)", duration: 200) }

    // MARK: - Home shelf

    func testHomeShelfListsTheNewestTwentySuperLikesInLikedSongsOrder() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let promoted = (1...25).map(track)
            for song in promoted { store.setSuperLiked(song, true) }
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.superLikes.count, 25)
            XCTAssertEqual(store.superLikes.first, promoted.last, "A promotion is the newest reaction and leads Liked Songs")

            let shelf = HomeView.superLikedShelf(store.superLikes)
            XCTAssertEqual(HomeView.superLikedShelfLimit, 20)
            XCTAssertEqual(shelf.count, 20)
            XCTAssertEqual(shelf, Array(store.superLikes.prefix(20)), "The shelf is the library order, only capped")
            XCTAssertEqual(shelf.first, promoted[24])
            XCTAssertEqual(shelf.last, promoted[5])
            for early in promoted.prefix(5) {
                XCTAssertFalse(shelf.contains(early), "\(early.id) is older than the twenty newest super likes")
            }

            // A later promotion of an old super like moves it to the front of the shelf, like Liked Songs.
            store.setSuperLiked(promoted[0], false)
            store.setSuperLiked(promoted[0], true)
            XCTAssertEqual(HomeView.superLikedShelf(store.superLikes).first, promoted[0])
        }
    }

    func testHomeShelfIsHiddenWithoutSuperLikesAndFollowsTheModelWrappers() throws {
        XCTAssertTrue(HomeView.superLikedShelf([]).isEmpty, "Home hides a section whose shelf has nothing to show")

        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        let heartless = track(1)
        let starlight = track(2)
        model.toggleLike(heartless, surface: .home)
        XCTAssertTrue(model.library.isFavorite(heartless))
        XCTAssertTrue(HomeView.superLikedShelf(model.library.superLikes).isEmpty, "Plain likes never fill the shelf")

        model.toggleSuperLike(starlight, surface: .home)
        XCTAssertEqual(HomeView.superLikedShelf(model.library.superLikes), [starlight])
        XCTAssertEqual(model.library.favorites.map(\.id), [starlight.id, heartless.id])

        model.toggleSuperLike(starlight, surface: .home)
        XCTAssertTrue(model.library.isFavorite(starlight), "Change to Like keeps the song in Liked Songs")
        XCTAssertTrue(HomeView.superLikedShelf(model.library.superLikes).isEmpty, "Demoting the last super like hides the shelf again")
        XCTAssertEqual(MusicAppModel.LikeSurface.home.rawValue, "home")
    }

    func testTheShelfHonoursCustomizeHomeLikeEveryOtherSection() {
        var layout = HomeLayoutPreferences()
        XCTAssertTrue(layout.visibleSections.contains(.superLiked))
        layout.setVisible(false, for: .superLiked)
        XCTAssertFalse(layout.visibleSections.contains(.superLiked))
        XCTAssertEqual(layout.orderedSections.count, HomeSectionKind.allCases.count, "Hiding keeps the row in Customize Home")
        layout.setVisible(true, for: .superLiked)
        layout.move(from: IndexSet(integer: layout.orderedSections.count - 1), to: 0)
        XCTAssertEqual(layout.visibleSections.first, .superLiked)
    }

    // MARK: - Storage

    func testStorageCountsSuperLikesSeparatelyFromLikes() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            _ = store.addFavorites(DebugR19Fixture.likedTracks)
            store.setSuperLiked(DebugR19Fixture.superLikedTrack, true)
            XCTAssertEqual(store.favorites.count, 6, "The Liked Songs row counts every like, super liked included")
            XCTAssertEqual(store.superLikes.count, 1, "The Super Liked row counts the tier alone")
            XCTAssertEqual(store.superLikes.map(\.id), [DebugR19Fixture.starlight.id])
            XCTAssertFalse(store.isSuperLiked(DebugR19Fixture.heartless), "Heartless is the fixture's plain like")

            store.setSuperLiked(DebugR19Fixture.superLikedTrack, false)
            XCTAssertEqual(store.favorites.count, 6)
            XCTAssertEqual(store.superLikes.count, 0)

            store.setSuperLiked(DebugR19Fixture.heartless, true)
            store.toggleFavorite(DebugR19Fixture.heartless)
            XCTAssertEqual(store.favorites.count, 5, "Unliking a super liked song leaves both counts")
            XCTAssertEqual(store.superLikes.count, 0)
        }
    }

    // MARK: - Row glyph

    func testTrackRowDescribesTheTierBeforeTheLocalCopy() {
        XCTAssertEqual(TrackRow.stateDescription(isSuperLiked: false, isDownloaded: false, isCached: false), "")
        XCTAssertEqual(TrackRow.stateDescription(isSuperLiked: true, isDownloaded: false, isCached: false), ". Super liked")
        XCTAssertEqual(TrackRow.stateDescription(isSuperLiked: false, isDownloaded: true, isCached: false), ". Downloaded")
        XCTAssertEqual(TrackRow.stateDescription(isSuperLiked: false, isDownloaded: false, isCached: true), ". Cached on this device")
        XCTAssertEqual(TrackRow.stateDescription(isSuperLiked: true, isDownloaded: true, isCached: false), ". Super liked. Downloaded")
        XCTAssertEqual(TrackRow.stateDescription(isSuperLiked: true, isDownloaded: false, isCached: true),
                       ". Super liked. Cached on this device")
        XCTAssertEqual(TrackRow.stateDescription(isSuperLiked: true, isDownloaded: true, isCached: true), ". Super liked. Downloaded",
                       "A downloaded copy is the stronger local state; the cached wording never doubles it")

        // The pure value part is unchanged, so the tier joins it the same way the downloaded state always has.
        let row = TrackRow(track: Track(id: "song", title: "Song", artists: ["Artist"], duration: 200), showsDuration: true)
        XCTAssertEqual(row.accessibilityValue, "Duration 3:20")
        XCTAssertEqual(row.accessibilityValue + TrackRow.stateDescription(isSuperLiked: true, isDownloaded: true, isCached: false),
                       "Duration 3:20. Super liked. Downloaded")
    }
}
