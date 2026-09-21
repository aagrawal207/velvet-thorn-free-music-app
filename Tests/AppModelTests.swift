import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelTests: XCTestCase {
    func testOlderQueryCannotPublishResultsOrStopTheNewSearchSpinner() async throws {
        let context = try makeContext()
        let model = context.model
        model.searchQuery = "old query"
        let oldTask = context.start { await $0.search() }
        let old = try await context.catalog.searches.request(at: 0)
        model.searchQuery = "  नया गाना  "
        let newTask = context.start { await $0.search() }
        let current = try await context.catalog.searches.request(at: 1)
        XCTAssertEqual(current.input, AppModelSearchRequest(query: "नया गाना", filter: .songs, continuation: nil))

        try await context.catalog.searches.complete(old, with: .success(CatalogPage(tracks: [AppModelFixtures.track("old")], continuation: "old-next")))
        await oldTask.value
        XCTAssertTrue(model.isSearching)
        XCTAssertTrue(model.searchPage.tracks.isEmpty)
        XCTAssertNil(model.searchPage.continuation)
        XCTAssertFalse(model.hasSearched)

        let expected = AppModelFixtures.track("new")
        try await context.catalog.searches.complete(current, with: .success(CatalogPage(tracks: [expected])))
        await newTask.value
        XCTAssertEqual(model.searchPage.tracks, [expected])
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.hasSearched)
        XCTAssertNil(model.searchError)
    }

    func testOlderFilterSuccessAndFailureCannotReplaceCompletedAlbumSearch() async throws {
        for fails in [false, true] {
            let context = try makeContext()
            let model = context.model
            model.searchQuery = "same artist"
            let oldTask = context.start { await $0.search() }
            let old = try await context.catalog.searches.request(at: 0)
            model.searchFilter = .albums
            let newTask = context.start { await $0.search() }
            let current = try await context.catalog.searches.request(at: 1)
            let album = MusicCollection(id: "album", title: "Current album", kind: .album)
            try await context.catalog.searches.complete(current, with: .success(CatalogPage(collections: [album], continuation: "album-next")))
            await newTask.value
            let oldResult: Result<CatalogPage, any Error> = fails
                ? .failure(MusicServiceError.unavailable("Obsolete songs error"))
                : .success(CatalogPage(tracks: [AppModelFixtures.track("obsolete-song")]))
            try await context.catalog.searches.complete(old, with: oldResult)
            await oldTask.value

            XCTAssertEqual(model.searchPage.collections, [album])
            XCTAssertTrue(model.searchPage.tracks.isEmpty)
            XCTAssertEqual(model.searchPage.continuation, "album-next")
            XCTAssertNil(model.searchError)
            XCTAssertTrue(model.hasSearched)
            XCTAssertFalse(model.isSearching)
        }
    }

    func testLateSuccessCannotEraseTheNewQueryFailure() async throws {
        let context = try makeContext()
        context.model.searchQuery = "old"
        let oldTask = context.start { await $0.search() }
        let old = try await context.catalog.searches.request(at: 0)
        context.model.searchQuery = "new"
        let currentTask = context.start { await $0.search() }
        let current = try await context.catalog.searches.request(at: 1)
        try await context.catalog.searches.complete(current, with: .failure(MusicServiceError.unavailable("Current failure")))
        await currentTask.value
        try await context.catalog.searches.complete(old, with: .success(CatalogPage(tracks: [AppModelFixtures.track("old")])))
        await oldTask.value
        XCTAssertEqual(context.model.searchError, "Current failure")
        XCTAssertTrue(context.model.searchPage.tracks.isEmpty)
        XCTAssertTrue(context.model.hasSearched)
        XCTAssertFalse(context.model.isSearching)
    }

    func testEditingQueryOrFilterBeforeDebouncedSearchRejectsLateSuccess() async throws {
        for changesFilter in [false, true] {
            let context = try makeContext()
            context.model.searchQuery = "original"
            let task = context.start { await $0.search() }
            let request = try await context.catalog.searches.request(at: 0)
            if changesFilter { context.model.searchFilter = .artists }
            else { context.model.searchQuery = "edited" }
            try await context.catalog.searches.complete(request, with: .success(CatalogPage(tracks: [AppModelFixtures.track("obsolete")], continuation: "obsolete-next")))
            await task.value
            XCTAssertTrue(context.model.searchPage.tracks.isEmpty)
            XCTAssertNil(context.model.searchPage.continuation)
            XCTAssertFalse(context.model.hasSearched)
            XCTAssertFalse(context.model.isSearching)
        }
    }

    func testEditingQueryOrFilterBeforeDebouncedSearchRejectsLateFailure() async throws {
        for changesFilter in [false, true] {
            let context = try makeContext()
            context.model.searchQuery = "original"
            let task = context.start { await $0.search() }
            let request = try await context.catalog.searches.request(at: 0)
            if changesFilter { context.model.searchFilter = .artists }
            else { context.model.searchQuery = "edited" }
            try await context.catalog.searches.complete(request, with: .failure(MusicServiceError.unavailable("Obsolete request failed")))
            await task.value
            XCTAssertNil(context.model.searchError, "An edited request must not inherit the previous request's error")
            XCTAssertFalse(context.model.hasSearched, "The edited input has not been searched yet")
            XCTAssertFalse(context.model.isSearching)
        }
    }

    func testEmptySearchInvalidatesPendingWorkWithoutCallingProvider() async throws {
        let context = try makeContext()
        context.model.searchQuery = "pending"
        let task = context.start { await $0.search() }
        let request = try await context.catalog.searches.request(at: 0)
        context.model.searchQuery = " \n\t "
        await context.model.search()
        try await context.catalog.searches.complete(request, with: .failure(MusicServiceError.unavailable("Late error")))
        await task.value
        let requests = await context.catalog.searches.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(context.model.isSearching)
        XCTAssertFalse(context.model.hasSearched)
        XCTAssertNil(context.model.searchError)
        XCTAssertTrue(context.model.searchPage.tracks.isEmpty)
        XCTAssertTrue(context.model.searchPage.collections.isEmpty)
    }

    func testCancelledSearchIgnoresProviderThatStillReturnsAndCanRetry() async throws {
        let context = try makeContext()
        context.model.searchQuery = "retry me"
        let task = context.start { await $0.search() }
        let request = try await context.catalog.searches.request(at: 0)
        task.cancel()
        try await AppModelFixtures.eventually { await context.catalog.searches.cancellations.contains(request.id) }
        try await context.catalog.searches.complete(request, with: .success(CatalogPage(tracks: [AppModelFixtures.track("cancelled")], continuation: "cancelled-next")))
        await task.value
        XCTAssertTrue(context.model.searchPage.tracks.isEmpty)
        XCTAssertNil(context.model.searchPage.continuation)
        XCTAssertFalse(context.model.hasSearched)
        XCTAssertFalse(context.model.isSearching)
        XCTAssertNil(context.model.searchError)
        let expected = AppModelFixtures.track("retry")
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [expected])))
        await context.model.search()
        XCTAssertEqual(context.model.searchPage.tracks, [expected])
        XCTAssertTrue(context.model.hasSearched)
    }

    func testPaginationDeduplicatesByIDAcrossAndWithinPagesAndConsumesCursor() async throws {
        let context = try makeContext()
        let a = AppModelFixtures.track("a")
        let b = AppModelFixtures.track("b")
        let c = AppModelFixtures.track("c")
        let d = AppModelFixtures.track("d")
        let first = MusicCollection(id: "one", title: "First album", kind: .album)
        let second = MusicCollection(id: "two", title: "Second album", kind: .album)
        await context.seedSearch(CatalogPage(tracks: [a, b], collections: [first], continuation: "page-2", title: "Original title"),
                                 query: "  music  ", filter: .albums)
        var duplicateB = b
        duplicateB.title = "Changed duplicate metadata"
        var duplicateC = c
        duplicateC.title = "Later duplicate in the same page"
        var duplicateFirst = first
        duplicateFirst.title = "Duplicate album"
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [duplicateB, c, duplicateC, a, d],
            collections: [duplicateFirst, second, second], continuation: "page-3", title: "Later title")))
        await context.model.loadMoreSearch()
        XCTAssertEqual(context.model.searchPage.tracks, [a, b, c, d])
        XCTAssertEqual(context.model.searchPage.collections, [first, second])
        XCTAssertEqual(context.model.searchPage.continuation, "page-3")
        XCTAssertEqual(context.model.searchPage.title, "Original title")
        let request = try await context.catalog.searches.request(at: 1)
        XCTAssertEqual(request.input, AppModelSearchRequest(query: "music", filter: .albums, continuation: "page-2"))

        let last = AppModelFixtures.track("last")
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [d, last], collections: [second])))
        await context.model.loadMoreSearch()
        await context.model.loadMoreSearch()
        let requests = await context.catalog.searches.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[2].input.continuation, "page-3")
        XCTAssertEqual(context.model.searchPage.tracks, [a, b, c, d, last])
        XCTAssertNil(context.model.searchPage.continuation)
        XCTAssertFalse(context.model.isSearching)
    }

    func testConcurrentPaginationIsSingleFlightAndFailureKeepsRetryableContent() async throws {
        let context = try makeContext()
        let original = AppModelFixtures.track("original")
        await context.seedSearch(CatalogPage(tracks: [original], continuation: "next"))
        let task = context.start { await $0.loadMoreSearch() }
        let request = try await context.catalog.searches.request(at: 1)
        await context.model.loadMoreSearch()
        let requests = await context.catalog.searches.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(context.model.isSearching)
        try await context.catalog.searches.complete(request, with: .failure(MusicServiceError.unavailable("Page failed")))
        await task.value
        XCTAssertEqual(context.model.searchPage.tracks, [original])
        XCTAssertEqual(context.model.searchPage.continuation, "next")
        XCTAssertEqual(context.model.searchError, "Page failed")
        XCTAssertTrue(context.model.hasSearched)
        XCTAssertFalse(context.model.isSearching)

        let additional = AppModelFixtures.track("additional")
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [additional])))
        await context.model.loadMoreSearch()
        let retry = try await context.catalog.searches.request(at: 2)
        XCTAssertEqual(retry.input, request.input)
        XCTAssertEqual(context.model.searchPage.tracks, [original, additional])
        XCTAssertNil(context.model.searchError)
        XCTAssertNil(context.model.searchPage.continuation)
    }

    func testCancelledPaginationIgnoresLateSuccessOrFailureAndRetainsRetryCursor() async throws {
        for fails in [false, true] {
            let context = try makeContext()
            let original = AppModelFixtures.track("original")
            await context.seedSearch(CatalogPage(tracks: [original], continuation: "next"))
            let task = context.start { await $0.loadMoreSearch() }
            let request = try await context.catalog.searches.request(at: 1)
            task.cancel()
            try await AppModelFixtures.eventually { await context.catalog.searches.cancellations.contains(request.id) }
            let result: Result<CatalogPage, any Error> = fails
                ? .failure(MusicServiceError.unavailable("Cancelled page failed"))
                : .success(CatalogPage(tracks: [AppModelFixtures.track("cancelled")]))
            try await context.catalog.searches.complete(request, with: result)
            await task.value
            XCTAssertEqual(context.model.searchPage.tracks, [original])
            XCTAssertEqual(context.model.searchPage.continuation, "next")
            XCTAssertNil(context.model.searchError)
            XCTAssertFalse(context.model.isSearching)
            XCTAssertTrue(context.model.hasSearched)
            await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [AppModelFixtures.track("retry")])))
            await context.model.loadMoreSearch()
            XCTAssertEqual(context.model.searchPage.tracks.map(\.id), ["original", "retry"])
        }
    }

    func testNewSearchRejectsOldPaginationWithoutEndingItsLoadingState() async throws {
        for fails in [false, true] {
            let context = try makeContext()
            await context.seedSearch(CatalogPage(tracks: [AppModelFixtures.track("old")], continuation: "old-next"))
            let pageTask = context.start { await $0.loadMoreSearch() }
            let page = try await context.catalog.searches.request(at: 1)
            context.model.searchQuery = "new artist"
            context.model.searchFilter = .artists
            let searchTask = context.start { await $0.search() }
            let search = try await context.catalog.searches.request(at: 2)
            let result: Result<CatalogPage, any Error> = fails
                ? .failure(MusicServiceError.unavailable("Old page error"))
                : .success(CatalogPage(tracks: [AppModelFixtures.track("old-page")], continuation: "old-page-3"))
            try await context.catalog.searches.complete(page, with: result)
            await pageTask.value
            XCTAssertTrue(context.model.isSearching)
            XCTAssertTrue(context.model.searchPage.tracks.isEmpty)
            XCTAssertNil(context.model.searchError)
            let artist = MusicCollection(id: "artist", title: "New artist", kind: .artist)
            try await context.catalog.searches.complete(search, with: .success(CatalogPage(collections: [artist])))
            await searchTask.value
            XCTAssertEqual(context.model.searchPage.collections, [artist])
            XCTAssertTrue(context.model.searchPage.tracks.isEmpty)
            XCTAssertNil(context.model.searchPage.continuation)
        }
    }

    func testEditingQueryOrFilterDiscardsPendingPaginationSuccessAndFailure() async throws {
        for changesFilter in [false, true] {
            for fails in [false, true] {
                let context = try makeContext()
                let original = AppModelFixtures.track("original")
                await context.seedSearch(CatalogPage(tracks: [original], continuation: "next"))
                let task = context.start { await $0.loadMoreSearch() }
                let request = try await context.catalog.searches.request(at: 1)
                if changesFilter { context.model.searchFilter = .playlists }
                else { context.model.searchQuery = "edited" }
                let result: Result<CatalogPage, any Error> = fails
                    ? .failure(MusicServiceError.unavailable("Obsolete pagination error"))
                    : .success(CatalogPage(tracks: [AppModelFixtures.track("obsolete-page")]))
                try await context.catalog.searches.complete(request, with: result)
                await task.value
                XCTAssertEqual(context.model.searchPage.tracks, [original])
                XCTAssertEqual(context.model.searchPage.continuation, "next")
                XCTAssertNil(context.model.searchError, "The edited input must not inherit a previous page's error")
                XCTAssertFalse(context.model.isSearching)
            }
        }
    }

    func testPaginationNeverSendsPreviousCursorWithEditedQueryOrFilter() async throws {
        for changesFilter in [false, true] {
            let context = try makeContext()
            let original = AppModelFixtures.track("original")
            await context.seedSearch(CatalogPage(tracks: [original], continuation: "original-only-cursor"))
            if changesFilter { context.model.searchFilter = .albums }
            else { context.model.searchQuery = "edited" }
            await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [AppModelFixtures.track("unrelated")])))
            await context.model.loadMoreSearch()
            let requests = await context.catalog.searches.requests
            XCTAssertEqual(requests.count, 1, "A continuation belongs to the completed request, not the currently edited fields")
            XCTAssertFalse(context.model.searchPage.tracks.contains { $0.id == "unrelated" })
            XCTAssertNil(context.model.searchError)
        }
    }

    func testHomePublishesUsefulSectionsBeforeSlowChartsAndKeepsPersonalRadio() async throws {
        let context = try makeContext(languages: [.hindi, .english])
        let seed = context.seedListener(primary: AppModelFixtures.track("hindi-seed", language: .hindi), language: .hindi)
        let task = context.start { await $0.loadHome() }
        let discovery = try await context.catalog.discoveries.request(at: 0)
        let artist = try await context.catalog.artists.request(at: 0)
        let chartRequests = [try await context.charts.charts.request(at: 0), try await context.charts.charts.request(at: 1)]
        XCTAssertEqual(discovery.input, [.hindi, .english])
        XCTAssertEqual(artist.input, seed.artistID)
        let personal = AppModelFixtures.track("personal", language: .hindi)
        try await context.catalog.artists.complete(artist, with: .success(context.artistPage(artist.input, songs: [personal])))
        try await AppModelFixtures.eventually { context.model.homeSections.contains { $0.tracks == [personal] } }
        XCTAssertTrue(context.model.isLoadingHome)

        let sections = [AppModelFixtures.section("hindi", language: .hindi), AppModelFixtures.section("english")]
        try await context.catalog.discoveries.complete(discovery, with: .success(sections))
        try await AppModelFixtures.eventually { context.model.homeSections.count == 3 }
        XCTAssertTrue(context.model.isLoadingHome)
        XCTAssertEqual(context.model.homeSections.first?.tracks, [personal])
        let hindiChart = AppModelFixtures.chart("weekly-hindi", language: .hindi)
        for request in chartRequests {
            let result: Result<ChartSnapshot, any Error> = request.input == .hindi
                ? .success(hindiChart) : .failure(MusicServiceError.unavailable("Optional English chart unavailable"))
            try await context.charts.charts.complete(request, with: result)
        }
        await task.value
        XCTAssertEqual(context.model.homeSections.map(\.id), ["personal.UChindi-seed", "hindi", "english"])
        XCTAssertEqual(context.model.charts.map(\.id), [hindiChart.id])
        XCTAssertEqual(context.model.charts.first?.periodStart, hindiChart.periodStart)
        XCTAssertEqual(context.model.charts.first?.periodEnd, hindiChart.periodEnd)
        XCTAssertEqual(context.model.charts.first?.source, hindiChart.source)
        XCTAssertNil(context.model.homeError)
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testDiscoveryFailureKeepsSuccessfulChartAndPersonalRadio() async throws {
        let context = try makeContext()
        let seed = context.seedListener(primary: AppModelFixtures.track("seed"))
        await context.catalog.discoveries.enqueue(.failure(MusicServiceError.unavailable("Discovery failed")))
        await context.catalog.artists.enqueue(.success(context.artistPage(seed.artistID ?? "", songs: [AppModelFixtures.track("personal")])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("weekly")))
        await context.model.loadHome()
        XCTAssertEqual(context.model.homeSections.flatMap(\.tracks).map(\.id), ["personal"])
        XCTAssertEqual(context.model.charts.map(\.id), ["weekly"])
        XCTAssertEqual(context.model.homeError, "Discovery failed")
        XCTAssertFalse(context.model.isLoadingHome)

        await context.catalog.discoveries.enqueue(.success([AppModelFixtures.section("retry")]))
        await context.catalog.artists.enqueue(.failure(MusicServiceError.unavailable("Artist unavailable")))
        await context.charts.charts.enqueue(.failure(MusicServiceError.unavailable("Chart unavailable")))
        await context.model.loadHome()
        let discoveries = await context.catalog.discoveries.requests
        XCTAssertEqual(discoveries.count, 2, "A failed discovery must remain retryable without force")
        XCTAssertTrue(context.model.homeSections.contains { $0.id == "retry" })
        XCTAssertEqual(context.model.charts.map(\.id), ["weekly"])
        XCTAssertNil(context.model.homeError)
    }

    func testFailedForcedHomeRefreshPreservesPreviouslyLoadedContent() async throws {
        let context = try makeContext()
        let seed = context.seedListener(primary: AppModelFixtures.track("seed"))
        await context.catalog.discoveries.enqueue(.success([AppModelFixtures.section("cached")]))
        await context.catalog.artists.enqueue(.success(context.artistPage(seed.artistID ?? "", songs: [AppModelFixtures.track("personal")])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("cached-chart")))
        await context.model.loadHome()
        await context.catalog.discoveries.enqueue(.failure(MusicServiceError.unavailable("Refresh failed")))
        await context.catalog.artists.enqueue(.failure(MusicServiceError.unavailable("Artist failed")))
        await context.charts.charts.enqueue(.failure(MusicServiceError.unavailable("Chart failed")))
        await context.model.loadHome(force: true)
        XCTAssertEqual(context.model.homeSections.map(\.id), ["personal.UCseed", "cached"])
        XCTAssertEqual(context.model.charts.map(\.id), ["cached-chart"])
        XCTAssertEqual(context.model.homeError, "Refresh failed")
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testNewLanguageLoadRejectsEveryOldHomeResponseAndKeepsItsSpinner() async throws {
        let context = try makeContext(languages: [.hindi])
        _ = context.seedListener(primary: AppModelFixtures.track("hindi-seed", language: .hindi), language: .hindi)
        let oldTask = context.start { await $0.loadHome(force: true) }
        let oldDiscovery = try await context.catalog.discoveries.request(at: 0)
        let oldChart = try await context.charts.charts.request(at: 0)
        let oldArtist = try await context.catalog.artists.request(at: 0)
        context.library.preferences.languages = [.english]
        let newTask = context.start { await $0.loadHome(force: true) }
        let newDiscovery = try await context.catalog.discoveries.request(at: 1)
        let newChart = try await context.charts.charts.request(at: 1)
        let newArtist = try await context.catalog.artists.request(at: 1)
        XCTAssertEqual(newDiscovery.input, [.english])
        XCTAssertEqual(newChart.input, .english)
        try await context.catalog.artists.complete(oldArtist, with: .success(context.artistPage(oldArtist.input, songs: [AppModelFixtures.track("old-radio", language: .hindi)])))
        try await context.catalog.discoveries.complete(oldDiscovery, with: .success([AppModelFixtures.section("old-home", language: .hindi)]))
        try await context.charts.charts.complete(oldChart, with: .success(AppModelFixtures.chart("old-chart", language: .hindi)))
        await oldTask.value
        XCTAssertTrue(context.model.homeSections.isEmpty)
        XCTAssertTrue(context.model.charts.isEmpty)
        XCTAssertTrue(context.model.isLoadingHome)
        XCTAssertNil(context.model.homeError)

        try await context.catalog.discoveries.complete(newDiscovery, with: .success([AppModelFixtures.section("new-home")]))
        try await context.charts.charts.complete(newChart, with: .success(AppModelFixtures.chart("new-chart")))
        // The listener's profile is Hindi, so its personal section stays off an English-only Home.
        try await context.catalog.artists.complete(newArtist, with: .success(context.artistPage(newArtist.input, songs: [AppModelFixtures.track("new-radio", language: .hindi)])))
        await newTask.value
        XCTAssertEqual(context.model.homeSections.map(\.id), ["new-home"])
        XCTAssertEqual(context.model.charts.map(\.id), ["new-chart"])
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testLanguageEditBeforeReplacementTaskStartsCannotRestoreOldHome() async throws {
        let context = try makeContext(languages: [.hindi])
        let task = context.start { await $0.loadHome() }
        let discovery = try await context.catalog.discoveries.request(at: 0)
        let chart = try await context.charts.charts.request(at: 0)
        context.library.preferences.languages = [.english]
        try await context.catalog.discoveries.complete(discovery, with: .success([AppModelFixtures.section("old-hindi", language: .hindi)]))
        try await context.charts.charts.complete(chart, with: .success(AppModelFixtures.chart("old-hindi-chart", language: .hindi)))
        await task.value
        XCTAssertTrue(context.model.homeSections.isEmpty, "Preference changes must invalidate responses even before a replacement load starts")
        XCTAssertTrue(context.model.charts.isEmpty)
        XCTAssertNil(context.model.homeError)
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testReturningToCachedLanguagesInvalidatesOppositeLanguageRequest() async throws {
        let context = try makeContext()
        await context.catalog.discoveries.enqueue(.success([AppModelFixtures.section("cached-english")]))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("cached-english-chart")))
        await context.model.loadHome()
        context.library.preferences.languages = [.hindi]
        let oldTask = context.start { await $0.loadHome() }
        let oldDiscovery = try await context.catalog.discoveries.request(at: 1)
        let oldChart = try await context.charts.charts.request(at: 1)
        context.library.preferences.languages = [.english]
        await context.catalog.discoveries.enqueue(.success([AppModelFixtures.section("refreshed-english")]))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("refreshed-english-chart")))
        await context.model.loadHome()
        try await context.catalog.discoveries.complete(oldDiscovery, with: .success([AppModelFixtures.section("late-hindi", language: .hindi)]))
        try await context.charts.charts.complete(oldChart, with: .success(AppModelFixtures.chart("late-hindi-chart", language: .hindi)))
        await oldTask.value
        XCTAssertFalse(context.model.homeSections.isEmpty, "A cache hit must have usable content for its language set")
        XCTAssertTrue(context.model.homeSections.allSatisfy { $0.language == .english })
        XCTAssertTrue(context.model.charts.allSatisfy { $0.language == .english })
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testCancelledHomeDropsLateResponsesAndDoesNotMarkThemCached() async throws {
        let context = try makeContext()
        let task = context.start { await $0.loadHome() }
        let discovery = try await context.catalog.discoveries.request(at: 0)
        let chart = try await context.charts.charts.request(at: 0)
        task.cancel()
        try await AppModelFixtures.eventually { await context.catalog.discoveries.cancellations.contains(discovery.id) }
        try await AppModelFixtures.eventually { await context.charts.charts.cancellations.contains(chart.id) }
        try await context.catalog.discoveries.complete(discovery, with: .success([AppModelFixtures.section("cancelled")]))
        try await context.charts.charts.complete(chart, with: .failure(MusicServiceError.unavailable("Cancelled chart")))
        await task.value
        XCTAssertTrue(context.model.homeSections.isEmpty)
        XCTAssertTrue(context.model.charts.isEmpty)
        XCTAssertNil(context.model.homeError)
        XCTAssertFalse(context.model.isLoadingHome)

        await context.catalog.discoveries.enqueue(.success([AppModelFixtures.section("retry")]))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("retry-chart")))
        await context.model.loadHome()
        let requests = await context.catalog.discoveries.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(context.model.homeSections.map(\.id), ["retry"])
    }

    func testClearedHistoryCannotBeReintroducedByPendingPersonalRadio() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("forgotten-seed"))
        let task = context.start { await $0.loadHome() }
        let discovery = try await context.catalog.discoveries.request(at: 0)
        let chart = try await context.charts.charts.request(at: 0)
        let artist = try await context.catalog.artists.request(at: 0)
        context.player.flushListeningProgress()
        context.library.clearHistory()
        try await context.catalog.artists.complete(artist, with: .success(context.artistPage(artist.input, songs: [AppModelFixtures.track("forgotten-personal-pick")])))
        try await context.catalog.discoveries.complete(discovery, with: .success([AppModelFixtures.section("public-discovery")]))
        try await context.charts.charts.complete(chart, with: .success(AppModelFixtures.chart("weekly")))
        await task.value
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertEqual(context.model.homeSections.map(\.id), ["public-discovery"], "Cleared listening history must not reappear in personal mixes")
        XCTAssertEqual(context.model.charts.map(\.id), ["weekly"])
    }

    func testHomeRefreshAfterClearingHistoryRemovesCachedPersonalMixes() async throws {
        let context = try makeContext()
        let seed = context.seedListener(primary: AppModelFixtures.track("forgotten-seed"))
        await context.catalog.discoveries.enqueue(.success([AppModelFixtures.section("public-discovery")]))
        await context.catalog.artists.enqueue(.success(context.artistPage(seed.artistID ?? "", songs: [AppModelFixtures.track("personal-pick")])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("weekly")))
        await context.model.loadHome()
        XCTAssertTrue(context.model.homeSections.contains { $0.id == "personal.UCforgotten-seed" })
        context.library.clearHistory()
        await context.catalog.discoveries.enqueue(.success([AppModelFixtures.section("refreshed-public")]))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("weekly")))
        await context.model.loadHome(force: true)
        XCTAssertEqual(context.model.homeSections.map(\.id), ["refreshed-public"])
        let artists = await context.catalog.artists.requests
        XCTAssertEqual(artists.count, 1, "No new recommendations should be seeded from cleared history")
    }

    func testRestorationAndQueueEditsPersistSelectedOccurrenceWithoutInventingHistory() async throws {
        let a = AppModelFixtures.track("repeated")
        let b = AppModelFixtures.track("other")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [a, b, a], currentIndex: 2,
                                                                position: 42.75, repeatMode: .all))
        XCTAssertEqual(context.player.currentIndex, 2)
        XCTAssertEqual(context.player.position, 42.75)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertTrue(context.library.recentlyPlayed.isEmpty)
        context.player.moveQueue(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.queue, [a, a, b])
        context.player.removeFromQueue(at: 1)
        context.player.seek(to: 117.125)
        context.player.handleLifecycleCheckpoint()
        let reloaded = LibraryStore(directory: context.directory)
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertEqual(reloaded.playback.queue, [a, b])
        XCTAssertEqual(reloaded.playback.currentIndex, 0)
        XCTAssertEqual(reloaded.playback.position, 117.125)
        XCTAssertEqual(reloaded.playback.repeatMode, .all)
        XCTAssertTrue(reloaded.events.isEmpty)
        XCTAssertTrue(reloaded.recentlyPlayed.isEmpty)
        XCTAssertEqual(reloaded.summary(for: .week).seconds, 0)
        let requests = await context.streams.streams.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPlaySelectionUsesProviderIDRatherThanMetadataEquality() async throws {
        let context = try makeContext()
        let a = AppModelFixtures.track("a")
        let selected = AppModelFixtures.track("selected")
        let c = AppModelFixtures.track("c")
        var updated = selected
        updated.title = "Refreshed title from another surface"
        updated.albumTitle = "Newly loaded album metadata"
        context.model.play(updated, in: [a, selected, c])
        let request = try await context.streams.streams.request(at: 0)
        XCTAssertEqual(request.input.track.id, selected.id)
        XCTAssertFalse(request.input.forceRefresh)
        XCTAssertEqual(context.player.queue, [a, selected, c])
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.library.playback.queue, [a, selected, c])
        XCTAssertEqual(context.library.playback.currentIndex, 1)
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertTrue(context.library.recentlyPlayed.isEmpty)
        try await context.streams.streams.complete(request, with: .failure(MusicServiceError.unavailable("Offline resolution failure")))
        try await AppModelFixtures.eventually { context.player.errorMessage != nil }
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertTrue(context.library.recentlyPlayed.isEmpty)
        XCTAssertEqual(LibraryStore(directory: context.directory).playback.currentIndex, 1)
    }

    func testPlayMissingSelectionPrependsItAndEmptyMixKeepsTheCurrentQueue() async throws {
        let context = try makeContext()
        let selected = AppModelFixtures.track("selected")
        let others = [AppModelFixtures.track("a"), AppModelFixtures.track("b")]
        context.model.play(selected, in: others)
        XCTAssertEqual(context.player.queue, [selected] + others)
        XCTAssertEqual(context.player.currentIndex, 0)
        context.model.play([Track]())
        XCTAssertEqual(context.player.queue, [selected] + others)
        XCTAssertNotNil(context.model.toast)
        context.model.play(selected)
        XCTAssertEqual(context.player.queue, [selected])
        XCTAssertEqual(context.library.playback.queue, [selected])
        XCTAssertTrue(context.library.events.isEmpty)
    }

    func testShuffledMixKeepsDuplicateOccurrencesAndExplicitPlayRestoresInputOrder() async throws {
        let context = try makeContext()
        let a = AppModelFixtures.track("a")
        let b = AppModelFixtures.track("b")
        let c = AppModelFixtures.track("c")
        let tracks = [a, b, a, c]
        context.model.play(tracks, shuffle: true)
        XCTAssertTrue(context.player.shuffleEnabled)
        XCTAssertEqual(context.player.queue.map(\.id).sorted(), ["a", "a", "b", "c"])
        let selected = try XCTUnwrap(context.player.currentTrack)
        XCTAssertTrue(tracks.contains(selected))
        XCTAssertEqual(context.library.playback.queue[context.library.playback.currentIndex], selected)
        XCTAssertTrue(context.library.playback.shuffleEnabled)
        context.player.pause()
        context.player.seek(to: 42.5)
        let checkpoint = LibraryStore(directory: context.directory).playback
        XCTAssertEqual(checkpoint.originalQueue, tracks)
        let restored = try makeContext(snapshot: checkpoint)
        XCTAssertEqual(restored.player.queue, context.player.queue)
        XCTAssertEqual(restored.player.currentTrack, selected)
        XCTAssertFalse(restored.player.isPlaying)
        restored.player.toggleShuffle()
        XCTAssertEqual(restored.player.queue, tracks)
        XCTAssertEqual(restored.player.currentTrack, selected)
        XCTAssertEqual(restored.player.position, 42.5)
        context.model.play([c, b, a])
        XCTAssertFalse(context.player.shuffleEnabled)
        XCTAssertEqual(context.player.queue, [c, b, a])
        XCTAssertEqual(context.player.currentTrack, c)
        XCTAssertEqual(context.library.playback.currentIndex, 0)
        XCTAssertFalse(context.library.playback.shuffleEnabled)
        XCTAssertTrue(context.library.events.isEmpty)
    }

    func testInstalledCallbacksPersistActualDeltasAndPlayerResumePosition() async throws {
        let track = AppModelFixtures.track("listened")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [track], position: 80))
        let started = try XCTUnwrap(context.player.onTrackStarted)
        let progress = try XCTUnwrap(context.player.onListeningProgress)
        started(track)
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertEqual(context.library.recentlyPlayed.first?.position, 80)
        context.player.seek(to: 143.25)
        XCTAssertEqual(context.library.summary(for: .month).seconds, 0)
        let session = UUID()
        let began = Date().addingTimeInterval(-120)
        XCTAssertTrue(progress(track, session, began, 15))
        XCTAssertTrue(progress(track, session, began, 15))
        let event = try XCTUnwrap(context.library.events.first)
        XCTAssertEqual(context.library.events.count, 1)
        XCTAssertEqual(event.id, session)
        XCTAssertEqual(event.track, track)
        XCTAssertEqual(event.startedAt, began)
        XCTAssertEqual(event.listenedSeconds, 30)
        XCTAssertEqual(context.library.recentlyPlayed.first?.position, 143.25)
        context.player.handleLifecycleCheckpoint()
        let reloaded = LibraryStore(directory: context.directory)
        XCTAssertEqual(reloaded.summary(for: .week).seconds, 30)
        XCTAssertEqual(reloaded.summary(for: .week).plays, 1)
        XCTAssertEqual(reloaded.recentlyPlayed.first?.position, 143.25)
        XCTAssertEqual(reloaded.playback.position, 143.25)
        XCTAssertNil(reloaded.errorMessage)
    }

    func testInstalledCallbacksHonorCurrentPrivacySettingWhileSavingQueueState() async throws {
        let track = AppModelFixtures.track("listened")
        let privateTrack = AppModelFixtures.track("private")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [track], position: 20))
        let started = try XCTUnwrap(context.player.onTrackStarted)
        let progress = try XCTUnwrap(context.player.onListeningProgress)
        let session = UUID()
        let began = Date().addingTimeInterval(-120)
        XCTAssertTrue(progress(track, session, began, 20))
        let recent = try XCTUnwrap(context.library.recentlyPlayed.first)
        context.library.preferences.saveListeningHistory = false
        context.player.restore(PlaybackSnapshot(queue: [privateTrack], position: 91.5))
        started(privateTrack)
        XCTAssertTrue(progress(track, session, began, 50))
        XCTAssertTrue(progress(privateTrack, UUID(), began, 50))
        context.player.handleLifecycleCheckpoint()
        let reloaded = LibraryStore(directory: context.directory)
        XCTAssertFalse(reloaded.preferences.saveListeningHistory)
        XCTAssertEqual(reloaded.events.count, 1)
        XCTAssertEqual(reloaded.events.first?.listenedSeconds, 20)
        XCTAssertEqual(reloaded.recentlyPlayed.map(\.id), [track.id])
        XCTAssertEqual(reloaded.recentlyPlayed.first?.position, recent.position)
        XCTAssertEqual(try XCTUnwrap(reloaded.recentlyPlayed.first).playedAt.timeIntervalSince1970,
                       recent.playedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(reloaded.playback.queue, [privateTrack])
        XCTAssertEqual(reloaded.playback.position, 91.5)

        context.library.preferences.saveListeningHistory = true
        context.player.restore(PlaybackSnapshot(queue: [track], position: 30))
        XCTAssertTrue(progress(track, session, began, 10))
        XCTAssertEqual(context.library.summary(for: .week).seconds, 30)
        XCTAssertEqual(context.library.summary(for: .week).plays, 1)
        XCTAssertEqual(context.library.recentlyPlayed.map(\.id), [track.id])
    }

    func testRejectedListeningCallbackIsNotAcknowledgedOrMaskedByARecentWrite() throws {
        let track = AppModelFixtures.track("listened")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [track]))
        let progress = try XCTUnwrap(context.player.onListeningProgress)
        let session = UUID()
        let began = Date().addingTimeInterval(-120)
        XCTAssertTrue(context.library.recordListening(track: track, sessionID: session, startedAt: began, seconds: 20))
        let url = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let saved = try Data(contentsOf: url)

        XCTAssertFalse(progress(AppModelFixtures.track("wrong-session-song"), session, began, 10))
        XCTAssertNotNil(context.library.errorMessage)
        XCTAssertEqual(context.library.events.count, 1)
        XCTAssertEqual(context.library.events.first?.track, track)
        XCTAssertEqual(context.library.events.first?.listenedSeconds, 20)
        XCTAssertTrue(context.library.recentlyPlayed.isEmpty, "A successful recent write would hide the failed listening checkpoint")
        XCTAssertEqual(try Data(contentsOf: url), saved)

        XCTAssertTrue(progress(track, session, began, 10))
        XCTAssertNil(context.library.errorMessage)
        XCTAssertEqual(context.library.events.first?.listenedSeconds, 30)
        XCTAssertEqual(context.library.recentlyPlayed.first?.track, track)
    }

    func testLocalAudioDrivesModelHistoryAndPauseOrSeekDoesNotAddListening() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 10)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = try makeContext(resolver: PlaybackFileResolver(url: url, duration: 10))
        let track = AppModelFixtures.track("local-audio")
        context.model.play(track)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 1.1 }
        context.player.pause()
        let event = try XCTUnwrap(context.library.events.first)
        XCTAssertEqual(event.track.id, track.id)
        XCTAssertGreaterThan(event.listenedSeconds, 0.5)
        XCTAssertLessThan(event.listenedSeconds, 4)
        XCTAssertEqual(context.library.events.count, 1)
        XCTAssertEqual(context.library.recentlyPlayed.map(\.id), [track.id])
        let before = context.library.summary(for: .week).seconds
        try await Task.sleep(for: .milliseconds(350))
        context.player.flushListeningProgress()
        context.player.seek(to: 7)
        try await Task.sleep(for: .milliseconds(250))
        context.player.flushListeningProgress()
        XCTAssertEqual(context.library.summary(for: .week).seconds, before, accuracy: 0.05)
        XCTAssertEqual(context.library.playback.position, 7, accuracy: 0.1)
        context.player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 7.7 }
        context.player.pause()
        XCTAssertEqual(context.library.events.count, 1)
        XCTAssertEqual(context.library.events.first?.id, event.id)
        XCTAssertGreaterThan(context.library.summary(for: .week).seconds, before)
        XCTAssertLessThan(context.library.summary(for: .week).seconds, 5)
        let reloaded = LibraryStore(directory: context.directory)
        XCTAssertEqual(reloaded.events.first?.id, event.id)
        XCTAssertEqual(reloaded.summary(for: .week).seconds, context.library.summary(for: .week).seconds, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(reloaded.recentlyPlayed.first).position, context.player.position, accuracy: 0.1)
        XCTAssertEqual(reloaded.playback.position, context.player.position, accuracy: 0.1)
    }

    func testPrivateLocalAudioKeepsResumeStateWithoutRecordingRealPlaybackCallbacks() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 10)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = try makeContext(resolver: PlaybackFileResolver(url: url, duration: 10))
        context.library.preferences.saveListeningHistory = false
        let track = AppModelFixtures.track("private-local-audio")
        context.model.play(track)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 1.1 }
        context.player.pause()
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertTrue(context.library.recentlyPlayed.isEmpty)
        XCTAssertEqual(context.library.summary(for: .year).seconds, 0)
        let reloaded = LibraryStore(directory: context.directory)
        XCTAssertFalse(reloaded.preferences.saveListeningHistory)
        XCTAssertEqual(reloaded.playback.queue, [track])
        XCTAssertGreaterThan(reloaded.playback.position, 1)
        XCTAssertTrue(reloaded.events.isEmpty)
        XCTAssertTrue(reloaded.recentlyPlayed.isEmpty)

        context.library.preferences.saveListeningHistory = true
        let resumePosition = context.player.position
        context.player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > resumePosition + 0.7 }
        context.player.pause()
        XCTAssertEqual(context.library.events.count, 1)
        XCTAssertEqual(context.library.recentlyPlayed.map(\.id), [track.id])
        XCTAssertGreaterThan(context.library.summary(for: .week).seconds, 0)
        XCTAssertLessThan(context.library.summary(for: .week).seconds, context.player.position - 0.5,
                          "Turning history back on must not backfill private listening time")
    }

    // MARK: - Autoplay and artist credits

    func testAutoplaySelectionDropsQueuedDislikedAndOtherVersionsOfTheSameSong() {
        let seed = Track(id: "seed0000001", title: "Six Days (Remix) (feat. Mos Def)", artists: ["DJ Shadow"], isAudioRecording: true)
        let queued = Track(id: "queue000001", title: "Nobody Speak", artists: ["DJ Shadow"], isAudioRecording: true)
        let radio = [
            Track(id: "radio000001", title: "Six Days", artists: ["DJ Shadow"], isAudioRecording: true),
            Track(id: "radio000002", title: "Six Days - Radio Edit", artists: ["DJ Shadow"], isAudioRecording: true),
            Track(id: "radio000003", title: "Hey Baby (feat. Mos Def)", artists: ["Stephen Marley"], isAudioRecording: true),
            Track(id: "radio000004", title: "Nobody Speak (Live)", artists: ["DJ Shadow"], isAudioRecording: true),
            Track(id: "disliked001", title: "Ms. Fat Booty", artists: ["Mos Def"], isAudioRecording: true),
            Track(id: "radio000005", title: "Hey Baby", artists: ["No Doubt"], isAudioRecording: true),
            Track(id: "video000001", title: "Clint Eastwood", artists: ["Gorillaz"], isAudioRecording: false),
            Track(id: "radio000006", title: "Midnight In A Perfect World", artists: ["DJ Shadow"], isAudioRecording: true),
            Track(id: seed.id, title: seed.title, artists: ["DJ Shadow"], isAudioRecording: true),
        ]
        let selected = MusicAppModel.autoplaySelection(from: radio, queue: [seed, queued], disliked: ["disliked001"])
        XCTAssertEqual(selected.map(\.id), ["radio000003", "radio000006"],
                       "Versions of queued songs, a repeated title, a disliked song, a video row, and the seed itself never enter autoplay")
        XCTAssertEqual(MusicAppModel.autoplaySelection(from: radio, queue: [], disliked: [], limit: 1).map(\.id), ["radio000001"])
    }

    func testAutoplayAsksTheProviderRadioForTheEndingSongWithoutLanguageTargeting() async throws {
        let context = try makeContext()
        let seed = AppModelFixtures.track("seed")
        let neighbor = AppModelFixtures.track("neighbor", language: .hindi)
        var remix = AppModelFixtures.track("remix")
        remix.title = "\(seed.title) (Remix)"
        await context.catalog.autoplayRadios.enqueue(.success([remix, neighbor]))

        let continuation = await context.player.onQueueExhausted?(seed) ?? []
        let requests = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(requests.map(\.input.id), [seed.id])
        let radioRequests = await context.catalog.radios.requests
        XCTAssertTrue(radioRequests.isEmpty, "Autoplay must not use the language-targeted Home mix")
        XCTAssertEqual(continuation.map(\.id), [neighbor.id], "The seed's own remix is not a continuation")
    }

    func testOpenArtistUsesTheLinkedPageOrResolvesATitleCreditByName() async throws {
        let context = try makeContext()
        let model = context.model
        model.selectedTab = .library
        model.isPlayerPresented = true

        await model.openArtist(ArtistCredit(name: "Kanye West", id: "UCRY5dYsbIN5TylSbd7gVnZg"))
        XCTAssertEqual(model.navigationPaths[.library]?.map(\.id), ["UCRY5dYsbIN5TylSbd7gVnZg"])
        XCTAssertEqual(model.navigationPaths[.library]?.first?.kind, .artist)
        XCTAssertFalse(model.isPlayerPresented, "The page must be visible once the player closes")
        let searchesSoFar = await context.catalog.searches.requests
        XCTAssertTrue(searchesSoFar.isEmpty, "A linked credit needs no lookup")

        let match = MusicCollection(id: "UCtpain00000000000000001", title: "T-Pain", kind: .artist)
        await context.catalog.searches.enqueue(.success(CatalogPage(collections: [
            MusicCollection(id: "UCother0000000000000001", title: "T-Pain Tribute Band", kind: .artist), match,
        ])))
        await model.openArtist(ArtistCredit(name: "T-Pain"))
        let lookups = await context.catalog.searches.requests
        XCTAssertEqual(lookups.map(\.input), [AppModelSearchRequest(query: "T-Pain", filter: .artists, continuation: nil)])
        XCTAssertEqual(model.navigationPaths[.library]?.last?.id, match.id)
        XCTAssertFalse(model.isArtistLookupPending)

        await context.catalog.searches.enqueue(.success(CatalogPage(collections: [])))
        await model.openArtist(ArtistCredit(name: "Al Be Back"))
        XCTAssertEqual(model.selectedTab, .search, "Without a close artist match, search shows what the catalog has")
        XCTAssertEqual(model.searchQuery, "Al Be Back")
        XCTAssertEqual(model.searchFilter, .songs)
    }

    private func makeContext(languages: Set<MusicLanguage> = [.english], snapshot: PlaybackSnapshot = PlaybackSnapshot(),
                             resolver: (any StreamResolving)? = nil) throws -> AppModelTestContext {
        let context = try AppModelTestContext(languages: languages, snapshot: snapshot, resolver: resolver)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
