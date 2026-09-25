import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class MoodRadioEngineTests: XCTestCase {
    func testZeroAllSingleAndUnavailableArtistHintsKeepTheMoodAndAllowOtherArtists() async throws {
        let f = ExperienceRadioFixtures.self
        let guest = ArtistCredit(name: "Guest Artist", id: "UCmoodGuest")
        let missing = ArtistCredit(name: "Unavailable Artist", id: "UCmoodMissing")
        let guestSong = RecommendationFixtures.track("guest-song", artist: guest.name, artistID: guest.id)
        let guestNeighbor = RecommendationFixtures.track("guest-neighbor", artist: "Another Artist")
        let cases: [[ArtistCredit]] = [[], f.melancholy.seeds.map(\.artist), [guest], [missing]]
        for hints in cases {
            var configuration = RadioConfiguration(station: station(), languages: [.english])
            configuration.artists = hints
            let catalog = ExperienceRadioCatalogFixture(searches: f.melancholySearches.mapValues { .success([$0]) },
                radios: [f.cas.id: .success([f.dream]), f.pixies.id: .success([f.alt]), guestSong.id: .success([guestNeighbor])],
                artists: ["UCmoodGuest": .success(ArtistPage(id: "UCmoodGuest", name: guest.name, topSongs: [guestSong])),
                          "UCmoodMissing": .failure(MusicServiceError.network("Optional hint is unavailable"))])
            let batch = try await ExperienceRadioEngine(catalog: catalog).start(configuration.experience(), disliked: [], languages: [.english])
            XCTAssertEqual(batch.tracks.first, f.cas)
            XCTAssertGreaterThanOrEqual(batch.tracks.count, 4)
            XCTAssertTrue(batch.tracks.contains(f.dream), "Selected artists must not filter provider neighbors")
            XCTAssertTrue(batch.tracks.contains(f.alt))
            XCTAssertFalse(batch.discoveryTrackIDs.isEmpty)
            if hints == [guest] { XCTAssertTrue(batch.tracks.contains(guestSong)) }
            if hints == [missing] { XCTAssertEqual(batch.tracks, [f.cas, f.pixies, f.dream, f.alt]) }
            let artists = await catalog.artistRequests
            if hints.isEmpty || hints == f.melancholy.seeds.map(\.artist) { XCTAssertTrue(artists.isEmpty) }
            let targeted = await catalog.targetedRadioRequests
            XCTAssertEqual(targeted, 0)
        }
    }

    func testEmptyCueSearchFallsBackToProviderMoodSongsEvenWhenRadioIsEmpty() async throws {
        let experience = station()
        let songs = (0..<6).map { RecommendationFixtures.track("mood-\($0)", artist: "Mood Artist \($0)", language: .english) }
        var searches: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: experience.seeds.map { ($0.query, .success([])) })
        searches[queries(experience)[0]] = .success(songs)
        searches[queries(experience)[1]] = .success([])
        let catalog = ExperienceRadioCatalogFixture(searches: searches,
            radios: Dictionary(uniqueKeysWithValues: songs.map { ($0.id, .success([])) }),
            playlistSearches: emptyPlaylists(experience))
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [], languages: [.english])
        XCTAssertEqual(Set(batch.tracks), Set(songs))
        XCTAssertTrue(Set(batch.buckets.map(\.anchor.id)).isSubset(of: Set(songs.map(\.id))))
        XCTAssertEqual(batch.discoveryTrackIDs, Set(songs.map(\.id)))
        let radio = await catalog.radioRequests
        XCTAssertEqual(radio.count, 4)
        XCTAssertTrue(radio.allSatisfy { songs.contains($0) })
    }

    func testMissingCueSongsUseMoodDiscoveryBeforeStartingFromAnArtistHint() async throws {
        let hint = ArtistCredit(name: "Hint Artist", id: "UCmoodHint")
        let hintSong = RecommendationFixtures.track("hint-song", artist: hint.name, artistID: hint.id)
        let songs = (0..<6).map { RecommendationFixtures.track("mood-\($0)", artist: "Mood Artist \($0)") }
        var configuration = RadioConfiguration(station: station(), languages: [.english])
        configuration.artists = [hint]
        let experience = configuration.experience()
        var searches: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: experience.seeds.map { ($0.query, .success([])) })
        searches[queries(experience)[0]] = .success(songs)
        searches[queries(experience)[1]] = .success([])
        let catalog = ExperienceRadioCatalogFixture(searches: searches,
            radios: Dictionary(uniqueKeysWithValues: (songs + [hintSong]).map { ($0.id, .success([])) }),
            artists: ["UCmoodHint": .success(ArtistPage(id: "UCmoodHint", name: hint.name, topSongs: [hintSong]))],
            playlistSearches: emptyPlaylists(experience))

        let batch = try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [], languages: [.english])

        XCTAssertEqual(batch.tracks.first, songs[0])
        XCTAssertTrue(batch.tracks.contains(hintSong))
        XCTAssertTrue(Set(songs).isSubset(of: Set(batch.tracks)))
        let radios = await catalog.radioRequests
        XCTAssertEqual(radios.count, 4, "Mood discovery must precede an unnecessary hint-only radio request")
        let searchesMade = await catalog.searchRequests
        XCTAssertTrue(searchesMade.contains { $0.query == queries(experience)[0] && $0.filter == .songs })
    }

    func testAStalledArtistHintCannotBlockMoodDefaultsOrDiscardAnotherAvailableHint() async throws {
        let f = ExperienceRadioFixtures.self
        let stalled = ArtistCredit(name: "Stalled Artist", id: "UCstalledHint")
        let available = ArtistCredit(name: "Available Artist", id: "UCavailableHint")
        let availableSong = RecommendationFixtures.track("available-hint", artist: available.name, artistID: available.id)
        let neighbor = RecommendationFixtures.track("available-neighbor", artist: "Another Artist")
        let catalog = AppModelCatalogProvider()
        addTeardownBlock { await catalog.close() }
        var configuration = RadioConfiguration(station: station(seeds: [
            .init(recording: f.cas, artist: f.melancholy.seeds[0].artist),
            .init(recording: f.pixies, artist: f.melancholy.seeds[1].artist),
        ]), languages: [.english])
        configuration.artists = [stalled, available]
        let experience = configuration.experience()
        let task = Task { try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [], languages: [.english]) }
        defer { task.cancel() }
        let hints = [try await catalog.artists.request(at: 0), try await catalog.artists.request(at: 1)]
        let fast = try XCTUnwrap(hints.first { $0.input == available.id })
        let late = try XCTUnwrap(hints.first { $0.input == stalled.id })
        try await catalog.artists.complete(fast, with: .success(ArtistPage(id: fast.input, name: available.name, topSongs: [availableSong])))
        let songs = [f.cas.id: [f.dream], f.pixies.id: [f.alt], availableSong.id: [neighbor]]
        for index in 0..<3 {
            let request = try await catalog.autoplayRadios.request(at: index)
            let tracks = try XCTUnwrap(songs[request.input.id])
            try await catalog.autoplayRadios.complete(request, with: .success(tracks))
        }
        let batch = try await task.value
        XCTAssertEqual(batch.tracks.first, f.cas)
        XCTAssertTrue(batch.tracks.contains(availableSong))
        XCTAssertTrue(batch.tracks.contains(f.dream) && batch.tracks.contains(f.alt))
        try await AppModelFixtures.eventually { await catalog.artists.cancellations.contains(late.id) }

        let lateSong = RecommendationFixtures.track("late-hint", artist: stalled.name, artistID: stalled.id)
        try await catalog.artists.complete(late, with: .success(ArtistPage(id: late.input, name: stalled.name, topSongs: [lateSong])))
        XCTAssertFalse(batch.tracks.contains(lateSong))
        let radio = await catalog.autoplayRadios.requests
        XCTAssertEqual(radio.count, 3)
        let searches = await catalog.searches.requests
        XCTAssertTrue(searches.isEmpty)
    }

    func testEmptyInitialRadioFallsBackToAMoodPlaylistWithFilteringIntact() async throws {
        let f = ExperienceRadioFixtures.self
        let experience = station()
        let songs = (0..<4).map { RecommendationFixtures.track("playlist-\($0)", artist: "Playlist Artist \($0)") }
        let blocked = RecommendationFixtures.track("blocked", title: "Blocked song", artist: "Excluded Artist")
        let video = RecommendationFixtures.track("video", audio: false)
        let hindi = RecommendationFixtures.track("wrong-language", language: .hindi)
        let duplicate = RecommendationFixtures.track("alternate-upload", title: songs[0].title + " (Remastered)")
        let playlist = MusicCollection(id: "provider-mood-playlist", title: "Dream pop nights", kind: .playlist)
        var searches = cueSearches()
        for query in queries(experience) { searches[query] = .success([]) }
        let catalog = ExperienceRadioCatalogFixture(searches: searches,
            radios: [f.cas.id: .success([]), f.pixies.id: .success([])],
            albums: [playlist.id: .success(CatalogPage(tracks: [video, hindi, blocked] + songs + [duplicate]))],
            playlistSearches: [queries(experience)[0]: .success([playlist]), queries(experience)[1]: .success([])])
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(experience,
            disliked: [DislikedSong(id: "different-upload", title: "Blocked song (Live)", artists: [])], languages: [.english])
        XCTAssertTrue(Set(songs).isSubset(of: Set(batch.tracks)))
        XCTAssertTrue(batch.tracks.allSatisfy { ![video.id, hindi.id, blocked.id, duplicate.id].contains($0.id) })
        XCTAssertTrue(batch.tracks.filter { songs.contains($0) }.allSatisfy { $0.language == nil })
        let browsed = await catalog.browseRequests
        XCTAssertEqual(browsed, [playlist.id])
        let radio = await catalog.radioRequests
        XCTAssertEqual(radio.count, 2, "A usable mood playlist avoids unnecessary further radio requests")
    }

    func testOneBoundedRadioRetryCanRecoverWhenOtherProviderStrategiesAreEmpty() async throws {
        let f = ExperienceRadioFixtures.self
        let experience = station()
        var searches = cueSearches()
        for query in queries(experience) { searches[query] = .success([]) }
        let catalog = ExperienceRadioCatalogFixture(searches: searches, playlistSearches: emptyPlaylists(experience),
            radioSequences: [f.cas.id: [.success([]), .success([f.dream])], f.pixies.id: [.success([]), .success([f.alt])]])
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [], languages: [.english])
        XCTAssertEqual(batch.tracks, [f.cas, f.pixies, f.dream, f.alt])
        let calls = await catalog.radioRequests
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.filter { $0.id == f.cas.id }.count, 2)
        XCTAssertEqual(calls.filter { $0.id == f.pixies.id }.count, 2)
    }

    func testAllStrategiesHaveBudgetsAndAnUnavailableProviderStillFails() async throws {
        let intents = (0..<6).map { RadioExperience.Seed("Style Signal \($0)", by: "Style Artist \($0)") }
        let cues = intents.enumerated().map { RecommendationFixtures.track("cue-\($0.offset)", title: $0.element.title, artist: $0.element.artist.name) }
        let hints = (0..<7).map { ArtistCredit(name: "Hint Artist \($0)", id: "UChint\($0)") }
        let hintSongs = hints.prefix(4).enumerated().map { RecommendationFixtures.track("hint-\($0.offset)", artist: $0.element.name, artistID: $0.element.id) }
        let queries = ["dream pop songs", "indie rock songs", "lofi study songs", "unused fourth query"]
        let experience = RadioExperience(id: "bounded-style", title: "Bounded", description: "Fixture", symbol: "radio",
            discoveryLanguages: [.english], contentLabel: "English", seeds: intents, styleQueries: queries, artistHints: hints)
        var searches: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: zip(intents, cues).map { ($0.query, .success([$1])) })
        for query in queries.prefix(3) { searches[query] = .success([]) }
        let playlists = (0..<4).map { MusicCollection(id: "playlist-\($0)", title: "Mood playlist \($0)", kind: .playlist) }
        let artistPages: [String: Result<ArtistPage, any Error>] = Dictionary(uniqueKeysWithValues: zip(hints.prefix(4), hintSongs).map { hint, song in
            (hint.id!, .success(ArtistPage(id: hint.id!, name: hint.name, topSongs: [song])))
        })
        let catalog = ExperienceRadioCatalogFixture(searches: searches,
            radios: Dictionary(uniqueKeysWithValues: (cues + hintSongs).map { ($0.id, .success([])) }), artists: artistPages,
            albums: Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, .success(CatalogPage())) }),
            playlistSearches: Dictionary(uniqueKeysWithValues: queries.prefix(3).map { ($0, .success(playlists)) }), delay: .milliseconds(20))
        do {
            _ = try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [], languages: [.english])
            XCTFail("Fixed cues alone must not masquerade as a provider-backed station")
        } catch { XCTAssertEqual(error as? ExperienceRadioError, .unavailable) }
        let searchesMade = await catalog.searchRequests
        let artistsMade = await catalog.artistRequests
        let browses = await catalog.browseRequests
        let radio = await catalog.radioRequests
        let peak = await catalog.maximumActiveRequests
        XCTAssertEqual(searchesMade.count, 12, "Six cue searches plus three style queries with songs and playlists filters")
        XCTAssertEqual(ExperienceRadioEngine.maximumStyleQueries, 3)
        XCTAssertFalse(searchesMade.contains { $0.query == queries[3] })
        XCTAssertEqual(artistsMade.count, 4)
        XCTAssertEqual(browses.count, ExperienceRadioEngine.maximumStylePlaylists)
        XCTAssertEqual(radio.count, ExperienceRadioEngine.maximumRadioRequests)
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 3)
    }

    func testSeedlessDatedStationStartsFromUndatedStyleSongsWhenNoDatedEvidenceExists() async throws {
        let experience = station(seeds: [], era: .newer)
        let songs = (0..<4).map { RecommendationFixtures.track("undated-\($0)", title: "2024 song \($0)", artist: "Artist \($0)") }
        let neighbors = songs.map { RecommendationFixtures.track("near-\($0.id)", artist: "Neighbor \($0.id)") }
        let queries = self.queries(experience).map { $0 + " 2015 and later" }
        let catalog = ExperienceRadioCatalogFixture(searches: [queries[0]: .success(songs), queries[1]: .success([])],
            radios: Dictionary(uniqueKeysWithValues: zip(songs, neighbors).map { ($0.id, .success([$1])) }),
            playlistSearches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success([])) }))
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [], languages: [.english])
        // Query wording is not release-date evidence, but a wording-only station still has to start.
        XCTAssertEqual(Set(batch.buckets.map(\.anchor.id)), Set(songs.map(\.id)))
        XCTAssertTrue(Set(songs + neighbors).isSubset(of: Set(batch.tracks)))
        XCTAssertTrue(Set(songs.map(\.id)).isSubset(of: batch.discoveryTrackIDs))
        let radio = await catalog.radioRequests
        XCTAssertEqual(Set(radio.map(\.id)), Set(songs.map(\.id)))
        let artists = await catalog.artistRequests
        XCTAssertTrue(artists.isEmpty, "Undated songs without artist ids have no album evidence to look up")
        let searched = await catalog.searchRequests
        XCTAssertTrue(searched.allSatisfy { $0.query.hasSuffix(" 2015 and later") })
    }

    func testCueStationsStillRequireDatedEvidenceForEraFallbackSeeds() async throws {
        let f = ExperienceRadioFixtures.self
        let experience = station(era: .newer)
        let songs = (0..<4).map { RecommendationFixtures.track("undated-\($0)", title: "2024 song \($0)", artist: "Artist \($0)") }
        let queries = self.queries(experience).map { $0 + " 2015 and later" }
        var searches: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: experience.seeds.map { ($0.query, .success([])) })
        searches[queries[0]] = .success(songs)
        searches[queries[1]] = .success([])
        let catalog = ExperienceRadioCatalogFixture(searches: searches,
            radios: [f.cas.id: .success([]), f.pixies.id: .success([])],
            playlistSearches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success([])) }))
        do {
            _ = try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [], languages: [.english])
            XCTFail("Missing cue recordings do not relax the era for a station that has cues")
        } catch { XCTAssertEqual(error as? ExperienceRadioError, .noSeeds) }
        let radio = await catalog.radioRequests
        XCTAssertTrue(radio.isEmpty)
    }

    func testMoodFallbackUsesAlbumYearEvidenceForSeedsAndAllowsOtherYearsAsRelatedSongs() async throws {
        let experience = station(seeds: [], era: .newer)
        var older = RecommendationFixtures.track("old-song", artist: "Earlier Artist", artistID: "UCearlier")
        older.albumID = "old-album"
        var newer = RecommendationFixtures.track("new-song", artist: "Current Artist", artistID: "UCcurrent")
        newer.albumID = "new-album"
        let related = [RecommendationFixtures.track("related-one", artist: "Related One"), RecommendationFixtures.track("related-two", artist: "Related Two")]
        let queries = self.queries(experience).map { $0 + " 2015 and later" }
        let catalog = ExperienceRadioCatalogFixture(searches: [queries[0]: .success([older, newer] + related), queries[1]: .success([])],
            radios: [newer.id: .success([])], artists: [
                "UCearlier": .success(ArtistPage(id: "UCearlier", name: "Earlier Artist", releases: [
                    RecommendationFixtures.release("old-album", title: "Earlier release", subtitle: "Album · 1995")])),
                "UCcurrent": .success(ArtistPage(id: "UCcurrent", name: "Current Artist", releases: [
                    RecommendationFixtures.release("new-album", title: "Current release", subtitle: "Album · 2019")])),
            ], playlistSearches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success([])) }))
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [], languages: [.english])
        XCTAssertEqual(batch.buckets.map(\.anchor.id), [newer.id], "Dated evidence outranks undated songs as anchors")
        XCTAssertEqual(batch.tracks.first, newer)
        XCTAssertEqual(Set(batch.tracks), Set([older, newer] + related))
        let radio = await catalog.radioRequests
        XCTAssertEqual(radio, [newer])
    }

    func testCancellationDuringMoodFallbackRejectsLateResponsesAndStopsFurtherRequests() async throws {
        let f = ExperienceRadioFixtures.self
        let catalog = AppModelCatalogProvider()
        addTeardownBlock { await catalog.close() }
        let experience = station(seeds: [.init(recording: f.cas, artist: f.melancholy.seeds[0].artist),
                                        .init(recording: f.pixies, artist: f.melancholy.seeds[1].artist)])
        let task = Task { try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: []) }
        defer { task.cancel() }
        for index in 0..<2 {
            let request = try await catalog.autoplayRadios.request(at: index)
            try await catalog.autoplayRadios.complete(request, with: .success([]))
        }
        let searches = [try await catalog.searches.request(at: 0), try await catalog.searches.request(at: 1),
                        try await catalog.searches.request(at: 2)]
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled fallback must not finish a station") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await AppModelFixtures.eventually {
            let cancellations = await catalog.searches.cancellations
            return searches.allSatisfy { cancellations.contains($0.id) }
        }
        for request in searches {
            try await catalog.searches.complete(request, with: .success(CatalogPage(tracks: [f.cas, f.pixies, f.dream, f.alt])))
        }
        let radio = await catalog.autoplayRadios.requests
        let allSearches = await catalog.searches.requests
        XCTAssertEqual(radio.count, 2)
        XCTAssertEqual(allSearches.count, 3)
    }

    func testContinuationCanUseFreshMoodSongsWithoutApplyingTheStartingEraToNeighbors() async throws {
        let f = ExperienceRadioFixtures.self
        let experience = station(era: .older)
        let english = RecommendationFixtures.track("fresh-en", artist: "New Artist", language: .english)
        let unknown = RecommendationFixtures.track("fresh-unknown", artist: "Unclassified Artist")
        let hindi = RecommendationFixtures.track("wrong-language", language: .hindi)
        let blocked = RecommendationFixtures.track("blocked", title: "Blocked Song")
        let catalog = ExperienceRadioCatalogFixture(searches: [queries(experience)[0]: .success([f.dream, english, unknown, hindi, blocked]),
                                                              queries(experience)[1]: .success([])],
            radios: [f.pixies.id: .success([]), f.alt.id: .success([])], playlistSearches: emptyPlaylists(experience))
        let batch = try await ExperienceRadioEngine(catalog: catalog).continueRadio(
            buckets: [.init(anchor: f.pixies, frontier: f.pixies), .init(anchor: f.alt, frontier: f.alt)], round: 0,
            queue: [f.pixies, f.alt, f.dream], disliked: [DislikedSong(id: blocked.id, title: blocked.title, artists: blocked.artists)],
            languages: [.english], experience: experience)
        XCTAssertEqual(Set(batch.tracks), Set([english, unknown]))
        XCTAssertNil(batch.tracks.first { $0.id == unknown.id }?.language)
        let queries = await catalog.searchRequests
        XCTAssertTrue(queries.allSatisfy { !$0.query.contains("before 2000") })
    }

    func testASingleSeedAdvancesItsFrontierAndRecoversAnExhaustedAnchorRevisit() async throws {
        let f = ExperienceRadioFixtures.self
        let next = RecommendationFixtures.track("new-neighbor", title: "New neighboring song", artist: "Another Artist")
        for round in [1, 4] {
            let catalog = ExperienceRadioCatalogFixture(radios: [f.cas.id: .success([]), f.dream.id: .success([next])])
            let batch = try await ExperienceRadioEngine(catalog: catalog).continueRadio(
                buckets: [.init(anchor: f.cas, frontier: f.dream)], round: round, queue: [f.cas, f.dream], disliked: [])
            XCTAssertEqual(batch.tracks, [next])
            XCTAssertEqual(batch.buckets.first?.frontier, next)
            let requests = await catalog.radioRequests
            XCTAssertEqual(requests.map(\.id), round == 1 ? [f.dream.id] : [f.cas.id, f.dream.id])
        }
    }

    private func station(seeds: [RadioExperience.Seed] = ExperienceRadioFixtures.melancholy.seeds,
                         era: RadioEra = .anytime) -> RadioExperience {
        RadioExperience(id: "mood-fixture", title: "Melancholy", description: "Dream pop and indie rock", symbol: "radio",
            discoveryLanguages: [.english], contentLabel: "English", seeds: seeds, defaultEra: era,
            styleQueries: ["dream pop songs", "mellow indie songs"])
    }

    /// The fixture station carries English wording only; other languages get synthesized wording the fixtures never answer.
    private func queries(_ experience: RadioExperience) -> [String] {
        experience.styleQueries(in: [.english])
    }

    private func cueSearches() -> [String: Result<[Track], any Error>] {
        ExperienceRadioFixtures.melancholySearches.mapValues { .success([$0]) }
    }

    private func emptyPlaylists(_ experience: RadioExperience) -> [String: Result<[MusicCollection], any Error>] {
        Dictionary(uniqueKeysWithValues: queries(experience).map { ($0, .success([])) })
    }
}
