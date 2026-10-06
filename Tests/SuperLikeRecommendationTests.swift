import XCTest
@testable import GanaBajana

final class SuperLikeRecommendationTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures
    private typealias Engine = RecommendationEngine
    private let day = "2026-05-28"
    private let nextDay = "2026-05-29"
    private let week = "2026-W22"
    private let nextWeek = "2026-W23"
    private let heartless = RecommendationFixtures.track("super-heartless", title: "Heartless", artist: "Kanye West", artistID: "UCkanye")
    private let runaway = RecommendationFixtures.track("super-runaway", title: "Runaway", artist: "Kanye West", artistID: "UCkanye")

    // MARK: Seeds

    func testSeedsReserveOneSuperLikeWithinTheBudgetAndKeepANaturalPick() {
        let strong = songs("strong", count: 6)
        let profile = taste(events: plays(strong), superLiked: [heartless])
        XCTAssertFalse(profile.isColdStart)
        XCTAssertEqual(profile.superLikedTrackIDs, [heartless.id])
        XCTAssertEqual(profile.trackAffinity[heartless.id] ?? 0, TasteProfile.superLikeBoost, accuracy: 1e-9)
        let threePlays = profile.trackAffinity["strong-0"] ?? 0
        XCTAssertEqual(threePlays, Self.threeFullPlays, accuracy: 1e-9)
        XCTAssertEqual(profile.topTracks(limit: 4).map(\.id), ["strong-0", "strong-1", "strong-2", "strong-3"],
                       "Three full plays outrank a super like, so the natural seeds carry none")
        let languageProfiles: [ListeningLanguageProfile?] = [nil, ListeningLanguageProfile()]
        for languageProfile in languageProfiles {
            let seeds = Engine.Seeds(profile: profile, languageProfile: languageProfile, periodKey: day)
            XCTAssertEqual(seeds.tracks.count, Engine.seedTrackCount)
            XCTAssertEqual(ids(seeds), ["strong-0", "strong-1", "strong-2", heartless.id], "The weakest natural seed gives way")
            XCTAssertEqual(seeds.tracks.map(\.weight), [1, 1, 1, TasteProfile.superLikeBoost / threePlays])
            XCTAssertTrue(seeds.tracks.allSatisfy { $0.scope == 0 })
            XCTAssertEqual(seeds.artists.map(\.id), ["UCstrong-0", "UCstrong-1", "UCstrong-2"])
        }

        let listened = taste(events: plays(strong) + plays([heartless]), superLiked: [heartless])
        XCTAssertEqual(listened.topTracks(limit: 4).first?.id, heartless.id)
        let listenedPlays = listened.trackAffinity["strong-0"] ?? 0
        let listenedSuper = listened.trackAffinity[heartless.id] ?? 0
        XCTAssertEqual(listenedPlays, Self.threeFullPlays, accuracy: 1e-9)
        XCTAssertEqual(listenedSuper, Self.threeFullPlays + TasteProfile.superLikeBoost, accuracy: 1e-9)
        for languageProfile in languageProfiles {
            let seeds = Engine.Seeds(profile: listened, languageProfile: languageProfile, periodKey: day)
            XCTAssertEqual(ids(seeds), listened.topTracks(limit: 4).map(\.id), "A naturally seeded super like changes nothing")
            let ratio = listenedPlays / listenedSuper
            XCTAssertEqual(seeds.tracks.map(\.weight), [1, ratio, ratio, ratio])
        }
    }

    func testSeedReservationRotatesBetweenSuperLikesByPeriodKey() {
        let profile = taste(events: plays(songs("strong", count: 6)), superLiked: [heartless, runaway])
        let superIDs: Set<String> = [heartless.id, runaway.id]
        var picks: [String: String] = [:]
        for key in [day, nextDay, week, nextWeek] {
            let seeds = Engine.Seeds(profile: profile, languageProfile: nil, periodKey: key)
            let chosen = seeds.tracks.filter { superIDs.contains($0.track.id) }
            XCTAssertEqual(seeds.tracks.count, Engine.seedTrackCount)
            XCTAssertEqual(chosen.count, 1, "Exactly one seed is a super like for \(key)")
            XCTAssertEqual(chosen.first?.track.id, rotatingID(superIDs, periodKey: key), "Highest jitter wins for \(key)")
            let again = Engine.Seeds(profile: profile, languageProfile: nil, periodKey: key)
            XCTAssertEqual(ids(again), ids(seeds), "The same period key always seeds the same super like")
            picks[key] = chosen.first?.track.id
        }
        for (first, second) in [(day, nextDay), (week, nextWeek)] {
            if rotatingID(superIDs, periodKey: first) != rotatingID(superIDs, periodKey: second) {
                XCTAssertEqual(Set([picks[first], picks[second]].compactMap { $0 }), superIDs, "\(first) and \(second) rotate")
            } else {
                XCTAssertEqual(picks[first], picks[second])
            }
        }
        XCTAssertNotEqual(rotatingID(superIDs, periodKey: day), rotatingID(superIDs, periodKey: nextDay),
                          "Fixture ids are chosen so consecutive days seed different super likes")
    }

    func testIneligibleSuperLikesAreSkippedAndSeedsMatchAProfileWithoutSuperLikes() {
        let strong = songs("strong", count: 6)
        let video = Fixtures.track("super-video", title: "Live Clip", artist: "Video Artist", artistID: "UCvideo", audio: false)
        let blocked = Fixtures.track("super-blocked", title: "Blocked", artist: "Blocked Artist", artistID: "UCblocked")
        let ghost = Fixtures.track("", title: "Ghost", artist: "Ghost Artist", artistID: "UCghost")
        let profile = taste(events: plays(strong), superLiked: [video, blocked, ghost], disliked: [blocked])
        let plain = taste(events: plays(strong), favorites: [video, blocked, ghost], disliked: [blocked])
        XCTAssertEqual(profile.superLikedTrackIDs, [video.id], "A dislike and an empty id never register as super likes")
        XCTAssertTrue(Engine.eligibleSuperLikes(profile).isEmpty)
        let languageProfiles: [ListeningLanguageProfile?] = [nil, ListeningLanguageProfile()]
        for languageProfile in languageProfiles {
            for key in [day, week] {
                let seeds = Engine.Seeds(profile: profile, languageProfile: languageProfile, periodKey: key)
                let baseline = Engine.Seeds(profile: plain, languageProfile: languageProfile, periodKey: key)
                XCTAssertEqual(ids(seeds), ["strong-0", "strong-1", "strong-2", "strong-3"])
                XCTAssertEqual(ids(seeds), ids(baseline))
                XCTAssertEqual(seeds.tracks.map(\.weight), baseline.tracks.map(\.weight))
                XCTAssertEqual(seeds.tracks.map(\.scope), baseline.tracks.map(\.scope))
                XCTAssertEqual(seeds.artists.map(\.id), baseline.artists.map(\.id))
                XCTAssertEqual(seeds.artists.map(\.weight), baseline.artists.map(\.weight))
            }
        }
    }

    // MARK: Daily Mix composition

    func testDailyMixLeadsTheFamiliarPortionWithTheDaysSuperLikeAndKeepsTheRestInOrder() {
        let known = songs("known", count: 32)
        let profile = taste(events: plays(known), superLiked: [heartless])
        let plain = taste(events: plays(known))
        let fresh = songs("fresh", count: 40)
        let natural = Engine.weightedShuffle(profile.trackAffinity, periodKey: day)
        XCTAssertGreaterThan(natural.firstIndex(of: heartless.id) ?? -1, 0, "The fixture must rely on the reservation, not luck")
        let expectations: [(DiscoveryFamiliarity, Int)] = [(.familiar, 18), (.balanced, 10), (.newMusic, 4)]
        for (mode, target) in expectations {
            let mix = compose(ranked: fresh, profile: profile, mode: mode)
            XCTAssertEqual(mix.count, Engine.dailyMixTarget)
            let heard = familiar(mix, profile: profile)
            XCTAssertEqual(heard.count, target)
            XCTAssertEqual(heard.first?.id, heartless.id)
            XCTAssertEqual(heard.dropFirst().map(\.id), Array(natural.filter { $0 != heartless.id }.prefix(target - 1)),
                           "Only the super like moves; the familiar order behind it is untouched")
            assertArtistCap(mix)

            let plainMix = compose(ranked: fresh, profile: plain, mode: mode)
            XCTAssertEqual(familiar(plainMix, profile: plain).map(\.id),
                           Array(Engine.weightedShuffle(plain.trackAffinity, periodKey: day).prefix(target)),
                           "A pool without super likes keeps the natural order exactly")
        }
    }

    func testDailyMixSuperLikeCountsAgainstTheArtistCapWithoutExtraSlots() {
        let kanye = (1...3).map { Fixtures.track("kanye-\($0)", title: "Kanye \($0)", artist: "Kanye West", artistID: "UCkanye") }
        let known = songs("known", count: 15)
        let profile = taste(events: plays(known + kanye), superLiked: [heartless])
        let natural = Engine.weightedShuffle(profile.trackAffinity, periodKey: day)
        XCTAssertEqual(Set(natural.prefix(3)), Set(kanye.map(\.id)), "Three listened Kanye songs lead naturally")
        let mix = compose(ranked: songs("fresh", count: 40), profile: profile, mode: .familiar)
        XCTAssertEqual(mix.count, Engine.dailyMixTarget)
        let heard = familiar(mix, profile: profile)
        XCTAssertEqual(heard.count, 18, "Nineteen heard songs minus the fourth Kanye song fill the familiar share")
        XCTAssertEqual(heard.first?.id, heartless.id)
        XCTAssertEqual(artistCounts(mix)["kanye west"], Engine.dailyMixArtistCap, "The super like uses one of the three Kanye slots")
        XCTAssertEqual(heard.dropFirst().prefix(2).map(\.id), Array(natural.prefix(2)))
        XCTAssertFalse(mix.contains { $0.id == natural[2] }, "The third natural Kanye pick loses its slot to the super like")
        assertArtistCap(mix)
    }

    func testDailyMixSkipsSuperLikesExcludedByAnotherMixOrOutsideTheScope() {
        let known = songs("known", count: 32)
        let profile = taste(events: plays(known), superLiked: [heartless])
        let fresh = songs("fresh", count: 40)
        let natural = Engine.weightedShuffle(profile.trackAffinity, periodKey: day).filter { $0 != heartless.id }

        let excluded = compose(ranked: fresh, profile: profile, mode: .balanced, excluded: [heartless.id])
        XCTAssertFalse(excluded.contains { $0.id == heartless.id })
        XCTAssertEqual(familiar(excluded, profile: profile).map(\.id), Array(natural.prefix(10)))

        let elsewhere = compose(ranked: fresh, profile: profile, mode: .balanced, belongs: { $0.id != self.heartless.id })
        XCTAssertFalse(elsewhere.contains { $0.id == heartless.id })
        XCTAssertEqual(familiar(elsewhere, profile: profile).map(\.id), Array(natural.prefix(10)))

        // A heard provider neighbour outside the scope reaches the pool but never the reserved head.
        var scoped = profile.trackAffinity
        scoped.removeValue(forKey: heartless.id)
        let neighbour = compose(ranked: fresh + [heartless], familiarWeights: scoped, profile: profile, mode: .balanced,
                                belongs: { $0.id != self.heartless.id })
        XCTAssertFalse(neighbour.contains { $0.id == heartless.id })
        XCTAssertEqual(familiar(neighbour, profile: profile).map(\.id), Array(natural.prefix(10)))
    }

    // MARK: Scoped seeds

    func testScopedSeedsPlaceTheReservedSuperLikeInItsOwningScope() {
        let hindi: [Track] = [("Arijit Singh", "UCarijit"), ("Pritam", "UCpritam")].flatMap { pair -> [Track] in
            (0..<2).map { Fixtures.track("hi-\(pair.1)-\($0)", artist: pair.0, artistID: pair.1) }
        }
        let english: [Track] = [("Drake", "UCdrake"), ("Kendrick Lamar", "UCkendrick")].flatMap { pair -> [Track] in
            (0..<2).map { Fixtures.track("en-\(pair.1)-\($0)", artist: pair.0, artistID: pair.1) }
        }
        let profile = taste(events: plays(hindi + english), superLiked: [runaway])
        let plain = taste(events: plays(hindi + english), favorites: [runaway])
        let hindiScope = MixScope(kind: .dailyMix, artistKeys: ["arijit singh", "pritam"])
        let englishScope = MixScope(kind: .dailyMix2, artistKeys: ["drake", "kendrick lamar", "kanye west"])
        let scopes = [hindiScope, englishScope]
        let seeds = Engine.scopedSeeds(profile: profile, scopes: scopes, ownership: .init(scopes: scopes), languageProfile: nil,
                                       periodKey: day)
        let baseline = Engine.scopedSeeds(profile: plain, scopes: scopes, ownership: .init(scopes: scopes), languageProfile: nil,
                                          periodKey: day)
        XCTAssertEqual(ids(baseline), ["hi-UCarijit-0", "hi-UCarijit-1", "en-UCdrake-0", "en-UCdrake-1"])
        XCTAssertEqual(seeds.tracks.count, Engine.seedTrackCount)
        XCTAssertEqual(seeds.tracks.map(\.scope), [0, 0, 1, 1], "Both scopes keep their two seeds")
        XCTAssertEqual(ids(seeds), ["hi-UCarijit-0", "hi-UCarijit-1", "en-UCdrake-0", runaway.id],
                       "The super like replaces the weakest seed of the scope that owns Kanye West")
        let threePlays = profile.trackAffinity["hi-UCarijit-0"] ?? 0
        XCTAssertEqual(threePlays, Self.threeFullPlays, accuracy: 1e-9)
        XCTAssertEqual(seeds.tracks.map(\.weight), [1, 1, 1, TasteProfile.superLikeBoost / threePlays])
        XCTAssertEqual(seeds.artists.map(\.id), baseline.artists.map(\.id))

        // Nothing is reserved when no scope owns the super like or its owner filters it out.
        let unowned = [hindiScope, MixScope(kind: .dailyMix2, artistKeys: ["drake", "kendrick lamar"])]
        let filtered = [hindiScope, MixScope(kind: .dailyMix2, artistKeys: englishScope.artistKeys, includes: { $0.id != "super-runaway" })]
        for scopes in [unowned, filtered] {
            let seeds = Engine.scopedSeeds(profile: profile, scopes: scopes, ownership: .init(scopes: scopes), languageProfile: nil,
                                           periodKey: day)
            XCTAssertEqual(ids(seeds), ids(baseline))
            XCTAssertEqual(seeds.tracks.map(\.weight), baseline.tracks.map(\.weight))
            XCTAssertEqual(seeds.tracks.map(\.scope), baseline.tracks.map(\.scope))
        }
    }

    // MARK: Engine

    func testDiscoverWeeklySeedsWithTheSuperLikeButNeverIncludesIt() async throws {
        let strong = songs("strong", count: 6)
        let profile = taste(events: plays(strong), superLiked: [heartless])
        let fresh = songs("fresh", count: 16)
        let catalog = await catalog(seeds: strong + [heartless], returning: fresh + [heartless])
        let engine = RecommendationEngine(catalog: catalog, now: { Fixtures.now })
        let weekly = try await engine.discoverWeekly(profile: profile, languages: [], periodKey: week,
                                                     languageProfile: ListeningLanguageProfile())
        let playlist = try XCTUnwrap(weekly)
        XCTAssertEqual(playlist.tracks.count, fresh.count)
        XCTAssertFalse(playlist.tracks.contains { $0.id == heartless.id }, "A heard super like never enters Discover Weekly")
        XCTAssertTrue(playlist.tracks.allSatisfy { !profile.heardTrackIDs.contains($0.id) })
        let seeds = await catalog.unrestrictedRadioRequests.map(\.id)
        XCTAssertEqual(seeds.count, Engine.seedTrackCount)
        XCTAssertTrue(seeds.contains(heartless.id), "The reserved super like still seeds the week")
        XCTAssertEqual(Set(seeds).count, seeds.count)
    }

    func testDailyMixThroughTheEngineLeadsWithTheSuperLike() async throws {
        let strong = songs("strong", count: 6)
        let profile = taste(events: plays(strong), superLiked: [heartless])
        let fresh = songs("fresh", count: 16)
        let natural = Engine.weightedShuffle(profile.trackAffinity, periodKey: day)
        XCTAssertNotEqual(natural.first, heartless.id, "The fixture must rely on the reservation, not luck")
        let catalog = await catalog(seeds: strong + [heartless], returning: fresh + [heartless])
        let engine = RecommendationEngine(catalog: catalog, now: { Fixtures.now })
        let daily = try await engine.dailyMix(profile: profile, languages: [], periodKey: day, languageProfile: ListeningLanguageProfile())
        let mix = try XCTUnwrap(daily)
        let heard = familiar(mix.tracks, profile: profile)
        XCTAssertEqual(heard.first?.id, heartless.id)
        XCTAssertEqual(heard.map(\.id), [heartless.id] + natural.filter { $0 != heartless.id })
        XCTAssertEqual(mix.tracks.count, strong.count + 1 + fresh.count)
        let seeds = await catalog.unrestrictedRadioRequests.map(\.id)
        XCTAssertTrue(seeds.contains(heartless.id))
    }

    func testScopedMixesPlaceTheSuperLikeAtTheHeadOfItsOwnMixOnly() async throws {
        let hindiArtists = [("Arijit Singh", "UCarijit"), ("Pritam", "UCpritam"), ("Shreya Ghoshal", "UCshreya")]
        let englishArtists = [("Drake", "UCdrake"), ("Kendrick Lamar", "UCkendrick"), ("Kanye West", "UCkanye")]
        func heard(_ artists: [(String, String)], prefix: String, count: Int) -> [Track] {
            artists.flatMap { name, id in (0..<count).map { Fixtures.track("\(prefix)-\(id)-\($0)", artist: name, artistID: id) } }
        }
        let hindi = heard(hindiArtists, prefix: "hi", count: 3)
        let english = heard(Array(englishArtists.prefix(2)), prefix: "en", count: 3) + heard([englishArtists[2]], prefix: "en", count: 2)
        let profile = taste(events: plays(hindi + english), superLiked: [heartless])
        let hindiFresh = (0..<16).map { Fixtures.track("hi-new-\($0)", artist: "Hindi newcomer \($0)") }
        let englishFresh = (0..<16).map { Fixtures.track("en-new-\($0)", artist: "English newcomer \($0)") }
        let catalog = RecommendationCatalogMock()
        for track in hindi { await catalog.setRadio(hindiFresh, for: track.id) }
        for track in english + [heartless] { await catalog.setRadio(englishFresh + [heartless], for: track.id) }
        for (name, id) in hindiArtists + englishArtists { await catalog.setArtist(Fixtures.page(id, name: name)) }
        let scopes = [MixScope(kind: .dailyMix, artistKeys: hindiArtists.map { TasteProfile.normalizedArtistName($0.0) }),
                      MixScope(kind: .dailyMix2, artistKeys: englishArtists.map { TasteProfile.normalizedArtistName($0.0) })]
        let engine = RecommendationEngine(catalog: catalog, now: { Fixtures.now })
        let mixes = try await engine.scopedMixes(profile: profile, scopes: scopes, periodKey: day)
        XCTAssertEqual(mixes.map(\.kind), [.dailyMix, .dailyMix2])
        let first = try XCTUnwrap(mixes.first)
        let second = try XCTUnwrap(mixes.last)
        XCTAssertFalse(first.tracks.contains { $0.id == heartless.id }, "The Hindi mix does not own the super like")
        XCTAssertEqual(familiar(second.tracks, profile: profile).first?.id, heartless.id)
        XCTAssertEqual(familiar(second.tracks, profile: profile).count, english.count + 1)
        for mix in mixes {
            XCTAssertEqual(mix.tracks.count, Engine.dailyMixTarget)
            assertArtistCap(mix.tracks)
        }
        let seeds = await catalog.radioRequests.map(\.seed.id)
        let hindiIDs = Set(hindi.map(\.id))
        XCTAssertEqual(seeds.count, Engine.seedTrackCount)
        XCTAssertTrue(seeds.contains(heartless.id), "The English scope spends one of its two seeds on the super like")
        XCTAssertEqual(seeds.filter(hindiIDs.contains).count, 2, "The Hindi scope keeps both seeds")
        let calls = await catalog.callCount
        XCTAssertLessThanOrEqual(calls, Engine.providerCallBudget)
    }

    // MARK: Helpers

    /// Distinct-artist recordings, each linked to its own channel so artist seeds stay comparable across profiles.
    private func songs(_ prefix: String, count: Int) -> [Track] {
        (0..<count).map { Fixtures.track("\(prefix)-\($0)", artist: "Artist \(prefix)-\($0)", artistID: "UC\(prefix)-\($0)") }
    }

    /// Three full plays today give 720 listened seconds plus the completion and replay bonuses, about 995, above a
    /// super like's 540, so a reservation must displace a natural pick.
    private func plays(_ tracks: [Track], times: Int = 3) -> [ListeningEvent] {
        tracks.flatMap { track in (0..<times).map { _ in Fixtures.event(track, daysAgo: 0, seconds: 240) } }
    }

    private static let threeFullPlays = 3 * 240 * (1 + TasteProfile.completionBonus) + TasteProfile.replayBonus(plays: 3)

    private func taste(events: [ListeningEvent], favorites: [Track] = [], superLiked: [Track] = [],
                       disliked: [Track] = []) -> TasteProfile {
        TasteProfile.build(events: events, favorites: favorites + superLiked, playlists: [], recents: [],
                           disliked: disliked.map { DislikedSong(id: $0.id, title: $0.title, artists: $0.artists, dislikedAt: Fixtures.now) },
                           superLikedIDs: Set(superLiked.map(\.id)), now: Fixtures.now)
    }

    /// Independent restatement of the rotation rule: highest jitter wins, the smaller id on a tie.
    private func rotatingID(_ ids: Set<String>, periodKey: String) -> String? {
        ids.max { left, right in
            let a = Engine.jitter(periodKey: periodKey, id: left)
            let b = Engine.jitter(periodKey: periodKey, id: right)
            return a == b ? left > right : a < b
        }
    }

    private func compose(ranked: [Track], familiarWeights: [String: Double]? = nil, profile: TasteProfile, mode: DiscoveryFamiliarity,
                         belongs: (Track) -> Bool = { _ in true }, excluded: Set<String> = []) -> [Track] {
        Engine.composeDailyMix(ranked: ranked, familiarWeights: familiarWeights ?? profile.trackAffinity, profile: profile,
                               languages: [], languageProfile: nil, familiarity: mode, periodKey: day,
                               belongs: belongs, excluded: excluded)
    }

    private func catalog(seeds: [Track], returning tracks: [Track]) async -> RecommendationCatalogMock {
        let catalog = RecommendationCatalogMock()
        for seed in seeds {
            await catalog.setRadio(tracks, for: seed.id)
            if let id = seed.artistID { await catalog.setArtist(Fixtures.page(id, name: seed.artistName)) }
        }
        return catalog
    }

    private func ids(_ seeds: Engine.Seeds) -> [String] { seeds.tracks.map(\.track.id) }

    private func familiar(_ tracks: [Track], profile: TasteProfile) -> [Track] {
        tracks.filter { profile.heardTrackIDs.contains($0.id) }
    }

    private func artistCounts(_ tracks: [Track]) -> [String: Int] {
        tracks.reduce(into: [:]) { $0[Engine.primaryArtistKey($1), default: 0] += 1 }
    }

    private func assertArtistCap(_ tracks: [Track], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(tracks.map(\.id)).count, tracks.count, file: file, line: line)
        XCTAssertTrue(artistCounts(tracks).values.allSatisfy { $0 <= Engine.dailyMixArtistCap }, file: file, line: line)
    }
}
