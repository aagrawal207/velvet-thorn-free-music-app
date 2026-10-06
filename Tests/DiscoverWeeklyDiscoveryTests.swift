import XCTest
@testable import GanaBajana

/// Discover Weekly's discovery rules on the production radio path: same-song exclusion, likely-known hits and
/// the deep-cut share.
@MainActor
final class DiscoverWeeklyDiscoveryTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures
    private typealias Candidate = RecommendationEngine.Candidate

    // MARK: Same song under another id

    func testAHeardOrDislikedSongNeverReturnsUnderAnotherUploadProviderOrVersion() async throws {
        let seeds = songs("seed", count: 4)
        let kesariya = Fixtures.track("yt-kesariya", title: "Kesariya", artist: "Arijit Singh")
        let blocked = Fixtures.track("yt-blocked", title: "Blocked Song", artist: "Blocked Artist")
        let profile = TasteProfile.build(events: seeds.map { Fixtures.event($0, daysAgo: 0, seconds: 240) },
                                         favorites: [kesariya], playlists: [], recents: [],
                                         disliked: [DislikedSong(id: blocked.id, title: blocked.title, artists: blocked.artists)],
                                         now: Fixtures.now)
        let copies = [
            Fixtures.track("yt-kesariya-reupload", title: "Kesariya", artist: "Arijit Singh"),
            Fixtures.track("saavn:kesariya", title: "Kesariya (From \"Brahmastra\")", artist: "Arijit Singh"),
            Fixtures.track("yt-kesariya-remix", title: "Kesariya - Remix", artist: "ARIJIT SINGH "),
            Fixtures.track("yt-blocked-live", title: "Blocked Song (Live)", artist: "Blocked Artist"),
        ]
        let fresh = songs("fresh", count: 30)
        let catalog = await catalog(seeds: seeds, radio: copies + fresh)
        let result = try await weekly(catalog, profile: profile)
        let playlist = try XCTUnwrap(result)
        XCTAssertEqual(playlist.tracks.count, 30)
        XCTAssertTrue(Set(playlist.tracks.map(\.id)).isDisjoint(with: copies.map(\.id)))
        XCTAssertTrue(Set(playlist.tracks.map(\.id)).isSubset(of: fresh.map(\.id)))
    }

    func testTwoIdsOfOneUnheardSongAppearOnce() async throws {
        let seeds = songs("seed", count: 4)
        let profile = taste(seeds)
        let youtube = Fixtures.track("yt-new", title: "Fresh Song", artist: "Fresh Artist")
        let saavn = Fixtures.track("saavn:new", title: "Fresh Song (From \"A Film\")", artist: "Fresh Artist")
        // Fewer candidates than the Weekly holds, so only the duplicate rule can leave one of the pair out.
        let catalog = await catalog(seeds: seeds, radio: [youtube, saavn] + songs("fresh", count: 20))
        let result = try await weekly(catalog, profile: profile)
        let playlist = try XCTUnwrap(result)
        XCTAssertEqual(playlist.tracks.filter { [youtube.id, saavn.id].contains($0.id) }.count, 1)
        XCTAssertEqual(playlist.tracks.count, 21)
    }

    // MARK: Likely-known hits

    func testAFamiliarArtistsTopFiveHitsAreSkippedWhileDeeperSongsAndNewArtistsHitsStay() async throws {
        let seeds = (0..<4).map { Fixtures.track("seed-\($0)", artist: "Familiar \($0)", artistID: "UCfamiliar\($0)") }
        let profile = taste(seeds)
        let familiarTop = (0..<8).map { Fixtures.track("familiar-top-\($0)", artist: "Familiar 0", artistID: "UCfamiliar0") }
        let newcomerTop = (0..<5).map { Fixtures.track("newcomer-top-\($0)", artist: "Newcomer \($0)", artistID: "UCnew") }
        // Fewer radio songs than the Weekly holds, so every eligible top song makes the list.
        let catalog = await catalog(seeds: seeds, radio: songs("fresh", count: 20))
        await catalog.setArtist(Fixtures.page("UCfamiliar0", name: "Familiar 0", topSongs: familiarTop,
                                              related: [Fixtures.relatedArtist("UCnew", name: "Newcomer")]))
        await catalog.setArtist(Fixtures.page("UCnew", name: "Newcomer", topSongs: newcomerTop))
        for index in 1..<4 { await catalog.setArtist(Fixtures.page("UCfamiliar\(index)", name: "Familiar \(index)")) }

        let result = try await weekly(catalog, profile: profile, mode: .familiar)
        let playlist = try XCTUnwrap(result)
        let ids = Set(playlist.tracks.map(\.id))
        XCTAssertTrue(ids.isDisjoint(with: familiarTop.prefix(5).map(\.id)), "The familiar artist's top five are likely known")
        XCTAssertEqual(ids.intersection(familiarTop.dropFirst(5).map(\.id)).count, 2, "Deeper songs stay, within the artist cap")
        XCTAssertTrue(Set(newcomerTop.map(\.id)).isSubset(of: ids), "A new artist's hits are discoveries")
    }

    // MARK: Deep-cut share

    func testDeepCutShareFollowsDiscoveryBalanceAndIsSpreadThroughTheList() async throws {
        let seeds = songs("seed", count: 4)
        let profile = taste(seeds)
        let popular = songs("popular", count: 40)
        let deep = (0..<4).map { songs("deep\($0)", count: 10) }
        for (mode, expected) in [(DiscoveryFamiliarity.familiar, 6), (.balanced, 11), (.newMusic, 15)] {
            let catalog = RecommendationCatalogMock()
            // Popular songs appear in every seed's radio; each deep cut appears once, past the radio's first ten.
            for (index, seed) in seeds.enumerated() { await catalog.setRadio(popular + deep[index], for: seed.id) }
            let result = try await weekly(catalog, profile: profile, mode: mode)
            let playlist = try XCTUnwrap(result)
            let deepIDs = Set(deep.flatMap { $0 }.map(\.id))
            let positions = playlist.tracks.indices.filter { deepIDs.contains(playlist.tracks[$0].id) }
            XCTAssertEqual(playlist.tracks.count, 30)
            XCTAssertEqual(positions.count, expected, "\(mode)")
            XCTAssertLessThan(positions.first ?? 30, 6, "Deep cuts start near the top in \(mode)")
            XCTAssertGreaterThan(positions.last ?? 0, 23, "Deep cuts reach the end in \(mode)")
            let calls = await catalog.callCount
            XCTAssertEqual(calls, 4, "No extra provider calls for the quota")
            let repeated = try await weekly(catalog, profile: profile, mode: mode)
            XCTAssertEqual(playlist.tracks, repeated?.tracks, "Stable within the week")
        }
    }

    func testTooFewDeepCutsNeverShrinkTheWeekly() async throws {
        let seeds = songs("seed", count: 4)
        let profile = taste(seeds)
        let popular = songs("popular", count: 40)
        let deep = songs("deep", count: 2)
        let catalog = RecommendationCatalogMock()
        for (index, seed) in seeds.enumerated() { await catalog.setRadio(popular + (index == 0 ? deep : []), for: seed.id) }
        let result = try await weekly(catalog, profile: profile, mode: .newMusic)
        let playlist = try XCTUnwrap(result)
        XCTAssertEqual(playlist.tracks.count, 30)
        XCTAssertEqual(playlist.tracks.filter { deep.map(\.id).contains($0.id) }.count, 2)
    }

    // MARK: Popularity estimate

    func testPlayCountPercentilesAreComparedOnlyWithinOneSource() {
        let saavn = (1...10).map { candidate("saavn:\($0)", plays: Int64($0) * 1_000_000) }
        let youtube = (1...10).map { candidate("yt-\($0)", plays: Int64($0) * 1_000) }
        let popularity = WeeklyPopularity(saavn + youtube)
        XCTAssertEqual(popularity.knownCount, 20)
        XCTAssertTrue(popularity.isDeepCut(saavn[3]), "4M plays is the lower part of JioSaavn's counts here")
        XCTAssertFalse(popularity.isDeepCut(youtube[8]), "9K plays is a hit among YouTube's counts, whatever JioSaavn says")
        XCTAssertTrue(popularity.isDeepCut(youtube[0]))
        XCTAssertFalse(popularity.isDeepCut(saavn[9]))
    }

    func testMissingOrTooFewCountsFallBackToHarvestEvidence() {
        var hit = candidate("hit", plays: nil)
        hit.bestTopSongsPosition = 0
        var tail = candidate("tail", plays: nil)
        tail.bestRadioPosition = 25
        var early = candidate("early", plays: nil)
        early.bestRadioPosition = 3
        var shared = candidate("shared", plays: nil)
        shared.bestRadioPosition = 25
        shared.lists = 3
        let lonely = candidate("lonely-count", plays: 10)
        let popularity = WeeklyPopularity([hit, tail, early, shared, lonely])
        XCTAssertEqual(popularity.knownCount, 0, "One known count is not enough for a percentile")
        XCTAssertFalse(popularity.isDeepCut(hit), "A top song is a hit")
        XCTAssertTrue(popularity.isDeepCut(tail), "One radio, past its first ten")
        XCTAssertFalse(popularity.isDeepCut(early))
        XCTAssertFalse(popularity.isDeepCut(shared), "Several seeds surfacing it marks it popular")
        XCTAssertFalse(popularity.isDeepCut(lonely), "A missing percentile is unknown, never unpopular by count alone")
    }

    func testSongIdentityMatchesVersionsAndProvidersButNotOtherArtists() {
        let original = Fixtures.track("a", title: "Tum Hi Ho", artist: "Arijit Singh")
        let movie = Fixtures.track("saavn:b", title: "Tum Hi Ho (From \"Aashiqui 2\")", artist: "arijit singh")
        let cover = Fixtures.track("c", title: "Tum Hi Ho", artist: "A Cover Singer")
        XCTAssertEqual(SongIdentity.key(original), SongIdentity.key(movie))
        XCTAssertNotEqual(SongIdentity.key(original), SongIdentity.key(cover))
        XCTAssertNil(SongIdentity.key(title: "(Intro)", primaryArtist: "Someone"), "A title with no core has no identity")
    }

    // MARK: Helpers

    private func candidate(_ id: String, plays: Int64?) -> Candidate {
        var track = Fixtures.track(id, artist: "Artist \(id)")
        track.playCount = plays
        var candidate = Candidate(track: track, score: 1, order: 0)
        candidate.lists = 1
        candidate.bestRadioPosition = 5
        return candidate
    }

    private func songs(_ prefix: String, count: Int) -> [Track] {
        (0..<count).map { Fixtures.track("\(prefix)-\($0)", artist: "Artist \(prefix)-\($0)") }
    }

    private func taste(_ tracks: [Track]) -> TasteProfile {
        TasteProfile.build(events: tracks.map { Fixtures.event($0, daysAgo: 0, seconds: 240) }, favorites: [], playlists: [],
                           recents: [], now: Fixtures.now)
    }

    private func catalog(seeds: [Track], radio: [Track]) async -> RecommendationCatalogMock {
        let catalog = RecommendationCatalogMock()
        for seed in seeds { await catalog.setRadio(radio, for: seed.id) }
        return catalog
    }

    private func weekly(_ catalog: RecommendationCatalogMock, profile: TasteProfile,
                        mode: DiscoveryFamiliarity = .balanced) async throws -> GeneratedPlaylist? {
        try await RecommendationEngine(catalog: catalog, now: { Fixtures.now })
            .discoverWeekly(profile: profile, languages: [], periodKey: "2026-W22", languageProfile: ListeningLanguageProfile(),
                            familiarity: mode)
    }
}
