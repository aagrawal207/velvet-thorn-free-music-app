import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightCatalogTests: XCTestCase {
    func testCompleteListingStillGathersCollaborationsFromTwoBoundedSearchPagesWithoutAlbumsOrCountSearches() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await catalog.close() }
        let songs = (0..<35).map { ArtistSpotlightTestSupport.track("song-\($0)", count: Int64($0)) }
        let collaboration = ArtistSpotlightTestSupport.collaboration("collaboration", count: 800)
        var titleFeature = ArtistSpotlightTestSupport.track("title-feature", title: "Night Train (feat. A. R. Rahman)", count: 20)
        titleFeature.credits = [ArtistCredit(name: "Rail Collective")]
        var unrelated = ArtistSpotlightTestSupport.track("unrelated", count: 10_000)
        unrelated.credits = [ArtistCredit(name: "Other Artist")]
        let releases = [MusicCollection(id: "provider-album", title: "Release", kind: .album)]
        let service = ArtistSpotlightCatalogService(catalog: catalog)
        let page = ArtistSpotlightTestSupport.page(songs, releases: releases)
        let task = Task { try await service.load(page) }
        let first = try await catalog.searches.request(at: 0)
        XCTAssertEqual(first.input, AppModelSearchRequest(query: page.name, filter: .songs, continuation: nil))
        try await catalog.searches.complete(first, with: .success(CatalogPage(tracks: [collaboration, unrelated], continuation: "next-page")))
        let second = try await catalog.searches.request(at: 1)
        XCTAssertEqual(second.input.continuation, "next-page")
        try await catalog.searches.complete(second, with: .success(CatalogPage(tracks: [titleFeature, songs[0]], continuation: "third-page")))
        let outcome = try await task.value
        XCTAssertEqual(outcome.tracks.count, 37)
        XCTAssertEqual(outcome.tracks.first?.id, "collaboration", "A search-only collaboration sorts by its own count")
        XCTAssertEqual(outcome.tracks.map(\.id).firstIndex(of: "title-feature"), 15,
                       "20 plays follow the fourteen listed songs above 20 and win the count tie on title")
        XCTAssertEqual(outcome.tracks.last?.playCount, 0)
        XCTAssertFalse(outcome.tracks.contains { $0.id == "unrelated" })
        XCTAssertFalse(outcome.hadFailures)
        XCTAssertEqual(ArtistSpotlight.role(of: page, on: outcome.tracks[0]), .featured)
        XCTAssertEqual(ArtistSpotlight.role(of: page, on: outcome.tracks[1]), .primary)
        let searches = await catalog.searches.requests
        let albums = await catalog.albums.requests
        XCTAssertEqual(searches.count, 2, "The third continuation stays unused and a full listing never browses albums")
        XCTAssertTrue(albums.isEmpty)
    }

    func testSparseListingUsesBoundedProviderPagesAndListedAlbumsWithAllArtistCredits() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await catalog.close() }
        let seed = ArtistSpotlightTestSupport.track("top", count: 1_000)
        let collaboration = ArtistSpotlightTestSupport.collaboration("collaboration", count: 800)
        var unrelated = ArtistSpotlightTestSupport.track("unrelated", count: 10_000)
        unrelated.credits = [ArtistCredit(name: "Other Artist")]
        let releases = (0..<5).map { MusicCollection(id: "provider-album-\($0)", title: "Release \($0)", kind: .album) }
        var configuration = ArtistSpotlightTestSupport.catalogConfiguration(minimum: 20, searchPages: 2)
        configuration.maximumAlbumRequests = 2
        let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: configuration)
        let page = ArtistSpotlightTestSupport.page([seed], releases: releases)
        let task = Task { try await service.load(page) }
        let first = try await catalog.searches.request(at: 0)
        XCTAssertEqual(first.input, AppModelSearchRequest(query: page.name, filter: .songs, continuation: nil))
        try await catalog.searches.complete(first, with: .success(CatalogPage(tracks: [collaboration, unrelated], continuation: "next-page")))
        let second = try await catalog.searches.request(at: 1)
        XCTAssertEqual(second.input.continuation, "next-page")
        try await catalog.searches.complete(second, with: .success(CatalogPage(tracks: [seed], continuation: "unused-page")))
        let albumA = try await catalog.albums.request(at: 0)
        let albumB = try await catalog.albums.request(at: 1)
        XCTAssertEqual(Set([albumA.input, albumB.input]), Set(releases.prefix(2).map(\.id)))
        try await catalog.albums.complete(albumB, with: .success(CatalogPage(tracks: [ArtistSpotlightTestSupport.track("album-b", count: 400), unrelated])))
        try await catalog.albums.complete(albumA, with: .success(CatalogPage(tracks: [ArtistSpotlightTestSupport.track("album-a", count: 600), seed])))
        let outcome = try await task.value
        XCTAssertEqual(outcome.tracks.map(\.id), ["top", "collaboration", "album-a", "album-b"])
        let searchCount = await catalog.searches.requests.count
        let albumCount = await catalog.albums.requests.count
        let concurrency = await catalog.maximumActiveRequests
        XCTAssertEqual(searchCount, 2)
        XCTAssertEqual(albumCount, 2)
        XCTAssertLessThanOrEqual(concurrency, 3)
    }

    func testSearchAlternateReleaseOfAListedSongFoldsIntoOneRowWithoutASecondCount() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let progress = ArtistSpotlightProgress()
        addTeardownBlock { await catalog.close() }
        let releases = [MusicCollection(id: "MPRE-album", title: "Pablo Honey", subtitle: "Album • 1993", kind: .album),
                        MusicCollection(id: "MPRE-single", title: "Creep", subtitle: "Single • 1992", kind: .album)]
        var listedSingle = ArtistSpotlightTestSupport.track("creep-single", title: "Creep", count: 2_200_000_000)
        listedSingle.albumTitle = "Creep"
        listedSingle.albumID = "MPRE-single"
        listedSingle.duration = 239
        listedSingle.artworkURL = URL(string: "https://example.invalid/creep-single.jpg")
        var albumRelease = ArtistSpotlightTestSupport.track("creep-album", title: "Creep", count: 2_300_000_000)
        albumRelease.albumTitle = "Pablo Honey"
        albumRelease.albumID = "MPRE-album"
        albumRelease.duration = 240
        albumRelease.artworkURL = URL(string: "https://example.invalid/pablo-honey.jpg")
        albumRelease.isExplicit = true
        var liveTake = ArtistSpotlightTestSupport.track("creep-live", title: "Creep (Live)", count: 40_000_000)
        liveTake.albumID = "MPRE-album"
        let other = ArtistSpotlightTestSupport.track("karma-police", title: "Karma Police", count: 256_000_000)
        var configuration = ArtistSpotlightTestSupport.catalogConfiguration(searchPages: 1)
        configuration.maximumCountSearches = 0
        let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: configuration)
        let page = ArtistSpotlightTestSupport.page([listedSingle, other], releases: releases)
        let task = Task { try await service.load(page) { await progress.append($0) } }
        let search = try await catalog.searches.request(at: 0)
        try await catalog.searches.complete(search, with: .success(CatalogPage(tracks: [albumRelease, liveTake, listedSingle])))
        let outcome = try await task.value
        XCTAssertEqual(outcome.tracks.map(\.id), ["creep-album", "karma-police", "creep-live"],
                       "The album release represents the song; the live take is another performance")
        XCTAssertEqual(outcome.tracks.first?.playCount, 2_300_000_000, "The surviving release keeps its own total")
        XCTAssertEqual(outcome.tracks.first, albumRelease)
        XCTAssertTrue(outcome.tracks.first?.isExplicit == true)
        XCTAssertEqual(progress.updates.first?.map(\.id), ["creep-single", "karma-police"], "The listing shows before search finishes")
        XCTAssertFalse(outcome.hadFailures)
    }

    func testSearchPaginationRetainsRawAliasesAndMatchesOneShotSelection() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let progress = ArtistSpotlightProgress()
        let rawProgress = ArtistSpotlightProgress()
        addTeardownBlock { await catalog.close() }
        var fixture = ArtistSpotlightTestSupport.releaseAliases()
        var cleanAlbum = fixture.album
        cleanAlbum.isExplicit = false
        var explicitSingle = fixture.single
        explicitSingle.isExplicit = true
        var explicitAlbum = fixture.album
        explicitAlbum.id = "explicit-album"
        fixture.page.topSongs = [cleanAlbum]
        let service = ArtistSpotlightCatalogService(catalog: catalog,
            configuration: ArtistSpotlightTestSupport.catalogConfiguration(searchPages: 2))
        let page = fixture.page
        let task = Task {
            try await service.load(page, onCandidates: { await rawProgress.append($0) },
                                   onUpdate: { await progress.append($0) })
        }
        let first = try await catalog.searches.request(at: 0)
        try await catalog.searches.complete(first, with: .success(CatalogPage(tracks: [explicitSingle], continuation: "second")))
        let second = try await catalog.searches.request(at: 1)
        XCTAssertEqual(progress.updates.last, [cleanAlbum], "A losing release cannot lend its explicit flag or artwork")
        try await catalog.searches.complete(second, with: .success(CatalogPage(tracks: [explicitAlbum, cleanAlbum])))
        let outcome = try await task.value
        let expected = ArtistSpotlight.sorted(ArtistSpotlight.distinctSongs([cleanAlbum, explicitSingle, explicitAlbum], artist: page))
        XCTAssertEqual(outcome.tracks, [explicitAlbum])
        XCTAssertEqual(outcome.tracks, expected)
        XCTAssertEqual(Set(outcome.candidates.map(\.id)), [cleanAlbum.id, explicitSingle.id, explicitAlbum.id])
        XCTAssertEqual(outcome.candidates.first { $0.id == cleanAlbum.id }, cleanAlbum)
        XCTAssertEqual(rawProgress.updates.last, outcome.candidates)
        XCTAssertEqual(progress.updates.last, outcome.tracks)
    }

    func testAlbumResponseOrderMatchesOneShotAliasSelection() async throws {
        for singleFinishesFirst in [false, true] {
            let catalog = ArtistSpotlightCatalogFixture()
            let progress = ArtistSpotlightProgress()
            addTeardownBlock { await catalog.close() }
            var fixture = ArtistSpotlightTestSupport.releaseAliases()
            var cleanAlbum = fixture.album
            cleanAlbum.isExplicit = false
            var explicitSingle = fixture.single
            explicitSingle.isExplicit = true
            var explicitAlbum = fixture.album
            explicitAlbum.id = "explicit-album"
            fixture.page.topSongs = [cleanAlbum]
            var configuration = ArtistSpotlightTestSupport.catalogConfiguration(minimum: 20)
            configuration.maximumAlbumRequests = 2
            let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: configuration)
            let page = fixture.page
            let task = Task { try await service.load(page) { await progress.append($0) } }
            let first = try await catalog.albums.request(at: 0)
            let second = try await catalog.albums.request(at: 1)
            let album = first.input == "MPRE-album" ? first : second
            let single = first.input == "MPRE-single" ? first : second
            if singleFinishesFirst {
                try await catalog.albums.complete(single, with: .success(CatalogPage(tracks: [explicitSingle])))
            } else {
                try await catalog.albums.complete(album, with: .success(CatalogPage(tracks: [explicitAlbum])))
            }
            try await AppModelFixtures.eventually { progress.updates.count == 2 }
            if singleFinishesFirst {
                XCTAssertEqual(progress.updates.last, [cleanAlbum])
                try await catalog.albums.complete(album, with: .success(CatalogPage(tracks: [explicitAlbum])))
            } else {
                try await catalog.albums.complete(single, with: .success(CatalogPage(tracks: [explicitSingle])))
            }
            let outcome = try await task.value
            let expected = ArtistSpotlight.sorted(ArtistSpotlight.distinctSongs([cleanAlbum, explicitAlbum, explicitSingle], artist: page))
            XCTAssertEqual(outcome.tracks, [explicitAlbum])
            XCTAssertEqual(outcome.tracks, expected)
            XCTAssertEqual(Set(outcome.candidates.map(\.id)), [cleanAlbum.id, explicitSingle.id, explicitAlbum.id])
        }
    }

    func testRetainedAliasPoolAndVisibleSongsRespectSeparateBounds() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let progress = ArtistSpotlightProgress()
        addTeardownBlock { await catalog.close() }
        let fixture = ArtistSpotlightTestSupport.releaseAliases()
        var configuration = ArtistSpotlightTestSupport.catalogConfiguration(searchPages: 2)
        configuration.maximumAdditionalTracks = 1
        configuration.maximumAlbumRequests = 0
        let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: configuration)
        let task = Task { try await service.load(fixture.page, onCandidates: { await progress.append($0) }, onUpdate: { _ in }) }
        let first = try await catalog.searches.request(at: 0)
        let aliases = (0..<2).map { index in
            var track = fixture.single
            track.id = "alias-\(index)"
            return track
        }
        try await catalog.searches.complete(first, with: .success(CatalogPage(tracks: aliases, continuation: "second")))
        let second = try await catalog.searches.request(at: 1)
        let additional = (0..<10).map { ArtistSpotlightTestSupport.track("additional-\($0)", count: 100) }
        try await catalog.searches.complete(second, with: .success(CatalogPage(tracks: additional)))
        let outcome = try await task.value
        XCTAssertEqual(outcome.tracks.count, 2, "One initial song plus one additional display group")
        XCTAssertEqual(outcome.candidates.count, 5, "One initial recording plus two retained candidates for each of two searches")
        XCTAssertTrue(progress.updates.allSatisfy { $0.count <= 5 })
        XCTAssertTrue(Set(aliases.map(\.id)).isSubset(of: Set(outcome.candidates.map(\.id))))
        XCTAssertEqual(ArtistSpotlight.displaySongs(outcome.candidates, artist: fixture.page, maximumAdditionalTracks: 1).aliasCount, 2)
    }

    func testPreferredAlbumCannotBorrowTheSinglesCountDuringEnrichment() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await catalog.close() }
        var fixture = ArtistSpotlightTestSupport.releaseAliases()
        fixture.album.playCount = nil
        let service = ArtistSpotlightCatalogService(catalog: catalog,
            configuration: ArtistSpotlightTestSupport.catalogConfiguration(countSearches: 1, searchPages: 1))
        let page = fixture.page
        let task = Task { try await service.load(page) }
        let search = try await catalog.searches.request(at: 0)
        try await catalog.searches.complete(search, with: .success(CatalogPage(tracks: [fixture.album])))
        let count = try await catalog.searches.request(at: 1)
        try await catalog.searches.complete(count, with: .success(CatalogPage(tracks: [fixture.single])))
        let outcome = try await task.value
        XCTAssertEqual(outcome.tracks, [fixture.album])
        XCTAssertNil(outcome.tracks.first?.playCount)
        XCTAssertEqual(outcome.candidates.first { $0.id == fixture.single.id }?.playCount, 900)
        let searches = await catalog.searches.requests
        XCTAssertEqual(searches.count, 2)
    }

    func testCountEnrichmentIsBoundedAndUpdatesBeforeAllRequestsFinish() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let progress = ArtistSpotlightProgress()
        addTeardownBlock { await catalog.close() }
        let songs = (0..<6).map { ArtistSpotlightTestSupport.track("missing-\($0)") }
        var configuration = ArtistSpotlightTestSupport.catalogConfiguration(countSearches: 3)
        configuration.maximumConcurrentRequests = 2
        let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: configuration)
        let task = Task { try await service.load(ArtistSpotlightTestSupport.page(songs)) { await progress.append($0) } }
        let first = try await catalog.searches.request(at: 0)
        let second = try await catalog.searches.request(at: 1)
        XCTAssertEqual(first.input.filter, .songs)
        XCTAssertTrue(first.input.query.hasSuffix("A. R. Rahman"))
        let secondSong = try XCTUnwrap(songs.first { second.input.query.hasPrefix($0.title + " ") })
        var counted = secondSong
        counted.playCount = 900
        try await catalog.searches.complete(second, with: .success(CatalogPage(tracks: [counted])))
        try await AppModelFixtures.eventually { progress.updates.last?.first?.playCount == 900 }
        let third = try await catalog.searches.request(at: 2)
        let firstSong = try XCTUnwrap(songs.first { first.input.query.hasPrefix($0.title + " ") })
        let otherRecording = ArtistSpotlightTestSupport.track("different-recording", title: firstSong.title, count: 50_000)
        try await catalog.searches.complete(first, with: .success(CatalogPage(tracks: [otherRecording])))
        try await catalog.searches.complete(third, with: .failure(MusicServiceError.network("Synthetic failure")))
        let outcome = try await task.value
        XCTAssertEqual(outcome.tracks.first?.id, secondSong.id)
        XCTAssertEqual(outcome.tracks.filter { $0.playCount != nil }.count, 1)
        XCTAssertEqual(outcome.tracks.count, 6)
        XCTAssertTrue(outcome.hadFailures)
        let requests = await catalog.searches.requests
        let concurrency = await catalog.maximumActiveRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(concurrency, 2)
    }

    func testCancellingDropsLateSupplementAndDoesNotFollowItsContinuation() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let progress = ArtistSpotlightProgress()
        addTeardownBlock { await catalog.close() }
        let seed = ArtistSpotlightTestSupport.track("seed", count: 100)
        let service = ArtistSpotlightCatalogService(catalog: catalog)
        let task = Task { try await service.load(ArtistSpotlightTestSupport.page([seed])) { await progress.append($0) } }
        let request = try await catalog.searches.request(at: 0)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled enrichment completed") }
        catch is CancellationError { }
        try await catalog.searches.complete(request, with: .success(CatalogPage(
            tracks: [ArtistSpotlightTestSupport.track("stale", count: 10_000)], continuation: "must-not-follow")))
        let requests = await catalog.searches.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(progress.updates.last?.map(\.id), ["seed"])
    }

    func testDeadlinePreservesSongsWhenAProviderIgnoresCancellation() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await catalog.close() }
        var configuration = ArtistSpotlightTestSupport.catalogConfiguration(countSearches: 1)
        configuration.requestTimeout = 0.03
        configuration.totalTimeout = 0.1
        let seed = ArtistSpotlightTestSupport.track("seed")
        let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: configuration)
        let task = Task { try await service.load(ArtistSpotlightTestSupport.page([seed])) }
        let request = try await catalog.searches.request(at: 0)
        let outcome = try await task.value
        XCTAssertEqual(outcome.tracks.map(\.id), ["seed"])
        XCTAssertNil(outcome.tracks.first?.playCount)
        XCTAssertTrue(outcome.hadFailures)
        var late = seed
        late.playCount = 90_000
        try await catalog.searches.complete(request, with: .success(CatalogPage(tracks: [late])))
    }
}
