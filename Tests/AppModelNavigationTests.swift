import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelNavigationTests: XCTestCase {
    private let artistA = MusicCollection(id: "UC-artist-a", title: "Artist A", kind: .artist)
    private let artistB = MusicCollection(id: "UC-artist-b", title: "Artist B", kind: .artist)
    private let origin = MusicCollection(id: "origin-album", title: "Origin album", kind: .album)

    func testLinkedArtistBeatsPendingNameLookupForSuccessMissAndFailure() async throws {
        try await assertLookupRetired { context in
            await context.model.openArtist(ArtistCredit(name: artistB.title, id: artistB.id))
            XCTAssertEqual(context.model.navigationPaths[.library], [origin, artistB])
            let requests = await context.catalog.searches.requests
            XCTAssertEqual(requests.count, 1, "A linked artist opens without another lookup")
        }
    }

    func testTabChangesRetireLookupEvenWhenTheListenerReturnsToItsOrigin() async throws {
        for usesSelection in [false, true] {
            try await assertLookupRetired { context in
                if usesSelection {
                    context.model.selectTab(.home)
                    context.model.selectTab(.library)
                } else {
                    context.model.selectedTab = .home
                    context.model.selectedTab = .library
                }
            }
        }
    }

    func testFirstSearchTapRetiresLookupWithoutRequestingTheKeyboard() async throws {
        try await assertLookupRetired { context in
            context.model.selectTab(.search)
            XCTAssertEqual(context.model.searchFocusRequest, 0)
            XCTAssertFalse(context.model.consumeSearchFocusRequest(context.model.searchFocusRequest))
        }
    }

    func testSearchReselectionRetiresLookupAndKeepsItsOneFocusRequest() async throws {
        try await assertLookupRetired(prepare: { model in
            model.selectedTab = .search
            model.navigationPaths[.search] = [origin]
        }) { context in
            context.model.selectTab(.search)
            XCTAssertEqual(context.model.navigationPaths[.search], [])
            XCTAssertTrue(context.model.consumeSearchFocusRequest(context.model.searchFocusRequest))
            XCTAssertFalse(context.model.consumeSearchFocusRequest(context.model.searchFocusRequest))
        }
    }

    func testCollectionOpenAndUserPathPushOrPopRetireLookup() async throws {
        for path in 0..<4 {
            try await assertLookupRetired { context in
                switch path {
                case 0: context.model.open(artistB)
                case 1: context.model.navigationPath(for: .library).wrappedValue = [origin, artistB]
                case 2: context.model.navigationPath(for: .library).wrappedValue = []
                default: context.model.navigationPaths[.library] = [artistB]
                }
            }
        }
    }

    func testViewLocalNavigationCanRetireLookupWithoutChangingAModelBinding() async throws {
        try await assertLookupRetired { context in
            context.model.cancelPendingArtistLookup()
        }
    }

    func testPresentingPlayerOrSettingsRetiresLookupWithoutLettingItDismissTheScreen() async throws {
        for presentsPlayer in [false, true] {
            try await assertLookupRetired { context in
                if presentsPlayer { context.model.isPlayerPresented = true }
                else { context.model.isSettingsPresented = true }
            }
        }
    }

    func testDismissingPlayerOrSettingsAlsoRetiresItsPendingLookup() async throws {
        for presentsPlayer in [false, true] {
            try await assertLookupRetired(prepare: { model in
                if presentsPlayer { model.isPlayerPresented = true }
                else { model.isSettingsPresented = true }
            }) { context in
                context.model.isPlayerPresented = false
                context.model.isSettingsPresented = false
            }
        }
    }

    func testSearchBindingEditsRetireLookupBeforeDebounceEvenIfTheDraftIsRestored() async throws {
        for changesFilter in [false, true] {
            try await assertLookupRetired { context in
                if changesFilter {
                    context.model.searchFilter = .songs
                    context.model.searchFilter = .albums
                } else {
                    context.model.searchQuery = "New draft"
                    context.model.searchQuery = "Existing draft"
                }
            }
        }
    }

    func testProgrammaticSearchAndCommittingAnUnchangedQueryRetireLookup() async throws {
        for opensSearch in [false, true] {
            try await assertLookupRetired { context in
                if opensSearch { context.model.openSearch("New search") }
                else { context.model.commitSearch() }
            }
        }
    }

    func testRefreshingTheSameSearchRetiresLookupAndKeepsTheNewResults() async throws {
        try await assertLookupRetired { context in
            await context.catalog.searches.enqueue(.success(CatalogPage(collections: [artistB])))
            await context.model.search()
            XCTAssertEqual(context.model.searchPage.collections, [artistB])
        }
    }

    func testEmptySearchLifecycleAfterPlayerDismissalKeepsTheNameOnlyArtistIntent() async throws {
        for (index, result) in lookupOutcomes.enumerated() {
            let context = try makeSearchPlayerContext()
            let task = try dismissPlayerAndOpenArtist(in: context)
            let request = try await context.catalog.searches.request(at: 0)
            XCTAssertEqual(request.input, AppModelSearchRequest(query: artistA.title, filter: .artists, continuation: nil))
            XCTAssertTrue(context.model.isArtistLookupPending)

            await context.model.loadSearch()
            await context.model.loadSearch()
            XCTAssertTrue(context.model.isArtistLookupPending, "Search appearance is data work, not a newer Search action")
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertFalse(context.model.isSearching)
            XCTAssertFalse(context.model.hasSearched)
            let requests = await context.catalog.searches.requests
            XCTAssertEqual(requests.count, 1, "Empty-query lifecycle work must not issue another catalog lookup")
            try await context.catalog.searches.complete(request, with: result)
            await task.value

            XCTAssertEqual(context.model.selectedTab, .search)
            if index == 0 {
                XCTAssertEqual(context.model.navigationPaths[.search], [artistA])
                XCTAssertEqual(context.model.searchQuery, "")
            } else {
                XCTAssertEqual(context.model.navigationPaths[.search], [])
                XCTAssertEqual(context.model.searchQuery, artistA.title, "A current miss or failure still falls back to the artist's search")
            }
            XCTAssertFalse(context.model.isArtistLookupPending)
            XCTAssertEqual(context.model.searchFocusRequest, 0)
            XCTAssertTrue(context.library.recentSearches.isEmpty)
        }
    }

    func testUnchangedQueryDataLoadAfterPlayerDismissalKeepsPendingArtistLookup() async throws {
        for fails in [false, true] {
            let context = try makeSearchPlayerContext(query: "Earlier draft")
            let artistTask = try dismissPlayerAndOpenArtist(in: context)
            let artistRequest = try await context.catalog.searches.request(at: 0)
            let dataTask = context.start { await $0.loadSearch() }
            let dataRequest = try await context.catalog.searches.request(at: 1)
            XCTAssertEqual(dataRequest.input, AppModelSearchRequest(query: "Earlier draft", filter: .songs, continuation: nil))
            let dataResult: Result<CatalogPage, any Error> = fails
                ? .failure(MusicServiceError.unavailable("Background search failed"))
                : .success(CatalogPage(tracks: [AppModelFixtures.track("background-result")]))
            try await context.catalog.searches.complete(dataRequest, with: dataResult)
            await dataTask.value
            XCTAssertTrue(context.model.isArtistLookupPending)
            XCTAssertTrue(context.model.hasSearched)
            XCTAssertFalse(context.model.isSearching)
            XCTAssertEqual(context.model.searchError, fails ? "Background search failed" : nil)
            try await context.catalog.searches.complete(artistRequest, with: .success(CatalogPage(collections: [artistA])))
            await artistTask.value

            XCTAssertEqual(context.model.navigationPaths[.search], [artistA])
            XCTAssertEqual(context.model.searchQuery, "Earlier draft")
            XCTAssertFalse(context.model.isPlayerPresented)
            XCTAssertFalse(context.model.isArtistLookupPending)
        }
    }

    func testBackgroundSearchFinishingAfterArtistOpenKeepsTheDestination() async throws {
        let context = try makeSearchPlayerContext(query: "Earlier draft")
        let artistTask = try dismissPlayerAndOpenArtist(in: context)
        let artistRequest = try await context.catalog.searches.request(at: 0)
        let dataTask = context.start { await $0.loadSearch() }
        let dataRequest = try await context.catalog.searches.request(at: 1)
        try await context.catalog.searches.complete(artistRequest, with: .success(CatalogPage(collections: [artistA])))
        await artistTask.value
        XCTAssertEqual(context.model.navigationPaths[.search], [artistA])
        let result = AppModelFixtures.track("background-result")
        try await context.catalog.searches.complete(dataRequest, with: .success(CatalogPage(tracks: [result])))
        await dataTask.value

        XCTAssertEqual(context.model.navigationPaths[.search], [artistA])
        XCTAssertEqual(context.model.searchQuery, "Earlier draft")
        XCTAssertEqual(context.model.searchPage.tracks, [result])
        XCTAssertFalse(context.model.isPlayerPresented)
        XCTAssertEqual(context.model.searchFocusRequest, 0)
    }

    func testNewSearchEditsSubmitAndReselectionBeatArtistAfterLifecycleLoad() async throws {
        for intent in ["query", "filter", "submit", "reselect"] {
            for result in lookupOutcomes {
                let context = try makeSearchPlayerContext()
                let task = try dismissPlayerAndOpenArtist(in: context)
                let request = try await context.catalog.searches.request(at: 0)
                await context.model.loadSearch()
                XCTAssertTrue(context.model.isArtistLookupPending)
                switch intent {
                case "query": context.model.searchQuery = "A newer search"
                case "filter": context.model.searchFilter = .albums
                case "submit": context.model.commitSearch()
                default: context.model.selectTab(.search)
                }
                XCTAssertFalse(context.model.isArtistLookupPending)
                let query = context.model.searchQuery
                let filter = context.model.searchFilter
                let focus = context.model.searchFocusRequest
                try await context.catalog.searches.complete(request, with: result)
                await task.value

                XCTAssertEqual(context.model.navigationPaths[.search], [])
                XCTAssertEqual(context.model.selectedTab, .search)
                XCTAssertEqual(context.model.searchQuery, query)
                XCTAssertEqual(context.model.searchFilter, filter)
                XCTAssertFalse(context.model.isPlayerPresented)
                if intent == "reselect" { XCTAssertTrue(context.model.consumeSearchFocusRequest(focus)) }
            }
        }
    }

    func testExplicitRetryRetiresArtistBeforeItsDeferredSearchDataLoad() async throws {
        for result in lookupOutcomes {
            let context = try makeSearchPlayerContext()
            let task = try dismissPlayerAndOpenArtist(in: context)
            let request = try await context.catalog.searches.request(at: 0)
            await context.model.loadSearch()
            XCTAssertTrue(context.model.isArtistLookupPending)
            context.model.cancelPendingArtistLookup()
            try await context.catalog.searches.complete(request, with: result)
            await task.value
            XCTAssertEqual(context.model.navigationPaths[.search], [])
            XCTAssertEqual(context.model.searchQuery, "", "Retry retires navigation at the tap, before debounce runs")
            await context.model.loadSearch()
            XCTAssertFalse(context.model.isArtistLookupPending)
            XCTAssertEqual(context.model.navigationPaths[.search], [])
        }
    }

    func testExplicitEmptyQueryRefreshStillRetiresLookupAfterLifecycleLoad() async throws {
        for result in lookupOutcomes {
            let context = try makeSearchPlayerContext()
            let task = try dismissPlayerAndOpenArtist(in: context)
            let request = try await context.catalog.searches.request(at: 0)
            await context.model.loadSearch()
            XCTAssertTrue(context.model.isArtistLookupPending)
            await context.model.search()
            XCTAssertFalse(context.model.isArtistLookupPending)
            try await context.catalog.searches.complete(request, with: result)
            await task.value
            XCTAssertEqual(context.model.navigationPaths[.search], [])
            XCTAssertEqual(context.model.searchQuery, "")
        }
    }

    func testPlayingANewSelectionRetiresLookup() async throws {
        try await assertLookupRetired { context in
            context.model.play(AppModelFixtures.track("new-selection"))
        }
    }

    func testOldLookupCannotClearTheNewNameLookupSpinnerOrDestination() async throws {
        for result in lookupOutcomes {
            let context = try makeContext()
            context.model.selectedTab = .library
            let oldTask = context.start { await $0.openArtist(ArtistCredit(name: self.artistA.title)) }
            let old = try await context.catalog.searches.request(at: 0)
            let currentTask = context.start { await $0.openArtist(ArtistCredit(name: self.artistB.title)) }
            let current = try await context.catalog.searches.request(at: 1)
            try await context.catalog.searches.complete(old, with: result)
            await oldTask.value
            XCTAssertTrue(context.model.isArtistLookupPending)
            XCTAssertTrue(context.model.navigationPaths.isEmpty)
            XCTAssertEqual(context.model.selectedTab, .library)
            try await context.catalog.searches.complete(current, with: .success(CatalogPage(collections: [artistB])))
            await currentTask.value
            XCTAssertEqual(context.model.navigationPaths[.library], [artistB])
            XCTAssertFalse(context.model.isArtistLookupPending)
        }
    }

    func testCurrentLookupCanApplyItsOwnNavigationAndPresentationChanges() async throws {
        for presentation in 0..<3 {
            for (index, result) in lookupOutcomes.enumerated() {
                let context = try makeContext()
                let model = context.model
                model.selectedTab = .library
                model.navigationPaths[.library] = [origin]
                model.isPlayerPresented = presentation == 1
                model.isSettingsPresented = presentation == 2
                let task = context.start { await $0.openArtist(ArtistCredit(name: self.artistA.title)) }
                let request = try await context.catalog.searches.request(at: 0)
                XCTAssertTrue(model.isArtistLookupPending)
                try await context.catalog.searches.complete(request, with: result)
                await task.value
                if index == 0 {
                    XCTAssertEqual(model.selectedTab, .library)
                    XCTAssertEqual(model.navigationPaths[.library], [origin, artistA])
                } else {
                    XCTAssertEqual(model.selectedTab, .search)
                    XCTAssertEqual(model.searchQuery, artistA.title)
                    XCTAssertEqual(model.searchFilter, .songs)
                    XCTAssertEqual(model.navigationPaths[.search], [])
                }
                XCTAssertFalse(model.isPlayerPresented)
                XCTAssertFalse(model.isSettingsPresented)
                XCTAssertFalse(model.isArtistLookupPending)
                XCTAssertEqual(model.searchFocusRequest, 0)
            }
        }
    }

    func testUnchangedBindingsAndKeyboardDismissalDoNotRetireCurrentLookup() async throws {
        let context = try makeContext()
        let model = context.model
        model.selectedTab = .library
        let task = context.start { await $0.openArtist(ArtistCredit(name: self.artistA.title)) }
        let request = try await context.catalog.searches.request(at: 0)
        model.selectedTab = .library
        model.navigationPath(for: .library).wrappedValue = []
        model.navigationPath(for: .search).wrappedValue = []
        model.isPlayerPresented = false
        model.isSettingsPresented = false
        model.searchQuery = ""
        model.searchFilter = .songs
        model.dismissSearchKeyboard()
        XCTAssertTrue(model.isArtistLookupPending)
        try await context.catalog.searches.complete(request, with: .success(CatalogPage(collections: [artistA])))
        await task.value
        XCTAssertEqual(model.navigationPaths[.library], [artistA])
        XCTAssertFalse(model.isArtistLookupPending)
    }

    func testCancelledLookupIgnoresALateProviderResponse() async throws {
        for result in lookupOutcomes {
            let context = try makeContext()
            let task = context.start { await $0.openArtist(ArtistCredit(name: self.artistA.title)) }
            let request = try await context.catalog.searches.request(at: 0)
            task.cancel()
            try await AppModelFixtures.eventually { await context.catalog.searches.cancellations.contains(request.id) }
            try await context.catalog.searches.complete(request, with: result)
            await task.value
            XCTAssertTrue(context.model.navigationPaths.isEmpty)
            XCTAssertEqual(context.model.selectedTab, .home)
            XCTAssertEqual(context.model.searchQuery, "")
            XCTAssertFalse(context.model.isArtistLookupPending)
        }
    }

    private var lookupOutcomes: [Result<CatalogPage, any Error>] {
        [.success(CatalogPage(collections: [artistA])), .success(CatalogPage()),
         .failure(MusicServiceError.unavailable("Artist lookup failed"))]
    }

    private func assertLookupRetired(prepare: @MainActor (MusicAppModel) -> Void = { _ in },
                                     file: StaticString = #filePath, line: UInt = #line,
                                     after newerIntent: @MainActor (AppModelTestContext) async throws -> Void) async throws {
        for result in lookupOutcomes {
            let context = try makeContext()
            let model = context.model
            model.selectedTab = .library
            model.navigationPaths[.library] = [origin]
            model.searchQuery = "Existing draft"
            model.searchFilter = .albums
            prepare(model)
            let task = context.start { await $0.openArtist(ArtistCredit(name: self.artistA.title)) }
            let request = try await context.catalog.searches.request(at: 0)
            XCTAssertTrue(model.isArtistLookupPending, file: file, line: line)
            try await newerIntent(context)
            XCTAssertFalse(model.isArtistLookupPending, file: file, line: line)
            let tab = model.selectedTab
            let paths = model.navigationPaths
            let query = model.searchQuery
            let filter = model.searchFilter
            let playerPresented = model.isPlayerPresented
            let settingsPresented = model.isSettingsPresented
            let focus = model.searchFocusRequest
            let dismissals = model.searchFocusDismissal
            let results = model.searchPage
            try await context.catalog.searches.complete(request, with: result)
            await task.value
            XCTAssertEqual(model.selectedTab, tab, file: file, line: line)
            XCTAssertEqual(model.navigationPaths, paths, file: file, line: line)
            XCTAssertEqual(model.searchQuery, query, file: file, line: line)
            XCTAssertEqual(model.searchFilter, filter, file: file, line: line)
            XCTAssertEqual(model.isPlayerPresented, playerPresented, file: file, line: line)
            XCTAssertEqual(model.isSettingsPresented, settingsPresented, file: file, line: line)
            XCTAssertEqual(model.searchFocusRequest, focus, file: file, line: line)
            XCTAssertEqual(model.searchFocusDismissal, dismissals, file: file, line: line)
            XCTAssertEqual(model.searchPage.tracks, results.tracks, file: file, line: line)
            XCTAssertEqual(model.searchPage.collections, results.collections, file: file, line: line)
            XCTAssertFalse(model.isArtistLookupPending, file: file, line: line)
        }
    }

    private func makeSearchPlayerContext(query: String = "") throws -> AppModelTestContext {
        var track = AppModelFixtures.track("name-only-artist-song")
        track.credits = [ArtistCredit(name: artistA.title)]
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [track], position: 32))
        context.model.openSearch(query)
        context.model.isPlayerPresented = true
        return context
    }

    private func dismissPlayerAndOpenArtist(in context: AppModelTestContext) throws -> Task<Void, Never> {
        let credit = try XCTUnwrap(context.player.currentTrack?.allCredits.first)
        XCTAssertNil(credit.collection)
        var task: Task<Void, Never>?
        AppNavigationIntent.perform(in: context.model) {
            context.model.isPlayerPresented = false
            task = context.start { await $0.openArtist(credit) }
        }
        return try XCTUnwrap(task)
    }

    private func makeContext(snapshot: PlaybackSnapshot = PlaybackSnapshot()) throws -> AppModelTestContext {
        let context = try AppModelTestContext(snapshot: snapshot)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
