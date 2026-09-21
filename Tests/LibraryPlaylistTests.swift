import XCTest
@testable import GanaBajana

final class LibraryPlaylistTests: XCTestCase {
    @MainActor
    func testCreateRenameAddRemoveAndDeletePreserveIdentityAndFavorites() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let first = libraryTestTrack()
            let second = libraryTestTrack("song-b")
            store.toggleFavorite(first)
            let id = store.createPlaylist(name: "  मेरा संगीत  ")
            let createdAt = try XCTUnwrap(store.playlists.first?.createdAt)
            store.add(first, to: id)
            store.add(second, to: id)
            store.add(first, to: id)
            XCTAssertEqual(store.playlists.first?.tracks, [first, second])
            store.renamePlaylist(id: id, name: "  Evening songs\n")
            XCTAssertEqual(store.playlists.first?.id, id)
            XCTAssertEqual(store.playlists.first?.createdAt, createdAt)
            XCTAssertEqual(store.playlists.first?.name, "Evening songs")
            store.remove(trackID: first.id, from: id)
            XCTAssertEqual(store.playlists.first?.tracks, [second])
            XCTAssertTrue(store.isFavorite(first))
            store.deletePlaylist(id: id)
            XCTAssertTrue(store.playlists.isEmpty)
            XCTAssertEqual(LibraryStore(directory: directory).favorites, [first])
            XCTAssertTrue(LibraryStore(directory: directory).playlists.isEmpty)
        }
    }

    @MainActor
    func testBlankNamesAndUnknownPlaylistEditsDoNotMutateTheLibrary() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let rejectedID = store.createPlaylist(name: " \n\t ")
            XCTAssertFalse(store.playlists.contains { $0.id == rejectedID })
            XCTAssertNotNil(store.errorMessage)
            let id = store.createPlaylist(name: "Keep this")
            store.renamePlaylist(id: id, name: "  ")
            XCTAssertEqual(store.playlists.first?.name, "Keep this")
            store.add(libraryTestTrack(), to: UUID())
            store.remove(trackID: "song-a", from: UUID())
            store.deletePlaylist(id: UUID())
            XCTAssertEqual(store.playlists.count, 1)
            XCTAssertTrue(store.playlists[0].tracks.isEmpty)
        }
    }

    @MainActor
    func testNoncontiguousReorderingUsesOriginalDestinationOffsetsAndPersists() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let id = store.createPlaylist(name: "In order")
            for name in ["a", "b", "c", "d", "e"] { store.add(libraryTestTrack(name), to: id) }
            store.moveTracks(in: id, from: IndexSet([1, 3]), to: 5)
            XCTAssertEqual(store.playlists[0].tracks.map(\.id), ["a", "c", "e", "b", "d"])
            store.moveTracks(in: id, from: IndexSet([3, 4]), to: 0)
            XCTAssertEqual(store.playlists[0].tracks.map(\.id), ["b", "d", "a", "c", "e"])
            XCTAssertEqual(LibraryStore(directory: directory).playlists[0].tracks.map(\.id), ["b", "d", "a", "c", "e"])
        }
    }

    @MainActor
    func testInvalidAndNoOpMovesLeaveTrackOrderIntact() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let id = store.createPlaylist(name: "Order")
            let tracks = [libraryTestTrack("a"), libraryTestTrack("b"), libraryTestTrack("c")]
            tracks.forEach { store.add($0, to: id) }
            store.moveTracks(in: id, from: IndexSet(integer: 8), to: 0)
            XCTAssertNotNil(store.errorMessage)
            store.moveTracks(in: id, from: IndexSet(integer: 0), to: 9)
            store.moveTracks(in: id, from: IndexSet(integer: 0), to: -1)
            store.moveTracks(in: id, from: IndexSet(), to: 0)
            store.moveTracks(in: id, from: IndexSet(integer: 1), to: 2)
            store.moveTracks(in: id, from: IndexSet([0, 1, 2]), to: 3)
            XCTAssertEqual(store.playlists[0].tracks, tracks)
        }
    }

    @MainActor
    func testFavoriteIdentityUsesSongIDRatherThanChangingMetadata() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let original = libraryTestTrack()
            var updated = original
            updated.title = "A better catalog title"
            store.toggleFavorite(original)
            XCTAssertTrue(store.isFavorite(updated))
            store.toggleFavorite(updated)
            XCTAssertTrue(store.favorites.isEmpty)
            XCTAssertTrue(LibraryStore(directory: directory).favorites.isEmpty)
        }
    }
}
