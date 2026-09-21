import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class SearchHistoryModelTests: XCTestCase {
    func testFirstSearchTapBrowsesAndAReselectionRequestsKeyboardOnce() throws {
        let context = try makeContext()
        let model = context.model
        let album = MusicCollection(id: "fixture-album", title: "Album", kind: .album)
        model.searchQuery = "my draft"
        model.navigationPaths[.search] = [album]
        model.navigationPaths[.library] = [album]
        model.selectTab(.search)
        let first = model.searchFocusRequest
        XCTAssertEqual(first, 0)
        XCTAssertEqual(model.selectedTab, .search)
        XCTAssertEqual(model.searchQuery, "my draft")
        XCTAssertEqual(model.navigationPaths[.search], [])
        XCTAssertEqual(model.navigationPaths[.library], [album])
        XCTAssertFalse(model.consumeSearchFocusRequest(first))
        model.selectTab(.search)
        XCTAssertGreaterThan(model.searchFocusRequest, first)
        XCTAssertTrue(model.consumeSearchFocusRequest(model.searchFocusRequest))
        model.open(album)
        model.navigationPath(for: .search).wrappedValue = []
        XCTAssertFalse(model.consumeSearchFocusRequest(model.searchFocusRequest), "Returning from a detail must not reopen the keyboard")
    }

    func testLeavingSearchAndProgrammaticSearchConsumeUnansweredFocusRequests() throws {
        let context = try makeContext()
        let model = context.model
        model.selectTab(.search)
        let first = model.searchFocusRequest
        model.selectTab(.home)
        model.selectedTab = .search
        XCTAssertFalse(model.consumeSearchFocusRequest(first))
        model.selectTab(.search)
        let second = model.searchFocusRequest
        model.navigationPaths[.search] = [MusicCollection(id: "detail", title: "Detail")]
        model.searchFilter = .albums
        model.isPlayerPresented = true
        model.openSearch("Shreya Ghoshal")
        XCTAssertEqual(model.searchFocusRequest, second)
        XCTAssertFalse(model.consumeSearchFocusRequest(second))
        XCTAssertEqual(model.searchQuery, "Shreya Ghoshal")
        XCTAssertEqual(model.searchFilter, .songs)
        XCTAssertEqual(model.selectedTab, .search)
        XCTAssertEqual(model.navigationPaths[.search], [])
        XCTAssertFalse(model.isPlayerPresented)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
    }

    func testPresentingAPlayerOrSettingsDoesNotLeaveAFutureKeyboardRequest() throws {
        let context = try makeContext()
        let model = context.model
        model.selectTab(.search)
        model.isPlayerPresented = true
        model.isPlayerPresented = false
        XCTAssertFalse(model.consumeSearchFocusRequest(model.searchFocusRequest))
        model.selectTab(.search)
        model.isSettingsPresented = true
        model.isSettingsPresented = false
        XCTAssertFalse(model.consumeSearchFocusRequest(model.searchFocusRequest))
    }

    func testBackgroundSearchesAndPaginationDoNotSaveTypedFragments() async throws {
        let context = try makeContext()
        for query in ["T", "Tum", "Tum Hi"] {
            await context.seedSearch(CatalogPage(), query: query)
        }
        let song = libraryTestTrack("result")
        await context.seedSearch(CatalogPage(tracks: [song], continuation: "next"), query: "  Tum Hi Ho  ")
        await context.catalog.searches.enqueue(.success(CatalogPage()))
        await context.model.loadMoreSearch()
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        context.model.commitSearch()
        XCTAssertEqual(context.library.recentSearches, ["Tum Hi Ho"])
        XCTAssertEqual(context.model.searchQuery, "  Tum Hi Ho  ")
        XCTAssertEqual(LibraryStore(directory: context.directory).recentSearches, ["Tum Hi Ho"])
    }

    func testPlayingAResultCommitsTheQueryAndDismissesFocusWithoutAnEnterKey() async throws {
        let context = try makeContext()
        let song = libraryTestTrack("chosen-result")
        context.model.selectTab(.search)
        await context.seedSearch(CatalogPage(tracks: [song]), query: "Chosen song")
        let dismissal = context.model.searchFocusDismissal
        context.model.play(song)
        XCTAssertGreaterThan(context.model.searchFocusDismissal, dismissal)
        XCTAssertFalse(context.model.consumeSearchFocusRequest(context.model.searchFocusRequest))
        XCTAssertEqual(context.library.recentSearches, ["Chosen song"])
        XCTAssertEqual(context.player.queue, [song])

        context.model.searchQuery = "unfinished fragment"
        context.model.play(libraryTestTrack("not-a-search-result"))
        XCTAssertEqual(context.library.recentSearches, ["Chosen song"])
        context.model.selectTab(.home)
        context.model.play(song)
        XCTAssertEqual(context.library.recentSearches, ["Chosen song"])
    }

    func testCollectionResultsCommitHistoryAndKeepKeyboardDismissedOnBack() async throws {
        let context = try makeContext()
        let album = MusicCollection(id: "chosen-album", title: "Chosen album", kind: .album)
        context.model.selectTab(.search)
        await context.seedSearch(CatalogPage(collections: [album]), query: "Album query", filter: .albums)
        context.model.open(album)
        XCTAssertEqual(context.library.recentSearches, ["Album query"])
        XCTAssertEqual(context.model.navigationPaths[.search], [album])
        context.model.navigationPath(for: .search).wrappedValue = []
        XCTAssertFalse(context.model.consumeSearchFocusRequest(context.model.searchFocusRequest))
        XCTAssertEqual(context.model.searchQuery, "Album query")
    }

    private func makeContext() throws -> AppModelTestContext {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
