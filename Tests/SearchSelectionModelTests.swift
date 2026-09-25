import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class SearchSelectionModelTests: XCTestCase {
    func testEveryResultTypeRecordsItsDestinationMetadataRatherThanTheQuery() throws {
        let context = try makeContext()
        context.model.searchQuery = "Words that are not a destination title"
        let song = AppModelFixtures.track("selected-song")
        context.model.activateSearchSelection(.track(song), source: .result)
        XCTAssertEqual(context.player.queue, [song])
        var expected: [SearchSelection] = [.track(song)]
        for kind in [CollectionKind.artist, .album, .playlist, .mix] {
            let collection = MusicCollection(id: "selected-\(kind.rawValue)", title: "Selected \(kind.rawValue)",
                                             subtitle: "Provider metadata", kind: kind, tracks: [song])
            context.model.activateSearchSelection(.collection(collection), source: .result)
            var destination = collection
            destination.tracks = []
            expected.insert(.collection(destination), at: 0)
            XCTAssertEqual(context.model.navigationPaths[.search]?.last, destination)
            XCTAssertEqual(collection.tracks, [song], "Saving a destination must not mutate the caller's collection")
        }
        XCTAssertEqual(context.library.recentSearchSelections, expected)
        XCTAssertEqual(LibraryStore(directory: context.directory).recentSearchSelections, expected)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertEqual(context.model.searchQuery, "Words that are not a destination title")
    }

    func testResultAndMenuSelectionsDeduplicateByCaseSensitiveIDAndKindNotTitle() throws {
        let context = try makeContext()
        let upper = Track(id: "Recording", title: "Same title", isAudioRecording: true)
        let lower = Track(id: "recording", title: "Same title", isAudioRecording: true)
        let album = MusicCollection(id: "Recording", title: "Same title", kind: .album)
        let artist = MusicCollection(id: "Recording", title: "Same title", kind: .artist)
        for selection in [SearchSelection.track(upper), .track(lower), .collection(album), .collection(artist)] {
            context.model.activateSearchSelection(selection, source: .result)
        }
        var updated = upper
        updated.title = "Refreshed provider title"
        updated.albumTitle = "Updated album"
        context.model.activateSearchSelection(.track(updated), source: .resultMenu)
        XCTAssertEqual(context.library.recentSearchSelections.map(\.id), [
            "track:Recording", "collection:artist:Recording", "collection:album:Recording", "track:recording",
        ])
        XCTAssertEqual(context.library.recentSearchSelections.first, .track(updated))
        XCTAssertTrue(context.library.recentSearchSelections.contains(.track(lower)))
        XCTAssertEqual(context.player.currentTrack, updated)
        XCTAssertEqual(LibraryStore(directory: context.directory).recentSearchSelections, context.library.recentSearchSelections)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
    }

    func testRecentCollectionOpensDirectlyWithoutCatalogLookupOrReplacingTheDraft() async throws {
        let context = try makeContext()
        context.model.updatePreferences { $0.saveListeningHistory = false }
        context.model.searchQuery = "Unsubmitted draft"
        context.model.searchFilter = .artists
        let album = MusicCollection(id: "recent-album", title: "Saved album", subtitle: "Saved artist", kind: .album,
                                    tracks: [AppModelFixtures.track("stale-snapshot")])
        let other = SearchSelection.collection(MusicCollection(id: "another", title: "Other result", kind: .playlist))
        XCTAssertTrue(context.library.recordSearchSelection(.collection(album)))
        XCTAssertTrue(context.library.recordSearchSelection(other))
        let restored = LibraryStore(directory: context.directory)
        let selection = try XCTUnwrap(restored.recentSearchSelections.first { $0.id == "collection:album:recent-album" })
        let root = context.model.searchRootGeneration
        context.model.isPlayerPresented = true
        context.model.activateSearchSelection(selection, source: .recent)
        guard case .collection(let destination) = selection else { return XCTFail("Expected the saved album destination") }
        XCTAssertTrue(destination.tracks.isEmpty)
        XCTAssertEqual(context.model.navigationPaths[.search]?.last, destination)
        XCTAssertEqual(context.library.recentSearchSelections, [selection, other])
        XCTAssertEqual(context.model.searchQuery, "Unsubmitted draft")
        XCTAssertEqual(context.model.searchFilter, .artists)
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertEqual(context.model.searchRootGeneration, root)
        XCTAssertFalse(context.model.consumeSearchFocusRequest(context.model.searchFocusRequest))
        let searches = await context.catalog.searches.requests
        let artists = await context.catalog.artists.requests
        let radios = await context.catalog.autoplayRadios.requests
        let streams = await context.streams.streams.requests
        XCTAssertTrue(searches.isEmpty && artists.isEmpty && radios.isEmpty && streams.isEmpty)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertFalse(context.library.preferences.saveListeningHistory)
    }

    func testRecentSongUsesTheSavedRecordingWithoutRepeatingSearch() async throws {
        let context = try makeContext()
        let song = AppModelFixtures.track("recent-recording")
        XCTAssertTrue(context.library.recordSearchSelection(.track(song)))
        let saved = try XCTUnwrap(LibraryStore(directory: context.directory).recentSearchSelections.first)
        context.model.searchQuery = "A different draft"
        context.model.activateSearchSelection(saved, source: .recent)
        let stream = try await context.streams.streams.request(at: 0)
        XCTAssertEqual(stream.input.track, song)
        XCTAssertEqual(context.player.queue, [song])
        XCTAssertEqual(context.model.searchQuery, "A different draft")
        let searches = await context.catalog.searches.requests
        let artists = await context.catalog.artists.requests
        XCTAssertTrue(searches.isEmpty && artists.isEmpty, "Playback resolution does not need a catalog search")
        try await context.streams.streams.complete(stream, with: .failure(MusicServiceError.unavailable("Offline fixture")))
        XCTAssertEqual(context.library.recentSearchSelections, [saved])
    }

    func testReselectionPreservesLoadedPagesAndNextContinuation() async throws {
        let context = try makeContext()
        let first = AppModelFixtures.track("first-page")
        let second = AppModelFixtures.track("second-page")
        let third = AppModelFixtures.track("third-page")
        let artist = MusicCollection(id: "UCfeatured", title: "Featured artist", kind: .artist)
        let saved = SearchSelection.collection(MusicCollection(id: "saved-album", title: "Saved album", kind: .album))
        XCTAssertTrue(context.library.recordSearchSelection(saved))
        let file = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let bytes = try Data(contentsOf: file)
        await context.seedSearch(CatalogPage(tracks: [first], continuation: "page-2", correctedQuery: "Corrected query",
                                            featuredArtist: artist), query: "  Kept draft  ")
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [first, second], continuation: "page-3")))
        await context.model.loadMoreSearch()
        XCTAssertEqual(context.model.searchPage.tracks, [first, second])
        XCTAssertEqual(context.model.searchPage.continuation, "page-3")

        context.model.selectTab(.search)
        let focus = context.model.searchFocusRequest
        XCTAssertTrue(context.model.consumeSearchFocusRequest(focus))
        XCTAssertFalse(context.model.consumeSearchFocusRequest(focus))
        XCTAssertEqual(context.model.searchQuery, "  Kept draft  ")
        XCTAssertEqual(context.model.searchFilter, .songs)
        XCTAssertEqual(context.model.searchPage.tracks, [first, second])
        XCTAssertEqual(context.model.searchPage.continuation, "page-3")
        XCTAssertEqual(context.model.searchPage.correctedQuery, "Corrected query")
        XCTAssertEqual(context.model.searchPage.featuredArtist, artist)
        XCTAssertTrue(context.model.hasSearched)
        XCTAssertTrue(context.model.hasExecutedCurrentSearch)
        XCTAssertFalse(context.model.isSearching)
        XCTAssertNil(context.model.searchError)

        // UI fixtures have no continuation; this provider verifies the retained cursor and exact request sequence.
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [second, third])))
        await context.model.loadMoreSearch()
        XCTAssertEqual(context.model.searchPage.tracks, [first, second, third])
        XCTAssertNil(context.model.searchPage.continuation)
        let requests = await context.catalog.searches.requests
        XCTAssertEqual(requests.map(\.input), [
            AppModelSearchRequest(query: "Kept draft", filter: .songs, continuation: nil),
            AppModelSearchRequest(query: "Kept draft", filter: .songs, continuation: "page-2"),
            AppModelSearchRequest(query: "Kept draft", filter: .songs, continuation: "page-3")
        ])
        XCTAssertEqual(context.library.recentSearchSelections, [saved])
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testFailedHistoryWritesDoNotPretendSelectionRemovalOrClearSucceeded() throws {
        let context = try makeContext()
        let kept = SearchSelection.collection(MusicCollection(id: "kept", title: "Kept album", kind: .album))
        let selected = MusicCollection(id: "unsaved", title: "Opened but unsaved", kind: .playlist)
        XCTAssertTrue(context.library.recordSearchSelection(kept))
        context.library.recordSearch("Legacy query")
        let revision = context.library.searchHistoryResetRevision
        let file = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let bytes = try Data(contentsOf: file)
        try context.withBlockedLibraryFile {
            context.model.activateSearchSelection(.collection(selected), source: .resultMenu)
            XCTAssertEqual(context.model.navigationPaths[.search]?.last, selected, "A history failure must not block explicit navigation")
            XCTAssertEqual(context.model.toast, context.library.errorMessage)
            XCTAssertNotNil(context.library.errorMessage)
            context.model.removeRecentSearchSelection(id: kept.id)
            context.model.clearRecentSearchSelections()
            XCTAssertEqual(context.library.recentSearchSelections, [kept])
            XCTAssertEqual(context.library.recentSearches, ["Legacy query"])
            XCTAssertEqual(context.library.searchHistoryResetRevision, revision)
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        context.model.removeRecentSearchSelection(id: kept.id)
        XCTAssertTrue(context.library.recentSearchSelections.isEmpty)
        XCTAssertEqual(context.library.recentSearches, ["Legacy query"])
        context.model.clearRecentSearchSelections()
        XCTAssertNotEqual(context.library.searchHistoryResetRevision, revision)
        let restored = LibraryStore(directory: context.directory)
        XCTAssertTrue(restored.recentSearchSelections.isEmpty)
        XCTAssertTrue(restored.recentSearches.isEmpty)
        XCTAssertNil(context.library.errorMessage)
    }

    func testGenericPlayerAndHomeActionsCannotRecordMatchingResultsOrRecreateClearedHistory() async throws {
        let context = try makeContext()
        let song = AppModelFixtures.track("matching-result")
        let album = MusicCollection(id: "matching-album", title: "Matching album", kind: .album)
        await context.seedSearch(CatalogPage(tracks: [song], collections: [album]), query: "Exact active query")
        context.model.play(song)
        context.model.open(album)
        XCTAssertTrue(context.library.recentSearchSelections.isEmpty)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        context.model.activateSearchSelection(.collection(album), source: .result)
        XCTAssertEqual(context.library.recentSearchSelections, [.collection(album)])
        context.model.clearRecentSearchSelections()
        let cleared = try XCTUnwrap(context.library.searchHistoryResetRevision)
        context.model.selectTab(.home)
        context.model.play(song)
        context.model.open(album)
        XCTAssertTrue(context.library.recentSearchSelections.isEmpty)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertEqual(context.library.searchHistoryResetRevision, cleared)
        let restored = LibraryStore(directory: context.directory)
        XCTAssertTrue(restored.recentSearchSelections.isEmpty)
        XCTAssertTrue(restored.recentSearches.isEmpty)
    }

    func testResolvedArtistRecordsTheDestinationWhenTheSearchResetIsUnchanged() async throws {
        let context = try makeContext()
        context.model.searchQuery = "Original search words"
        let artist = MusicCollection(id: "UCresolved", title: "Resolved Artist", kind: .artist)
        let task = context.start { await $0.openArtist(ArtistCredit(name: artist.title), searchSource: .resultMenu) }
        let request = try await context.catalog.searches.request(at: 0)
        XCTAssertEqual(request.input, AppModelSearchRequest(query: artist.title, filter: .artists, continuation: nil))
        try await context.catalog.searches.complete(request, with: .success(CatalogPage(collections: [artist])))
        await task.value
        XCTAssertEqual(context.model.navigationPaths[.search]?.last, artist)
        XCTAssertEqual(context.library.recentSearchSelections, [.collection(artist)])
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertEqual(context.model.searchQuery, "Original search words")
        XCTAssertFalse(context.model.isArtistLookupPending)
    }

    func testDelayedArtistCannotRecreateClearedHistoryThroughEitherClearPath() async throws {
        for clearThroughModel in [false, true] {
            let context = try makeContext()
            context.library.recordSearch("Legacy query")
            let artist = MusicCollection(id: "UCdelayed", title: "Delayed Artist", kind: .artist)
            let before = context.library.searchHistoryResetRevision
            let task = context.start { await $0.openArtist(ArtistCredit(name: artist.title), searchSource: .result) }
            let request = try await context.catalog.searches.request(at: 0)
            if clearThroughModel { context.model.clearRecentSearchSelections() }
            else { XCTAssertTrue(context.library.clearRecentSearches()) }
            XCTAssertNotEqual(context.library.searchHistoryResetRevision, before)
            try await context.catalog.searches.complete(request, with: .success(CatalogPage(collections: [artist])))
            await task.value
            XCTAssertTrue(context.library.recentSearchSelections.isEmpty)
            XCTAssertTrue(context.library.recentSearches.isEmpty)
            XCTAssertFalse(context.model.isArtistLookupPending)
            if clearThroughModel { XCTAssertTrue(context.model.navigationPaths[.search, default: []].isEmpty) }
            else { XCTAssertEqual(context.model.navigationPaths[.search]?.last, artist, "A direct store clear suppresses recording, not the existing navigation intent") }
            XCTAssertTrue(LibraryStore(directory: context.directory).recentSearchSelections.isEmpty)
        }
    }

    func testNewSelectionRetiresDelayedArtistSuccessAndFailure() async throws {
        for fails in [false, true] {
            let context = try makeContext()
            context.model.searchQuery = "Keep this draft"
            let artist = MusicCollection(id: "UCold", title: "Old Artist", kind: .artist)
            let album = MusicCollection(id: "latest", title: "Latest album", kind: .album)
            XCTAssertTrue(context.library.recordSearchSelection(.collection(album)))
            let task = context.start { await $0.openArtist(ArtistCredit(name: artist.title), searchSource: .resultMenu) }
            let request = try await context.catalog.searches.request(at: 0)
            context.model.activateSearchSelection(.collection(album), source: .recent)
            let result: Result<CatalogPage, any Error> = fails ? .failure(MusicServiceError.network("Obsolete failure"))
                : .success(CatalogPage(collections: [artist]))
            try await context.catalog.searches.complete(request, with: result)
            await task.value
            XCTAssertEqual(context.model.navigationPaths[.search], [album])
            XCTAssertEqual(context.model.searchQuery, "Keep this draft")
            XCTAssertEqual(context.library.recentSearchSelections, [.collection(album)])
            XCTAssertTrue(context.library.recentSearches.isEmpty)
            XCTAssertFalse(context.model.isArtistLookupPending)
        }
    }

    private func makeContext() throws -> AppModelTestContext {
        let context = try AppModelTestContext()
        context.model.selectTab(.search)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
