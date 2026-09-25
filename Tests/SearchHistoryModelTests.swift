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
        let root = model.searchRootGeneration
        model.selectTab(.search)
        let first = model.searchFocusRequest
        XCTAssertEqual(first, 0)
        XCTAssertEqual(model.selectedTab, .search)
        XCTAssertEqual(model.searchQuery, "my draft")
        XCTAssertEqual(model.navigationPaths[.search], [])
        XCTAssertEqual(model.navigationPaths[.library], [album])
        XCTAssertEqual(model.searchRootGeneration, root)
        XCTAssertFalse(model.consumeSearchFocusRequest(first))
        model.selectTab(.search)
        XCTAssertNotEqual(model.searchRootGeneration, root)
        XCTAssertGreaterThan(model.searchFocusRequest, first)
        XCTAssertTrue(model.consumeSearchFocusRequest(model.searchFocusRequest))
        XCTAssertFalse(model.consumeSearchFocusRequest(model.searchFocusRequest))
        let reselectedRoot = model.searchRootGeneration
        model.open(album)
        model.navigationPath(for: .search).wrappedValue = []
        XCTAssertFalse(model.consumeSearchFocusRequest(model.searchFocusRequest), "Returning from a detail must not reopen the keyboard")
        XCTAssertEqual(model.searchRootGeneration, reselectedRoot)
        XCTAssertTrue(context.library.recentSearchSelections.isEmpty)
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
        XCTAssertTrue(context.library.recentSearchSelections.isEmpty)
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
        let file = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let original = try Data(contentsOf: file)
        for query in ["T", "Tum", "Tum Hi"] {
            context.model.searchQuery = query
            await context.catalog.searches.enqueue(.success(CatalogPage()))
            await context.model.loadSearch()
        }
        let song = libraryTestTrack("result")
        await context.seedSearch(CatalogPage(tracks: [song], continuation: "next"), query: "  Tum Hi Ho  ")
        await context.catalog.searches.enqueue(.success(CatalogPage()))
        await context.model.loadMoreSearch()
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        context.model.commitSearch()
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertTrue(context.library.recentSearchSelections.isEmpty)
        XCTAssertEqual(context.model.searchQuery, "  Tum Hi Ho  ")
        XCTAssertTrue(context.model.hasExecutedCurrentSearch)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testActivatingATrackResultRecordsItsDestinationAndDismissesFocusWithoutEnter() async throws {
        let context = try makeContext()
        let song = AppModelFixtures.track("chosen-result")
        context.model.selectTab(.search)
        await context.seedSearch(CatalogPage(tracks: [song]), query: "Chosen song")
        let dismissal = context.model.searchFocusDismissal
        context.model.activateSearchSelection(.track(song), source: .result)
        XCTAssertGreaterThan(context.model.searchFocusDismissal, dismissal)
        XCTAssertFalse(context.model.consumeSearchFocusRequest(context.model.searchFocusRequest))
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertEqual(context.library.recentSearchSelections, [.track(song)])
        XCTAssertEqual(LibraryStore(directory: context.directory).recentSearchSelections, [.track(song)])
        XCTAssertEqual(context.player.queue, [song])

        context.model.searchQuery = "unfinished fragment"
        context.model.play(libraryTestTrack("not-a-search-result"))
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertEqual(context.library.recentSearchSelections, [.track(song)])
        context.model.selectTab(.home)
        context.model.play(song)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertEqual(context.library.recentSearchSelections, [.track(song)])
    }

    func testCollectionResultsRecordDestinationsAndKeepKeyboardDismissedOnBack() async throws {
        let context = try makeContext()
        let album = MusicCollection(id: "chosen-album", title: "Chosen album", kind: .album)
        context.model.selectTab(.search)
        await context.seedSearch(CatalogPage(collections: [album]), query: "Album query", filter: .albums)
        context.model.activateSearchSelection(.collection(album), source: .result)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertEqual(context.library.recentSearchSelections, [.collection(album)])
        XCTAssertEqual(context.model.navigationPaths[.search], [album])
        context.model.navigationPath(for: .search).wrappedValue = []
        XCTAssertFalse(context.model.consumeSearchFocusRequest(context.model.searchFocusRequest))
        XCTAssertEqual(context.model.searchQuery, "Album query")
    }

    func testExplicitSubmitExecutesImmediatelyWithoutSavingAQueryOrRequiringDebounce() async throws {
        let context = try makeContext()
        context.model.selectTab(.search)
        context.model.searchQuery = "  Submitted query  "
        context.model.commitSearch()
        XCTAssertFalse(context.model.hasExecutedCurrentSearch)
        let before = await context.catalog.searches.requests
        XCTAssertTrue(before.isEmpty, "Commit only retires artist intent; the explicit search owns its request")
        let task = context.start { await $0.search() }
        let request = try await context.catalog.searches.request(at: 0)
        XCTAssertEqual(request.input, AppModelSearchRequest(query: "Submitted query", filter: .songs, continuation: nil))
        XCTAssertTrue(context.model.hasExecutedCurrentSearch)
        XCTAssertTrue(context.model.isSearching)
        let track = AppModelFixtures.track("submitted-result")
        try await context.catalog.searches.complete(request, with: .success(CatalogPage(tracks: [track])))
        await task.value
        XCTAssertEqual(context.model.searchPage.tracks, [track])
        XCTAssertTrue(context.model.hasSearched)
        XCTAssertFalse(context.model.isSearching)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        XCTAssertTrue(context.library.recentSearchSelections.isEmpty)
        context.model.searchQuery = "New draft"
        XCTAssertFalse(context.model.hasExecutedCurrentSearch)
    }

    func testSubmitRetiresPendingArtistWithoutCommittingTextOrAcceptingLateNavigation() async throws {
        let context = try makeContext()
        context.model.selectTab(.search)
        context.model.searchQuery = "Current draft"
        let artist = MusicCollection(id: "UClate-artist", title: "Late artist", kind: .artist)
        let lookup = context.start { await $0.openArtist(ArtistCredit(name: artist.title), searchSource: .resultMenu) }
        let request = try await context.catalog.searches.request(at: 0)
        XCTAssertTrue(context.model.isArtistLookupPending)
        context.model.commitSearch()
        XCTAssertFalse(context.model.isArtistLookupPending)
        try await context.catalog.searches.complete(request, with: .success(CatalogPage(collections: [artist])))
        await lookup.value
        XCTAssertTrue(context.model.navigationPaths[.search, default: []].isEmpty)
        XCTAssertEqual(context.model.searchQuery, "Current draft")
        XCTAssertTrue(context.library.recentSearchSelections.isEmpty)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        let requests = await context.catalog.searches.requests
        XCTAssertEqual(requests.count, 1)
    }

    private func makeContext() throws -> AppModelTestContext {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
