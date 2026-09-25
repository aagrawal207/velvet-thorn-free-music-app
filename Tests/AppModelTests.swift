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
        let discovery = try await context.catalog.autoplayRadios.request(at: 0)
        let artist = try await context.catalog.artists.request(at: 0)
        let chart = try await context.charts.charts.request(at: 0)
        XCTAssertEqual(discovery.input.id, seed.id)
        XCTAssertEqual(chart.input, .hindi, "Learned listening selects chart scope ahead of the legacy fallback")
        XCTAssertEqual(artist.input, seed.artistID)
        let personal = AppModelFixtures.track("personal", language: .hindi)
        try await context.catalog.artists.complete(artist, with: .success(context.artistPage(artist.input, songs: [personal])))
        try await AppModelFixtures.eventually { context.model.homeSections.contains { $0.tracks == [personal] } }
        XCTAssertTrue(context.model.isLoadingHome)

        let hindi = RecommendationFixtures.track("hindi", artist: "Hindi performer", language: .hindi)
        let english = RecommendationFixtures.track("english", artist: "English performer", language: .english)
        var unknown = AppModelFixtures.track("unknown")
        unknown.language = nil
        unknown.artists = ["Unclassified performer"]
        let unverified = libraryTestTrack("unverified")
        let blocked = AppModelFixtures.track("late-dislike", language: .hindi)
        context.model.toggleDislike(blocked)
        try await context.catalog.autoplayRadios.complete(discovery, with: .success([hindi, english, unknown, unverified, blocked]))
        try await AppModelFixtures.eventually { context.model.homeSections.count == 2 }
        XCTAssertTrue(context.model.isLoadingHome)
        XCTAssertEqual(context.model.homeSections.first?.tracks, [personal])
        let discovered = try XCTUnwrap(context.model.homeSections.first { $0.id == "discovery.language.hi" })
        XCTAssertEqual(Set(discovered.tracks.map(\.id)), [hindi.id, english.id, unknown.id],
                       "Unknown and less-preferred audio stays eligible; late dislikes and unverified audio do not")
        XCTAssertNil(discovered.tracks.first { $0.id == unknown.id }?.language)
        let hindiChart = AppModelFixtures.chart("weekly-hindi", language: .hindi)
        try await context.charts.charts.complete(chart, with: .success(hindiChart))
        await task.value
        XCTAssertEqual(context.model.homeSections.map(\.id), ["personal.UChindi-seed", "discovery.language.hi"])
        XCTAssertEqual(context.model.charts.map(\.id), [hindiChart.id])
        XCTAssertEqual(context.model.charts.first?.periodStart, hindiChart.periodStart)
        XCTAssertEqual(context.model.charts.first?.periodEnd, hindiChart.periodEnd)
        XCTAssertEqual(context.model.charts.first?.source, hindiChart.source)
        XCTAssertNil(context.model.homeError)
        XCTAssertFalse(context.model.isLoadingHome)
        let chartRequests = await context.charts.charts.requests
        let legacyDiscovery = await context.catalog.discoveries.requests
        let targetedRadio = await context.catalog.radios.requests
        XCTAssertEqual(chartRequests.count, 1)
        XCTAssertTrue(legacyDiscovery.isEmpty && targetedRadio.isEmpty)
    }

    func testDiscoveryFailureKeepsSuccessfulChartAndPersonalRadio() async throws {
        let context = try makeContext()
        let seed = context.seedListener(primary: AppModelFixtures.track("seed"))
        await context.catalog.autoplayRadios.enqueue(.failure(MusicServiceError.unavailable("Discovery failed")))
        await context.catalog.searches.enqueue(.failure(MusicServiceError.unavailable("Discovery failed")))
        await context.catalog.artists.enqueue(.success(context.artistPage(seed.artistID ?? "", songs: [AppModelFixtures.track("personal")])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("weekly")))
        await context.model.loadHome()
        XCTAssertEqual(context.model.homeSections.flatMap(\.tracks).map(\.id), ["personal"])
        XCTAssertEqual(context.model.charts.map(\.id), ["weekly"])
        XCTAssertEqual(context.model.homeError, "Discovery failed")
        XCTAssertFalse(context.model.isLoadingHome)

        let retry = AppModelFixtures.track("retry")
        await context.catalog.autoplayRadios.enqueue(.success([retry]))
        await context.catalog.artists.enqueue(.failure(MusicServiceError.unavailable("Artist unavailable")))
        await context.charts.charts.enqueue(.failure(MusicServiceError.unavailable("Chart unavailable")))
        await context.model.loadHome()
        let discoveries = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(discoveries.count, 2, "A failed discovery must remain retryable without force")
        XCTAssertEqual(context.model.homeSections.map(\.id), ["personal.UCseed", "discovery.language.en"])
        XCTAssertEqual(context.model.homeSections.last?.tracks, [retry])
        XCTAssertEqual(context.model.charts.map(\.id), ["weekly"])
        XCTAssertNil(context.model.homeError)
        let searches = await context.catalog.searches.requests
        XCTAssertEqual(searches.map(\.input), [AppModelSearchRequest(query: "English songs", filter: .songs, continuation: nil)])
    }

    func testFailedForcedHomeRefreshPreservesPreviouslyLoadedContent() async throws {
        let context = try makeContext()
        let seed = context.seedListener(primary: AppModelFixtures.track("seed"))
        let cached = AppModelFixtures.track("cached")
        await context.catalog.autoplayRadios.enqueue(.success([cached]))
        await context.catalog.artists.enqueue(.success(context.artistPage(seed.artistID ?? "", songs: [AppModelFixtures.track("personal")])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("cached-chart")))
        await context.model.loadHome()
        await context.catalog.autoplayRadios.enqueue(.failure(MusicServiceError.unavailable("Refresh failed")))
        await context.catalog.searches.enqueue(.failure(MusicServiceError.unavailable("Refresh failed")))
        await context.catalog.artists.enqueue(.failure(MusicServiceError.unavailable("Artist failed")))
        await context.charts.charts.enqueue(.failure(MusicServiceError.unavailable("Chart failed")))
        await context.model.loadHome(force: true)
        XCTAssertEqual(context.model.homeSections.map(\.id), ["personal.UCseed", "discovery.language.en"])
        XCTAssertEqual(context.model.homeSections.last?.tracks, [cached])
        XCTAssertEqual(context.model.charts.map(\.id), ["cached-chart"])
        XCTAssertEqual(context.model.homeError, "Refresh failed")
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testPartialLanguageDiscoveryFailureKeepsAvailableUnknownAudioAndItsChart() async throws {
        let context = try makeContext()
        context.model.setLanguageNudge(.more, for: .hindi)
        let task = context.start { await $0.loadHome() }
        let searches = [try await context.catalog.searches.request(at: 0), try await context.catalog.searches.request(at: 1)]
        let charts = [try await context.charts.charts.request(at: 0), try await context.charts.charts.request(at: 1)]
        var unknown = AppModelFixtures.track("unknown-audio")
        unknown.language = nil
        for request in searches {
            XCTAssertEqual(request.input.filter, .songs)
            XCTAssertNil(request.input.continuation)
            let result: Result<CatalogPage, any Error> = request.input.query == "English songs"
                ? .success(CatalogPage(tracks: [unknown, libraryTestTrack("unverified")]))
                : .failure(MusicServiceError.unavailable("Hindi source failed"))
            try await context.catalog.searches.complete(request, with: result)
        }
        for request in charts {
            let result: Result<ChartSnapshot, any Error> = request.input == .english
                ? .success(AppModelFixtures.chart("available-chart")) : .failure(MusicServiceError.unavailable("Optional chart failed"))
            try await context.charts.charts.complete(request, with: result)
        }
        await task.value
        XCTAssertEqual(Set(searches.map(\.input.query)), ["Hindi songs", "English songs"])
        XCTAssertEqual(context.model.homeSections.map(\.id), ["discovery.language.en"])
        XCTAssertEqual(context.model.homeSections.first?.tracks, [unknown])
        XCTAssertNil(context.model.homeSections.first?.tracks.first?.language)
        XCTAssertEqual(context.model.charts.map(\.id), ["available-chart"])
        XCTAssertNil(context.model.homeError)
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testNewNudgeLoadRejectsEveryOldHomeResponseAndKeepsItsSpinner() async throws {
        let context = try makeContext(languages: [.hindi])
        let seed = context.seedListener(primary: AppModelFixtures.track("hindi-seed", language: .hindi), language: .hindi)
        let oldTask = context.start { await $0.loadHome(force: true) }
        let oldDiscovery = try await context.catalog.autoplayRadios.request(at: 0)
        let oldChart = try await context.charts.charts.request(at: 0)
        let oldArtist = try await context.catalog.artists.request(at: 0)
        let oldKey = context.model.listeningLanguageProfile.requestKey
        context.model.setLanguageNudge(.more, for: .english)
        XCTAssertNotEqual(context.model.listeningLanguageProfile.requestKey, oldKey)
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences.languageNudges[.english], .more)
        let newTask = context.start { await $0.loadHome(force: true) }
        let newDiscovery = try await context.catalog.autoplayRadios.request(at: 1)
        let newSearch = try await context.catalog.searches.request(at: 0)
        let newCharts = [try await context.charts.charts.request(at: 1), try await context.charts.charts.request(at: 2)]
        let newArtist = try await context.catalog.artists.request(at: 1)
        XCTAssertEqual(newDiscovery.input.id, seed.id)
        XCTAssertEqual(newSearch.input, AppModelSearchRequest(query: "English songs", filter: .songs, continuation: nil))
        XCTAssertEqual(Set(newCharts.map(\.input)), [.hindi, .english])
        try await context.catalog.artists.complete(oldArtist, with: .success(context.artistPage(oldArtist.input, songs: [AppModelFixtures.track("old-radio", language: .hindi)])))
        try await context.catalog.autoplayRadios.complete(oldDiscovery, with: .success([AppModelFixtures.track("old-home", language: .hindi)]))
        try await context.charts.charts.complete(oldChart, with: .success(AppModelFixtures.chart("old-chart", language: .hindi)))
        await oldTask.value
        XCTAssertTrue(context.model.homeSections.isEmpty)
        XCTAssertTrue(context.model.charts.isEmpty)
        XCTAssertTrue(context.model.isLoadingHome)
        XCTAssertNil(context.model.homeError)

        let hindi = AppModelFixtures.track("new-hindi", language: .hindi)
        let english = AppModelFixtures.track("new-english")
        let personal = AppModelFixtures.track("new-personal", language: .hindi)
        try await context.catalog.autoplayRadios.complete(newDiscovery, with: .success([hindi]))
        try await context.catalog.searches.complete(newSearch, with: .success(CatalogPage(tracks: [english])))
        for chart in newCharts {
            try await context.charts.charts.complete(chart, with: .success(AppModelFixtures.chart("new-\(chart.input.rawValue)", language: chart.input)))
        }
        try await context.catalog.artists.complete(newArtist, with: .success(context.artistPage(newArtist.input, songs: [personal])))
        await newTask.value
        XCTAssertEqual(context.model.homeSections.map(\.id), ["personal.UChindi-seed", "discovery.language.en", "discovery.language.hi"])
        XCTAssertEqual(Set(context.model.homeSections.flatMap(\.tracks).map(\.id)), [hindi.id, english.id, personal.id])
        XCTAssertEqual(Set(context.model.charts.map(\.id)), ["new-hindi", "new-english"])
        XCTAssertNil(context.model.homeError)
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testDirectNudgeEditBeforeReplacementLoadRejectsOldHomeFailure() async throws {
        let context = try makeContext()
        let task = context.start { await $0.loadHome() }
        let discovery = try await context.catalog.searches.request(at: 0)
        let chart = try await context.charts.charts.request(at: 0)
        let oldKey = context.model.listeningLanguageProfile.requestKey
        context.library.preferences.languageNudges[.hindi] = .more
        XCTAssertNotEqual(context.model.listeningLanguageProfile.requestKey, oldKey)
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences.languageNudges[.hindi], .more)
        try await context.catalog.searches.complete(discovery, with: .failure(MusicServiceError.unavailable("Obsolete failure")))
        try await context.charts.charts.complete(chart, with: .success(AppModelFixtures.chart("old-chart")))
        await task.value
        XCTAssertTrue(context.model.homeSections.isEmpty, "Preference changes must invalidate responses even before a replacement load starts")
        XCTAssertTrue(context.model.charts.isEmpty)
        XCTAssertNil(context.model.homeError)
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testReturningToTheOriginalNudgeCannotReviveOldHomeWork() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let originalKey = context.model.listeningLanguageProfile.requestKey
        let task = context.start { await $0.loadHome() }
        let radio = try await context.catalog.autoplayRadios.request(at: 0)
        let artist = try await context.catalog.artists.request(at: 0)
        let chart = try await context.charts.charts.request(at: 0)
        context.model.setLanguageNudge(.less, for: .english)
        context.model.setLanguageNudge(.automatic, for: .english)
        XCTAssertEqual(context.model.listeningLanguageProfile.requestKey, originalKey)
        try await context.catalog.autoplayRadios.complete(radio, with: .success([AppModelFixtures.track("obsolete-discovery")]))
        try await context.catalog.artists.complete(artist, with: .success(context.artistPage(artist.input, songs: [AppModelFixtures.track("obsolete-personal")])))
        try await context.charts.charts.complete(chart, with: .success(AppModelFixtures.chart("obsolete-chart")))
        await task.value
        XCTAssertTrue(context.model.homeSections.isEmpty)
        XCTAssertTrue(context.model.charts.isEmpty)
        XCTAssertNil(context.model.homeError)
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testColdFallbackChangesRejectLateHomeAndRefreshTheRestoredLanguage() async throws {
        let context = try makeContext()
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [AppModelFixtures.track("cached-english")])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("cached-english-chart")))
        await context.model.loadHome()
        XCTAssertFalse(context.model.listeningLanguageProfile.isLearned)
        context.library.preferences.languages = [.hindi]
        let oldTask = context.start { await $0.loadHome() }
        let oldDiscovery = try await context.catalog.searches.request(at: 1)
        let oldChart = try await context.charts.charts.request(at: 1)
        XCTAssertEqual(oldDiscovery.input.query, "Hindi songs")
        context.library.preferences.languages = [.english]
        let fresh = AppModelFixtures.track("refreshed-english")
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [fresh])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("refreshed-english-chart")))
        await context.model.loadHome()
        try await context.catalog.searches.complete(oldDiscovery, with: .success(CatalogPage(tracks: [AppModelFixtures.track("late-hindi", language: .hindi)])))
        try await context.charts.charts.complete(oldChart, with: .success(AppModelFixtures.chart("late-hindi-chart", language: .hindi)))
        await oldTask.value
        XCTAssertEqual(context.model.homeSections.map(\.id), ["discovery.language.en"])
        XCTAssertEqual(context.model.homeSections.first?.tracks, [fresh])
        XCTAssertEqual(context.model.charts.map(\.id), ["refreshed-english-chart"])
        XCTAssertFalse(context.model.isLoadingHome)
        await context.model.loadHome()
        let requests = await context.catalog.searches.requests
        XCTAssertEqual(requests.map(\.input.query), ["English songs", "Hindi songs", "English songs"],
                       "The final unchanged load reuses only the current fallback's cache")
    }

    func testCancelledHomeDropsLateResponsesAndDoesNotMarkThemCached() async throws {
        let context = try makeContext()
        let task = context.start { await $0.loadHome() }
        let discovery = try await context.catalog.searches.request(at: 0)
        let chart = try await context.charts.charts.request(at: 0)
        task.cancel()
        try await AppModelFixtures.eventually { await context.catalog.searches.cancellations.contains(discovery.id) }
        try await AppModelFixtures.eventually { await context.charts.charts.cancellations.contains(chart.id) }
        try await context.catalog.searches.complete(discovery, with: .success(CatalogPage(tracks: [AppModelFixtures.track("cancelled")])))
        try await context.charts.charts.complete(chart, with: .failure(MusicServiceError.unavailable("Cancelled chart")))
        await task.value
        XCTAssertTrue(context.model.homeSections.isEmpty)
        XCTAssertTrue(context.model.charts.isEmpty)
        XCTAssertNil(context.model.homeError)
        XCTAssertFalse(context.model.isLoadingHome)

        let retry = AppModelFixtures.track("retry")
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [retry])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("retry-chart")))
        await context.model.loadHome()
        let requests = await context.catalog.searches.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(context.model.homeSections.map(\.id), ["discovery.language.en"])
        XCTAssertEqual(context.model.homeSections.first?.tracks, [retry])
    }

    func testClearedHistoryCannotBeReintroducedByPendingPersonalRadio() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("forgotten-seed"))
        let task = context.start { await $0.loadHome() }
        let discovery = try await context.catalog.autoplayRadios.request(at: 0)
        let chart = try await context.charts.charts.request(at: 0)
        let artist = try await context.catalog.artists.request(at: 0)
        context.player.flushListeningProgress()
        context.library.clearHistory()
        try await context.catalog.artists.complete(artist, with: .success(context.artistPage(artist.input, songs: [AppModelFixtures.track("forgotten-personal-pick")])))
        try await context.catalog.autoplayRadios.complete(discovery, with: .success([AppModelFixtures.track("forgotten-discovery")]))
        try await context.charts.charts.complete(chart, with: .success(AppModelFixtures.chart("weekly")))
        await task.value
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertTrue(context.model.homeSections.isEmpty, "Both discovery and artist sections were derived from the retired history")
        XCTAssertTrue(context.model.charts.isEmpty)
        XCTAssertFalse(context.model.hasListeningProfile)
        XCTAssertFalse(context.model.listeningLanguageProfile.isLearned)
        let fresh = AppModelFixtures.track("cold-discovery")
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [fresh])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("fresh-weekly")))
        await context.model.loadHome()
        XCTAssertEqual(context.model.homeSections.map(\.id), ["discovery.language.en"])
        XCTAssertEqual(context.model.homeSections.first?.tracks, [fresh])
        let artists = await context.catalog.artists.requests
        let radios = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(artists.count, 1)
        XCTAssertEqual(radios.count, 1)
    }

    func testHomeRefreshAfterClearingHistoryRemovesCachedPersonalMixes() async throws {
        let context = try makeContext()
        let seed = context.seedListener(primary: AppModelFixtures.track("forgotten-seed"))
        await context.catalog.autoplayRadios.enqueue(.success([AppModelFixtures.track("public-discovery")]))
        await context.catalog.artists.enqueue(.success(context.artistPage(seed.artistID ?? "", songs: [AppModelFixtures.track("personal-pick")])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("weekly")))
        await context.model.loadHome()
        XCTAssertTrue(context.model.homeSections.contains { $0.id == "personal.UCforgotten-seed" })
        context.library.clearHistory()
        XCTAssertTrue(context.model.homeSections.isEmpty, "Clearing history immediately retires cached derived sections")
        let fresh = AppModelFixtures.track("refreshed-public")
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [fresh])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("weekly")))
        await context.model.loadHome(force: true)
        XCTAssertEqual(context.model.homeSections.map(\.id), ["discovery.language.en"])
        XCTAssertEqual(context.model.homeSections.first?.tracks, [fresh])
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
        XCTAssertFalse(context.model.isContinuingAutoplay)
        XCTAssertNil(context.model.autoplayContinuationError, "A thin batch with nothing else to borrow is still a success")
    }

    func testAutoplayFallbackSeedPrefersRecentListenerChoicesAndSkipsDislikesAndVideos() {
        let a = AppModelFixtures.track("a")
        let b = AppModelFixtures.track("b")
        let c = AppModelFixtures.track("c")
        let d = AppModelFixtures.track("d")
        let last = AppModelFixtures.track("last")
        var video = AppModelFixtures.track("video")
        video.isAudioRecording = false
        let queue = [a, b, video, c, d, last]
        func seed(_ queue: [Track], recents: [String] = [], autoplay: Set<String> = [], disliked: Set<String> = []) -> String? {
            AutoplayContinuation.fallbackSeed(queue: queue, after: last, recentIDs: recents, autoplayIDs: autoplay, disliked: disliked)?.id
        }
        XCTAssertEqual(seed(queue, recents: [last.id, b.id, d.id]), b.id, "The most recently played song other than the ending one wins")
        XCTAssertEqual(seed(queue), d.id, "Without history the nearest earlier song seeds")
        XCTAssertEqual(seed(queue, disliked: [d.id]), c.id)
        XCTAssertEqual(seed(queue, recents: [d.id], autoplay: [c.id, d.id]), b.id, "Autoplay's own additions yield to listener choices")
        XCTAssertEqual(seed([c, d, last], autoplay: [c.id, d.id]), d.id, "Autoplay additions seed only when nothing else remains")
        XCTAssertNil(seed([last]))
        XCTAssertNil(seed([video, last]))
    }

    func testAutoplayFailureClassesSeparateCooldownsFromOutagesAndExhaustion() {
        XCTAssertTrue(AutoplayContinuation.allowsFreshRetry(MusicServiceError.network("Offline")))
        XCTAssertTrue(AutoplayContinuation.allowsFreshRetry(MusicServiceError.unavailable("Down")))
        XCTAssertTrue(AutoplayContinuation.allowsFreshRetry(URLError(.timedOut)))
        XCTAssertFalse(AutoplayContinuation.allowsFreshRetry(MusicServiceError.rateLimited))
        XCTAssertFalse(AutoplayContinuation.allowsFreshRetry(CancellationError()))
        XCTAssertFalse(AutoplayContinuation.allowsFreshRetry(AppModelTestFailure.timedOut("Unknown")))
        XCTAssertTrue(AutoplayContinuation.endsAttempts(MusicServiceError.rateLimited))
        XCTAssertFalse(AutoplayContinuation.endsAttempts(MusicServiceError.unavailable("Down")))
        XCTAssertEqual(AutoplayContinuation.failure(primarySucceeded: true, errors: []), .empty)
        XCTAssertEqual(AutoplayContinuation.failure(primarySucceeded: true, errors: [MusicServiceError.network("Offline")]), .empty,
                       "A borrowed seed failing does not turn exhaustion into an outage")
        XCTAssertEqual(AutoplayContinuation.failure(primarySucceeded: false, errors: [MusicServiceError.network("Offline")]), .unreachable)
        XCTAssertEqual(AutoplayContinuation.failure(primarySucceeded: false,
                                                    errors: [MusicServiceError.network("Offline"), MusicServiceError.rateLimited]), .busy)
        XCTAssertEqual(AutoplayContinuation.Failure.empty.message, "Couldn’t find more songs to play.")
        XCTAssertEqual(AutoplayContinuation.Failure.busy.message, "Autoplay paused because the music service is busy. Try again in a moment.")
    }

    func testThinAutoplayBatchBorrowsTheMostRecentlyPlayedQueueSongAsASecondSeed() async throws {
        let a = AppModelFixtures.track("a")
        let b = AppModelFixtures.track("b")
        let c = AppModelFixtures.track("c")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [a, b, c], currentIndex: 2))
        context.library.recordRecent(track: c, position: 0)
        context.library.recordRecent(track: a, position: 12)
        let close = AppModelFixtures.track("close")
        var liveB = AppModelFixtures.track("b-live")
        liveB.title = "\(b.title) (Live)"
        let borrowedOne = AppModelFixtures.track("borrowed-one")
        let borrowedTwo = AppModelFixtures.track("borrowed-two")
        let continuation = Task { await context.player.onQueueExhausted?(c) ?? [] }
        let first = try await context.catalog.autoplayRadios.request(at: 0)
        XCTAssertEqual(first.input.id, c.id)
        XCTAssertTrue(context.model.isContinuingAutoplay)
        try await context.catalog.autoplayRadios.complete(first, with: .success([close, liveB, b]))
        let second = try await context.catalog.autoplayRadios.request(at: 1)
        XCTAssertEqual(second.input.id, a.id, "The listener's most recently played song other than the ending one seeds the second attempt")
        try await context.catalog.autoplayRadios.complete(second, with: .success([borrowedOne, close, c, borrowedTwo]))
        let additions = await continuation.value
        XCTAssertEqual(additions.map(\.id), [close.id, borrowedOne.id, borrowedTwo.id],
                       "The ending song's neighbors lead; the borrowed radio fills in without repeating queued or already chosen songs")
        let refreshes = await context.catalog.radioRefreshRequests
        XCTAssertEqual(refreshes.map(\.seed.id), [a.id])
        XCTAssertEqual(refreshes.map(\.forceRefresh), [false], "A borrowed seed may reuse a cached radio")
        XCTAssertFalse(context.model.isContinuingAutoplay)
        XCTAssertNil(context.model.autoplayContinuationError)
    }

    func testAutoplayRefreshesTheEndingSongOnceAfterATransientFailureButNotDuringACooldown() async throws {
        let seed = AppModelFixtures.track("seed")
        let neighbor = AppModelFixtures.track("neighbor")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [seed]))
        let transient = Task { await context.player.onQueueExhausted?(seed) ?? [] }
        let first = try await context.catalog.autoplayRadios.request(at: 0)
        try await context.catalog.autoplayRadios.complete(first, with: .failure(MusicServiceError.network("Offline")))
        let refresh = try await context.catalog.autoplayRadios.request(at: 1)
        XCTAssertEqual(refresh.input.id, seed.id, "With nothing to borrow, the ending song itself is asked again")
        try await context.catalog.autoplayRadios.complete(refresh, with: .success([neighbor]))
        let additions = await transient.value
        XCTAssertEqual(additions, [neighbor])
        XCTAssertNil(context.model.autoplayContinuationError)
        var refreshes = await context.catalog.radioRefreshRequests
        XCTAssertEqual(refreshes.map(\.forceRefresh), [true], "The retry bypasses a cached radio, not the provider cooldown")

        let cooling = Task { await context.player.onQueueExhausted?(seed) ?? [] }
        let limited = try await context.catalog.autoplayRadios.request(at: 2)
        try await context.catalog.autoplayRadios.complete(limited, with: .failure(MusicServiceError.rateLimited))
        let nothing = await cooling.value
        XCTAssertTrue(nothing.isEmpty)
        XCTAssertEqual(context.model.autoplayContinuationError, "Autoplay paused because the music service is busy. Try again in a moment.")
        XCTAssertFalse(context.model.isContinuingAutoplay)
        let requests = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(requests.count, 3, "A cooldown ends the attempt; a retry would fail on the device before reaching the provider")
        refreshes = await context.catalog.radioRefreshRequests
        XCTAssertEqual(refreshes.count, 1)
    }

    func testAutoplayStopsAfterThreeProviderCallsAndExplainsTheDeadEnd() async throws {
        let earlier = AppModelFixtures.track("earlier")
        let ending = AppModelFixtures.track("ending")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [earlier, ending], currentIndex: 1))
        let outage = Task { await context.player.onQueueExhausted?(ending) ?? [] }
        let first = try await context.catalog.autoplayRadios.request(at: 0)
        XCTAssertEqual(first.input.id, ending.id)
        try await context.catalog.autoplayRadios.complete(first, with: .failure(MusicServiceError.unavailable("Down")))
        let borrowed = try await context.catalog.autoplayRadios.request(at: 1)
        XCTAssertEqual(borrowed.input.id, earlier.id)
        try await context.catalog.autoplayRadios.complete(borrowed, with: .success([]))
        let refresh = try await context.catalog.autoplayRadios.request(at: 2)
        XCTAssertEqual(refresh.input.id, ending.id)
        try await context.catalog.autoplayRadios.complete(refresh, with: .failure(MusicServiceError.invalidResponse))
        let unreachable = await outage.value
        XCTAssertTrue(unreachable.isEmpty)
        XCTAssertEqual(context.model.autoplayContinuationError, "Autoplay couldn’t load more songs. Check your connection and try again.")
        XCTAssertFalse(context.model.isContinuingAutoplay)
        var requests = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(requests.count, AutoplayContinuation.maximumProviderCalls)
        let refreshes = await context.catalog.radioRefreshRequests
        XCTAssertEqual(refreshes.map(\.seed.id), [earlier.id, ending.id])
        XCTAssertEqual(refreshes.map(\.forceRefresh), [false, true])

        let starved = Task { await context.player.onQueueExhausted?(ending) ?? [] }
        let repeats = try await context.catalog.autoplayRadios.request(at: 3)
        try await context.catalog.autoplayRadios.complete(repeats, with: .success([earlier, ending]))
        let alternative = try await context.catalog.autoplayRadios.request(at: 4)
        XCTAssertEqual(alternative.input.id, earlier.id)
        try await context.catalog.autoplayRadios.complete(alternative, with: .success([ending]))
        let exhausted = await starved.value
        XCTAssertTrue(exhausted.isEmpty)
        XCTAssertEqual(context.model.autoplayContinuationError, "Couldn’t find more songs to play.",
                       "A radio that answers with only queued songs is exhaustion, not an outage, and earns no refresh")
        requests = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(requests.count, 5)
    }

    func testRetryAutoplayContinuationAsksAgainFreshAndClearsTheErrorOnSuccess() async throws {
        let seed = AppModelFixtures.track("seed")
        let neighbor = AppModelFixtures.track("neighbor")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [seed]))
        let failing = Task { await context.player.onQueueExhausted?(seed) ?? [] }
        let first = try await context.catalog.autoplayRadios.request(at: 0)
        try await context.catalog.autoplayRadios.complete(first, with: .failure(MusicServiceError.rateLimited))
        _ = await failing.value
        XCTAssertNotNil(context.model.autoplayContinuationError)

        context.model.retryAutoplayContinuation()
        XCTAssertNil(context.model.autoplayContinuationError)
        XCTAssertTrue(context.model.isContinuingAutoplay)
        context.model.retryAutoplayContinuation()
        let retry = try await context.catalog.autoplayRadios.request(at: 1)
        XCTAssertEqual(retry.input.id, seed.id)
        try await context.catalog.autoplayRadios.complete(retry, with: .success([neighbor]))
        try await AppModelFixtures.eventually { context.player.queue == [seed, neighbor] }
        XCTAssertEqual(context.player.autoplayTrackIDs, [neighbor.id])
        XCTAssertNil(context.model.autoplayContinuationError)
        XCTAssertFalse(context.model.isContinuingAutoplay)
        XCTAssertEqual(context.library.playback.queue, [seed, neighbor])
        let requests = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(requests.count, 2, "A retry while one is in flight is a no-op")
        let refreshes = await context.catalog.radioRefreshRequests
        XCTAssertEqual(refreshes.map(\.forceRefresh), [true], "A manual retry bypasses a stale cached radio")
    }

    func testTurningAutoplayOffOrPlayingSomethingNewClearsContinuationStateAndCancelsTheRequest() async throws {
        let seed = AppModelFixtures.track("seed")
        let neighbor = AppModelFixtures.track("neighbor")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [seed]))
        context.model.retryAutoplayContinuation()
        let pending = try await context.catalog.autoplayRadios.request(at: 0)
        XCTAssertTrue(context.model.isContinuingAutoplay)
        context.model.updatePreferences { $0.autoplay = false }
        XCTAssertFalse(context.model.isContinuingAutoplay)
        XCTAssertNil(context.model.autoplayContinuationError)
        try await AppModelFixtures.eventually { await context.catalog.autoplayRadios.cancellations.contains(pending.id) }
        try await context.catalog.autoplayRadios.complete(pending, with: .success([neighbor]))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(context.player.queue, [seed], "A cancelled continuation must not append after Autoplay is off")
        XCTAssertTrue(context.player.autoplayTrackIDs.isEmpty)
        context.model.retryAutoplayContinuation()
        XCTAssertFalse(context.model.isContinuingAutoplay, "Autoplay off makes the retry a no-op")
        var requests = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(requests.count, 1)

        context.model.updatePreferences { $0.autoplay = true }
        let failing = Task { await context.player.onQueueExhausted?(seed) ?? [] }
        let request = try await context.catalog.autoplayRadios.request(at: 1)
        try await context.catalog.autoplayRadios.complete(request, with: .failure(MusicServiceError.rateLimited))
        _ = await failing.value
        XCTAssertNotNil(context.model.autoplayContinuationError)
        context.model.play(AppModelFixtures.track("fresh-choice"))
        XCTAssertNil(context.model.autoplayContinuationError, "A new listener choice starts with a clean queue footer")
        requests = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testManualRetryAtTheEndOfTheQueueAsksFreshAndContinuesIntoTheNewSong() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 2)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = try makeContext(resolver: PlaybackFileResolver(url: url, duration: 2))
        context.model.updatePreferences { $0.gaplessPlayback = false; $0.automix = false }
        let seed = AppModelFixtures.track("seed")
        let neighbor = AppModelFixtures.track("neighbor")
        context.model.play(seed)
        let early = try await context.catalog.autoplayRadios.request(at: 0)
        XCTAssertEqual(early.input.id, seed.id)
        try await context.catalog.autoplayRadios.complete(early, with: .failure(MusicServiceError.rateLimited))
        try await AppModelFixtures.eventually { context.model.autoplayContinuationError != nil }
        var refreshes = await context.catalog.radioRefreshRequests
        XCTAssertTrue(refreshes.isEmpty, "The early request may use a cached radio")

        try await PlaybackTestSupport.eventually { await context.catalog.autoplayRadios.requests.count == 2 }
        let endOfQueue = try await context.catalog.autoplayRadios.request(at: 1)
        XCTAssertEqual(endOfQueue.input.id, seed.id)
        XCTAssertTrue(context.player.isLoading, "The ended queue waits for the final answer")
        XCTAssertTrue(context.model.isContinuingAutoplay)
        refreshes = await context.catalog.radioRefreshRequests
        XCTAssertEqual(refreshes.map(\.forceRefresh), [true], "The end-of-queue attempt bypasses the cached radio that already came up empty")
        try await context.catalog.autoplayRadios.complete(endOfQueue, with: .failure(MusicServiceError.rateLimited))
        try await PlaybackTestSupport.waitUntil { !context.player.isLoading && !context.model.isContinuingAutoplay }
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertEqual(context.player.queue, [seed])
        XCTAssertGreaterThanOrEqual(context.player.position, 1.99)
        XCTAssertEqual(context.model.autoplayContinuationError, "Autoplay paused because the music service is busy. Try again in a moment.")

        context.model.retryAutoplayContinuation()
        let retry = try await context.catalog.autoplayRadios.request(at: 2)
        XCTAssertEqual(retry.input.id, seed.id)
        try await context.catalog.autoplayRadios.complete(retry, with: .success([neighbor]))
        try await PlaybackTestSupport.waitUntil { context.player.currentTrack == neighbor && context.player.isPlaying && context.player.position > 0.2 }
        XCTAssertEqual(context.player.queue, [seed, neighbor], "The finished song is not replayed; playback continues into the new one")
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.autoplayTrackIDs, [neighbor.id])
        XCTAssertNil(context.model.autoplayContinuationError)
        XCTAssertEqual(context.library.playback.currentIndex, 1)
        refreshes = await context.catalog.radioRefreshRequests
        XCTAssertEqual(refreshes.map(\.forceRefresh), [true, true], "The manual retry also asks for a fresh radio")

        // The new song is now the last one, so Autoplay asks for its own continuation the ordinary way.
        let onward = try await context.catalog.autoplayRadios.request(at: 3)
        XCTAssertEqual(onward.input.id, neighbor.id)
        XCTAssertTrue(context.model.isContinuingAutoplay, "The newly last song's request is in flight")
        refreshes = await context.catalog.radioRefreshRequests
        XCTAssertEqual(refreshes.count, 2, "An early request for the newly last song may use a cached radio")
        let more = (1...AutoplayContinuation.minimumBatch).map { AppModelFixtures.track("more-\($0)") }
        try await context.catalog.autoplayRadios.complete(onward, with: .success(more))
        try await AppModelFixtures.eventually { context.player.queue == [seed, neighbor] + more }
        XCTAssertFalse(context.model.isContinuingAutoplay)
        XCTAssertNil(context.model.autoplayContinuationError)
        XCTAssertEqual(context.player.currentTrack, neighbor)
        let requests = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(requests.count, 4, "A full batch for the newly last song borrows no second seed")
        context.player.pause()
    }

    func testRadioContinuationFailuresLeaveOrdinaryAutoplayStateUntouched() async throws {
        let context = try makeContext()
        let f = ExperienceRadioFixtures.self
        let start = context.model.startRadio(f.melancholy)
        try await f.answerSearches(context, from: 0, with: f.melancholySearches)
        try await f.answerRadios(context, from: 0, with: f.melancholyRadios)
        await start.value
        XCTAssertEqual(context.model.activeRadioExperience, f.melancholy)
        let queries = Set(f.melancholy.selection(for: context.model.listeningLanguageProfile).styleQueries
            .prefix(ExperienceRadioEngine.maximumStyleQueries))
        XCTAssertEqual(queries.count, 3)
        let continuation = Task { await context.player.onQueueExhausted?(f.alt) ?? [] }
        defer { continuation.cancel() }
        try await f.answerRadios(context, from: 2, with: [f.cas.id: [], f.alt.id: []], fail: true)
        for index in 2..<(2 + queries.count * 2) {
            let request = try await context.catalog.searches.request(at: index)
            XCTAssertTrue(queries.contains(request.input.query))
            XCTAssertTrue(request.input.filter == .songs || request.input.filter == .playlists)
            XCTAssertNil(request.input.continuation)
            try await context.catalog.searches.complete(request, with: .success(CatalogPage()))
        }
        let additions = await continuation.value
        XCTAssertTrue(additions.isEmpty)
        XCTAssertNotNil(context.model.radioContinuationError)
        XCTAssertNil(context.model.autoplayContinuationError, "Radio keeps its own continuation state")
        XCTAssertFalse(context.model.isContinuingAutoplay)
        context.model.retryAutoplayContinuation()
        XCTAssertFalse(context.model.isContinuingAutoplay, "The ordinary retry is a no-op during a radio session")
        let requests = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(requests.count, 4)
        let fallbackSearches = await context.catalog.searches.requests.dropFirst(2)
        XCTAssertEqual(fallbackSearches.filter { $0.input.filter == .songs }.count, 3)
        XCTAssertEqual(fallbackSearches.filter { $0.input.filter == .playlists }.count, 3)
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
