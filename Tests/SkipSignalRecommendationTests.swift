import XCTest
@testable import GanaBajana

/// Skips, finished plays and replays in recommendations: the weights, the rest rule, affinity, and every surface
/// that reads them, on the production engine paths with canned catalogs.
@MainActor
final class SkipSignalRecommendationTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures
    private typealias Weights = ListeningSignalWeights
    private typealias Engine = RecommendationEngine
    private typealias Candidate = RecommendationEngine.Candidate
    private let now = RecommendationFixtures.now
    private let week = "2026-W22"
    private let day = "2026-05-28"

    // MARK: Skip weights

    func testSkipStrengthSeparatesEarlyMildLightAndLateSkips() {
        XCTAssertEqual(Weights.skipStrength(listenedSeconds: 5, duration: 240), 1, "Five seconds is a clear no")
        XCTAssertEqual(Weights.skipStrength(listenedSeconds: 9.9, duration: 240), Weights.strongSkip)
        XCTAssertEqual(Weights.skipStrength(listenedSeconds: 10, duration: 240), Weights.mildSkip)
        XCTAssertEqual(Weights.skipStrength(listenedSeconds: 29.9, duration: 240), 0.4)
        XCTAssertEqual(Weights.skipStrength(listenedSeconds: 60, duration: 240), 0.15, "A minute in is a fair try")
        XCTAssertEqual(Weights.skipStrength(listenedSeconds: 119.9, duration: 240), Weights.lightSkip)
        XCTAssertEqual(Weights.skipStrength(listenedSeconds: 120, duration: 240), 0, "Half the song is not a judgement")
        XCTAssertEqual(Weights.skipStrength(listenedSeconds: 200, duration: 240), 0)
        XCTAssertEqual(Weights.skipStrength(listenedSeconds: 60, duration: nil), Weights.lightSkip)
        let song = Fixtures.track("song")
        XCTAssertEqual(Weights.skipWeight(skip(song, seconds: 5), now: now), 1)
        XCTAssertEqual(Weights.skipWeight(skip(song, seconds: 60), now: now), 0.15)
        XCTAssertEqual(Weights.skipWeight(skip(song, seconds: 130), now: now), 0)
        XCTAssertEqual(Weights.skipWeight(finish(song), now: now), 0, "A finished song carries no negative weight")
    }

    func testChosenAndRapidContextsHalveTheWeightAndCompose() {
        let song = Fixtures.track("song")
        XCTAssertEqual(Weights.skipWeight(skip(song, origin: .chosen), now: now), 0.5, "Skipping through your own list is often searching")
        XCTAssertEqual(Weights.skipWeight(skip(song, rapid: true), now: now), 0.5, "Flicking through is not judging")
        XCTAssertEqual(Weights.skipWeight(skip(song, origin: .chosen, rapid: true), now: now), 0.25)
        XCTAssertEqual(Weights.skipWeight(skip(song, seconds: 20, origin: .chosen), now: now), 0.2, accuracy: 1e-12)

        let seeds = songs("seed", count: 4)
        XCTAssertFalse(taste(seeds, signals: [skip(song, origin: .chosen), skip(song, origin: .chosen)]).isResting(song))
        XCTAssertTrue(taste(seeds, signals: (0..<3).map { _ in skip(song, origin: .chosen) }).isResting(song),
                      "Three early skips in a list you chose reach the threshold")
        XCTAssertFalse(taste(seeds, signals: [skip(song), skip(song, seconds: 20)]).isResting(song),
                       "One early and one mild skip stay below the threshold")
        XCTAssertFalse(taste(seeds, signals: [skip(song, rapid: true), skip(song, rapid: true)]).isResting(song))
    }

    func testSkipWeightHalvesEveryFourteenDaysWithoutFutureInflation() {
        let song = Fixtures.track("song")
        XCTAssertEqual(Weights.skipWeight(skip(song, daysAgo: 14), now: now), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Weights.skipWeight(skip(song, daysAgo: 28), now: now), 0.25, accuracy: 1e-12)
        XCTAssertEqual(Weights.skipWeight(skip(song, seconds: 20, daysAgo: 14), now: now), 0.2, accuracy: 1e-12)
        XCTAssertEqual(Weights.skipWeight(skip(song, daysAgo: -3), now: now), 1, "Clock skew must not inflate a skip")
        let seeds = songs("seed", count: 4)
        let recent = taste(seeds, signals: rest(song, daysAgo: 1))
        XCTAssertEqual(recent.skipScores[song.id] ?? 0, 2 * pow(0.5, 1.0 / 14), accuracy: 1e-12)
        XCTAssertTrue(recent.isResting(song))
        let old = taste(seeds, signals: rest(song, daysAgo: 14))
        XCTAssertEqual(old.skipScores[song.id] ?? 0, 1, accuracy: 1e-12)
        XCTAssertFalse(old.isResting(song), "Two early skips two weeks ago no longer rest a song")
    }

    // MARK: Resting

    func testTwoEarlySkipsRestASongAndEveryUploadOfItInDiscoverWeeklyAndDailyMix() async throws {
        let seeds = songs("seed", count: 4)
        let rested = Fixtures.track("yt-rested", title: "Rested Song", artist: "Rested Artist")
        let reupload = Fixtures.track("saavn:rested", title: "Rested Song (From \"A Film\")", artist: "Rested Artist")
        let heardRested = Fixtures.track("heard-rested", title: "Heard Rested", artist: "Heard Artist")
        let fresh = songs("fresh", count: 15)
        let events = seeds.map { Fixtures.event($0, daysAgo: 0, seconds: 240) } + [Fixtures.event(heardRested, daysAgo: 0, seconds: 100)]
        func build(_ signals: [ListeningSignal]) -> TasteProfile {
            TasteProfile.build(events: events, favorites: [], playlists: [], recents: [], signals: signals, now: now)
        }
        let quiet = build([])
        let resting = build(rest(rested) + rest(heardRested, daysAgo: 1))
        XCTAssertEqual(resting.restingTrackIDs, [rested.id, heardRested.id])
        XCTAssertEqual(resting.restingSongKeys, Set([rested, heardRested].compactMap { SongIdentity.key($0) }))
        XCTAssertTrue(resting.isResting(reupload), "Another upload of the song shares its rest through the song key")
        XCTAssertEqual(resting.skipScore(for: reupload), 2, accuracy: 1e-12)
        XCTAssertGreaterThan(resting.trackAffinity[heardRested.id] ?? 0, 0, "The fixture must rely on the rest rule, not lost affinity")
        XCTAssertFalse(resting.isColdStart)

        let quietWeekly = try await weekly(await catalog(seeds: seeds, radio: [rested, reupload] + fresh), profile: quiet)
        let quietWeeklyIDs = Set(try XCTUnwrap(quietWeekly).tracks.map(\.id))
        XCTAssertEqual(quietWeeklyIDs.intersection([rested.id, reupload.id]).count, 1, "Without skips one upload of the song is new music")
        let restingCatalog = await catalog(seeds: seeds, radio: [rested, reupload] + fresh)
        let restingWeeklyResult = try await weekly(restingCatalog, profile: resting)
        let restingWeekly = try XCTUnwrap(restingWeeklyResult)
        XCTAssertEqual(Set(restingWeekly.tracks.map(\.id)), Set(fresh.map(\.id)))
        let weeklyCalls = await restingCatalog.callCount
        XCTAssertEqual(weeklyCalls, 4, "Resting songs cost no extra request")

        let quietDailyResult = try await daily(await catalog(seeds: seeds, radio: [rested, reupload] + fresh), profile: quiet)
        let quietDaily = try XCTUnwrap(quietDailyResult)
        XCTAssertTrue(Set([rested.id, reupload.id, heardRested.id]).isSubset(of: quietDaily.tracks.map(\.id)))
        XCTAssertEqual(quietDaily.tracks.count, 22)
        let dailyCatalog = await catalog(seeds: seeds, radio: [rested, reupload] + fresh)
        let restingDailyResult = try await daily(dailyCatalog, profile: resting)
        let restingDaily = try XCTUnwrap(restingDailyResult)
        XCTAssertEqual(Set(restingDaily.tracks.map(\.id)), Set((seeds + fresh).map(\.id)),
                       "Resting songs leave both the new pool and the familiar pool")
        let dailyCalls = await dailyCatalog.callCount
        XCTAssertEqual(dailyCalls, 4)

        let scope = MixScope(kind: .dailyMix)
        let scoped = try await engine(await catalog(seeds: seeds, radio: [rested, reupload] + fresh))
            .scopedMixes(profile: resting, scopes: [scope], periodKey: day)
        let scopedIDs = Set(try XCTUnwrap(scoped.first).tracks.map(\.id))
        XCTAssertTrue(scopedIDs.isDisjoint(with: [rested.id, reupload.id, heardRested.id]), "The clustered mix path applies the same rest")

        let composed = Engine.composeDailyMix(ranked: [rested, reupload, heardRested] + fresh, familiarWeights: resting.trackAffinity,
                                              profile: resting, languages: [], languageProfile: nil, familiarity: .familiar,
                                              periodKey: day)
        XCTAssertTrue(Set(composed.map(\.id)).isDisjoint(with: [rested.id, reupload.id, heardRested.id]))
    }

    func testOneMildSkipLowersRankWithoutRestingTheSong() async throws {
        let seeds = songs("seed", count: 4)
        let mild = Fixtures.track("mild", artist: "Mild Artist")
        let rival = Fixtures.track("rival", artist: "Rival Artist")
        let profile = taste(seeds, signals: [skip(mild, seconds: 20)])
        XCTAssertEqual(profile.skipScore(for: mild), Weights.mildSkip, accuracy: 1e-12)
        XCTAssertFalse(profile.isResting(mild))
        XCTAssertTrue(profile.restingTrackIDs.isEmpty && profile.restingSongKeys.isEmpty)
        XCTAssertEqual(Candidate(track: mild, score: 2, order: 0).weighted(bySkips: profile).score,
                       2 * (1 - Engine.skipRankDiscount * Weights.mildSkip), accuracy: 1e-12)
        XCTAssertEqual(Candidate(track: rival, score: 2, order: 1).weighted(bySkips: profile).score, 2,
                       "An unskipped candidate keeps its exact score")
        // Equal provider scores: a ten percent discount outweighs the 0.15 jitter band on every day.
        for period in [day, "2026-05-29", "2026-05-30", "2026-05-31"] {
            let ranked = Engine.rankedMixCandidates([Candidate(track: mild, score: 4, order: 0), Candidate(track: rival, score: 4, order: 1)],
                                                    profile: profile, languages: [], languageProfile: nil, genreProfile: nil,
                                                    periodKey: period)
            XCTAssertEqual(ranked.map(\.id), [rival.id, mild.id], period)
        }

        let candidates = [mild] + songs("fresh", count: 12)
        let weeklyResult = try await weekly(await catalog(seeds: seeds, radio: candidates), profile: profile)
        XCTAssertTrue(try XCTUnwrap(weeklyResult).tracks.contains { $0.id == mild.id }, "A mild skip only lowers rank")
        let dailyResult = try await daily(await catalog(seeds: seeds, radio: candidates), profile: profile)
        XCTAssertTrue(try XCTUnwrap(dailyResult).tracks.contains { $0.id == mild.id })
    }

    func testALikeOrSuperLikeKeepsASkippedSongOutOfRestWhileItsSkipsStillCostRank() {
        let seeds = songs("seed", count: 4)
        let liked = Fixtures.track("liked", title: "Liked Song", artist: "Liked Artist")
        let reupload = Fixtures.track("saavn:liked", title: "Liked Song (From \"A Film\")", artist: "Liked Artist")
        let superLiked = Fixtures.track("super", title: "Super Song", artist: "Super Artist", artistID: "UCsuper")
        let signals = rest(liked) + [skip(liked)] + rest(reupload) + rest(superLiked) + [skip(superLiked)]
        let unliked = taste(seeds, signals: signals)
        XCTAssertTrue(unliked.isResting(liked) && unliked.isResting(reupload) && unliked.isResting(superLiked))

        let profile = taste(seeds, favorites: [liked], superLiked: [superLiked], signals: signals)
        XCTAssertFalse(profile.isResting(liked), "Liking a song proves the opposite of a skip")
        XCTAssertFalse(profile.isResting(reupload), "The like clears every upload of the song")
        XCTAssertFalse(profile.isResting(superLiked))
        XCTAssertTrue(profile.restingTrackIDs.isEmpty && profile.restingSongKeys.isEmpty)
        XCTAssertEqual(profile.skipScore(for: liked), 5, accuracy: 1e-12, "Both uploads' skips share the song's score")
        XCTAssertEqual(Candidate(track: liked, score: 1, order: 0).weighted(bySkips: profile).score,
                       1 - Engine.maximumSkipRankDiscount, accuracy: 1e-12, "The rank discount stops at half")
        XCTAssertEqual(profile.trackAffinity[liked.id] ?? 0, TasteProfile.favoriteBoost - 3 * Weights.artistPenaltySeconds, accuracy: 1e-9)

        // A super like cannot rest, so its reserved seed never conflicts with the rest rule.
        XCTAssertEqual(Engine.eligibleSuperLikes(profile).map(\.id), [superLiked.id])
        for key in [day, week] {
            let seeded = Engine.Seeds(profile: profile, languageProfile: nil, periodKey: key)
            XCTAssertTrue(seeded.tracks.contains { $0.track.id == superLiked.id }, key)
        }
    }

    func testALaterFinishedPlayForgivesEarlierSkipsWhileNewSkipsCountAgain() {
        let seeds = songs("seed", count: 4)
        let song = Fixtures.track("song", title: "Second Chance", artist: "Chance Artist")
        let reupload = Fixtures.track("saavn:song", title: "Second Chance - Remastered", artist: "Chance Artist")
        let early = rest(song, daysAgo: 3)
        XCTAssertTrue(taste(seeds, signals: early).isResting(song))

        let finished = taste(seeds, signals: early + [finish(song, daysAgo: 2)])
        XCTAssertFalse(finished.isResting(song))
        XCTAssertEqual(finished.skipScore(for: song), 0)
        XCTAssertNil(finished.skipScores[song.id], "Forgiven skips leave no score, discount or penalty behind")
        XCTAssertFalse(taste(seeds, signals: early + [finish(reupload, daysAgo: 2)]).isResting(song),
                       "Finishing another upload of the song clears it too")
        XCTAssertTrue(taste(seeds, signals: [finish(song, daysAgo: 4)] + early).isResting(song),
                      "Only a finish after the skips forgives them")

        let oneMore = taste(seeds, signals: early + [finish(song, daysAgo: 2), skip(song, daysAgo: 1)])
        XCTAssertFalse(oneMore.isResting(song))
        XCTAssertEqual(oneMore.skipScore(for: song), pow(0.5, 1.0 / 14), accuracy: 1e-12)
        XCTAssertTrue(taste(seeds, signals: early + [finish(song, daysAgo: 2)] + rest(song, daysAgo: 1)).isResting(song))
    }

    // MARK: Affinity

    func testSkipsLowerTheSongAndEveryCreditedArtistDownToZero() {
        let seeds = songs("seed", count: 4)
        let skipped = Fixtures.track("skipped", artist: "Penalized Artist")
        let sibling = Fixtures.track("sibling", artist: "Penalized Artist")
        var duet = Fixtures.track("duet", artist: "Lead Singer")
        duet.artists.append("Guest Singer")
        let events = seeds.map { Fixtures.event($0, daysAgo: 0, seconds: 240) }
            + [skipped, sibling, duet].map { Fixtures.event($0, daysAgo: 0, seconds: 100) }
        func build(_ signals: [ListeningSignal]) -> TasteProfile {
            TasteProfile.build(events: events, favorites: [], playlists: [], recents: [], signals: signals, now: now)
        }
        let quiet = build([])
        XCTAssertEqual(quiet.artistAffinity["penalized artist"] ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(quiet.skipPenalizedArtistCount, 0)

        let once = build([skip(skipped)])
        XCTAssertEqual(once.artistAffinity["penalized artist"] ?? 0, 200 - Weights.artistPenaltySeconds, accuracy: 1e-9)
        XCTAssertEqual(once.trackAffinity[skipped.id] ?? 0, 100 - Weights.artistPenaltySeconds, accuracy: 1e-9)
        XCTAssertEqual(once.trackAffinity[sibling.id] ?? 0, 100, accuracy: 1e-9, "Another song by the artist keeps its own affinity")
        XCTAssertEqual(once.skipPenalizedArtistCount, 1)
        XCTAssertFalse(once.isResting(skipped))

        let chosenMild = build([skip(skipped, seconds: 20, origin: .chosen)])
        XCTAssertEqual(chosenMild.artistAffinity["penalized artist"] ?? 0, 200 - Weights.artistPenaltySeconds * 0.2, accuracy: 1e-9)

        let duetSkip = build([skip(duet)])
        XCTAssertEqual(duetSkip.artistAffinity["lead singer"] ?? 0, 100 - Weights.artistPenaltySeconds, accuracy: 1e-9)
        XCTAssertEqual(duetSkip.artistAffinity["guest singer"] ?? 0, 100 - Weights.artistPenaltySeconds, accuracy: 1e-9)
        XCTAssertEqual(duetSkip.skipPenalizedArtistCount, 2)

        let many = build((0..<5).map { _ in skip(skipped) })
        XCTAssertEqual(many.trackAffinity[skipped.id] ?? -1, 0, "Affinity floors at zero")
        XCTAssertEqual(many.artistAffinity["penalized artist"] ?? -1, 0)
        XCTAssertEqual(many.artistAffinity[TasteProfile.normalizedArtistName(seeds[0].artistName)] ?? 0,
                       quiet.artistAffinity[TasteProfile.normalizedArtistName(seeds[0].artistName)] ?? -1, accuracy: 1e-9)
    }

    func testFinishedPlaysEarnAQuarterMoreAndShortSongsFinishTenSecondsEarly() {
        let long = Fixtures.track("long", artist: "Long Artist", duration: 240)
        let short = Fixtures.track("short", artist: "Short Artist", duration: 60)
        let unknown = Fixtures.track("unknown", artist: "Unknown Artist", duration: nil)
        func affinity(_ track: Track, seconds: Double, daysAgo: Double = 0) -> Double {
            TasteProfile.build(events: [Fixtures.event(track, daysAgo: daysAgo, seconds: seconds)], favorites: [], playlists: [],
                               recents: [], now: now).trackAffinity[track.id] ?? 0
        }
        let bonus = 1 + TasteProfile.completionBonus
        XCTAssertEqual(affinity(long, seconds: 216), 216 * bonus, accuracy: 1e-9, "Ninety percent of a song is finished")
        XCTAssertEqual(affinity(long, seconds: 215.9), 215.9, accuracy: 1e-9)
        XCTAssertEqual(affinity(long, seconds: 240), 300, accuracy: 1e-9)
        XCTAssertEqual(affinity(long, seconds: 240, daysAgo: 21), 150, accuracy: 1e-9, "The bonus is a share of the decayed weight")
        XCTAssertEqual(affinity(short, seconds: 50), 50 * bonus, accuracy: 1e-9, "Ten seconds from the end of a short song is finished")
        XCTAssertEqual(affinity(short, seconds: 49.9), 49.9, accuracy: 1e-9)
        XCTAssertEqual(affinity(unknown, seconds: 300), 300, accuracy: 1e-9, "Without a length nothing proves a finish")
        let profile = TasteProfile.build(events: [Fixtures.event(long, daysAgo: 0, seconds: 240)], favorites: [], playlists: [],
                                         recents: [], now: now)
        XCTAssertEqual(profile.artistAffinity["long artist"] ?? 0, 300, accuracy: 1e-9, "Artists share the bonus")
    }

    func testWeeklyReplaysAddDiminishingBonusesToTheSongAndItsArtists() {
        let song = Fixtures.track("replayed", artist: "Replay Artist")
        func profile(plays: Int, daysAgo: Double = 0) -> TasteProfile {
            TasteProfile.build(events: (0..<plays).map { _ in Fixtures.event(song, daysAgo: daysAgo, seconds: 100) },
                               favorites: [], playlists: [], recents: [], now: now)
        }
        XCTAssertEqual(TasteProfile.replayBonus(plays: 0), 0)
        XCTAssertEqual(TasteProfile.replayBonus(plays: 1), 0)
        XCTAssertEqual(TasteProfile.replayBonus(plays: 2), 60, accuracy: 1e-12)
        XCTAssertEqual(TasteProfile.replayBonus(plays: 4), 120, accuracy: 1e-12)
        XCTAssertEqual(TasteProfile.replayBonus(plays: 8), 180, accuracy: 1e-12)
        var bonuses: [Int: Double] = [:]
        for plays in [1, 2, 4, 8] {
            let replayed = profile(plays: plays)
            let affinity = replayed.trackAffinity[song.id] ?? 0
            bonuses[plays] = affinity - 100 * Double(plays)
            XCTAssertEqual(bonuses[plays] ?? -1, TasteProfile.replayBonus(plays: plays), accuracy: 1e-9, "\(plays) plays")
            XCTAssertEqual(replayed.artistAffinity["replay artist"] ?? 0, affinity, accuracy: 1e-9, "The artist earns the same bonus")
        }
        let pairs: [(low: Int, high: Int)] = [(1, 2), (2, 4), (4, 8)]
        var perExtraPlay: [Double] = []
        for pair in pairs {
            let gained: Double = (bonuses[pair.high] ?? 0) - (bonuses[pair.low] ?? 0)
            perExtraPlay.append(gained / Double(pair.high - pair.low))
        }
        XCTAssertEqual(perExtraPlay[0], 60, accuracy: 1e-9)
        XCTAssertLessThan(perExtraPlay[1], perExtraPlay[0], "Each extra play is worth less, so one obsession cannot take over")
        XCTAssertLessThan(perExtraPlay[2], perExtraPlay[1])

        let decay = pow(0.5, 1.0 / TasteProfile.halfLifeDays)
        XCTAssertEqual(profile(plays: 2, daysAgo: 1).trackAffinity[song.id] ?? 0, (200 + 60) * decay, accuracy: 1e-9,
                       "The bonus decays from the latest play")
        let spread = TasteProfile.build(events: [Fixtures.event(song, daysAgo: 1, seconds: 100), Fixtures.event(song, daysAgo: 8, seconds: 100)],
                                        favorites: [], playlists: [], recents: [], now: now)
        XCTAssertEqual(spread.trackAffinity[song.id] ?? 0, 100 * decay + 100 * pow(0.5, 8 / TasteProfile.halfLifeDays), accuracy: 1e-9,
                       "A play older than a week is not a replay")
        let taps = TasteProfile.build(events: [Fixtures.event(song, daysAgo: 0, seconds: 100), Fixtures.event(song, daysAgo: 0, seconds: 5),
                                               Fixtures.event(song, daysAgo: 0, seconds: 5)],
                                      favorites: [], playlists: [], recents: [], now: now)
        XCTAssertEqual(taps.trackAffinity[song.id] ?? 0, 100, accuracy: 1e-9, "Taps below the play threshold are not replays")
    }

    // MARK: Seeds and clusters

    func testRestingSongsNeverSeedMixesWhileTheirArtistsStillCan() {
        let favorite = Fixtures.track("favorite", title: "Old Favorite", artist: "Favorite Artist", artistID: "UCfavorite")
        let others = (0..<5).map { Fixtures.track("other-\($0)", artist: "Other \($0)", artistID: "UCother\($0)") }
        let events = (0..<6).map { _ in Fixtures.event(favorite, daysAgo: 0, seconds: 240) }
            + others.map { Fixtures.event($0, daysAgo: 0, seconds: 240) }
        let quiet = TasteProfile.build(events: events, favorites: [], playlists: [], recents: [], now: now)
        let resting = TasteProfile.build(events: events, favorites: [], playlists: [], recents: [], signals: rest(favorite), now: now)
        XCTAssertTrue(resting.isResting(favorite))
        XCTAssertEqual(resting.topTracks(limit: 1).first?.id, favorite.id, "The fixture must rely on the rest rule, not a lower affinity")
        let languageProfiles: [ListeningLanguageProfile?] = [nil, ListeningLanguageProfile()]
        for languageProfile in languageProfiles {
            for key in [day, week] {
                let natural = Engine.Seeds(profile: quiet, languageProfile: languageProfile, periodKey: key)
                XCTAssertTrue(natural.tracks.contains { $0.track.id == favorite.id })
                let seeds = Engine.Seeds(profile: resting, languageProfile: languageProfile, periodKey: key)
                XCTAssertEqual(seeds.tracks.count, Engine.seedTrackCount)
                XCTAssertFalse(seeds.tracks.contains { $0.track.id == favorite.id })
                XCTAssertTrue(seeds.artists.contains { $0.id == "UCfavorite" }, "An artist is not the song that rests")
            }
        }
        let scope = MixScope(kind: .dailyMix)
        let scoped = Engine.scopedSeeds(profile: resting, scopes: [scope], ownership: .init(scopes: [scope]), languageProfile: nil,
                                        periodKey: day)
        XCTAssertEqual(scoped.tracks.count, Engine.seedTrackCount)
        XCTAssertFalse(scoped.tracks.contains { $0.track.id == favorite.id })
    }

    func testRestingSongsDoNotShapeTasteClusters() {
        let owned = (0..<5).map { Fixtures.track("cluster-\($0)", artist: "Cluster Artist") }
        let events = owned.map { Fixtures.event($0, daysAgo: 0, seconds: 240) }
        let quiet = TasteProfile.build(events: events, favorites: [], playlists: [], recents: [], now: now)
        let resting = TasteProfile.build(events: events, favorites: [], playlists: [], recents: [], signals: rest(owned[0]), now: now)
        let quietClusters = TasteClustering.clusters(.init(profile: quiet, languageProfile: nil, genreProfile: nil))
        let restingClusters = TasteClustering.clusters(.init(profile: resting, languageProfile: nil, genreProfile: nil))
        XCTAssertEqual(quietClusters.first?.trackIDs.count, 5)
        XCTAssertEqual(Set(restingClusters.flatMap(\.trackIDs)), Set(owned.dropFirst().map(\.id)))
    }

    // MARK: Radio, Home and autoplay

    func testSeedRadioLeavesRestingSongsOutOfAdditionsAndArtistAnchorsWithoutExtraRequests() async throws {
        let anchor = Fixtures.arijit1
        let rested = Fixtures.track("rested", title: "Rested Song", artist: "Rested Artist")
        let reupload = Fixtures.track("saavn:rested", title: "Rested Song (Live)", artist: "Rested Artist")
        let next = Fixtures.track("next", artist: "Next Artist")
        let resting = taste(songs("seed", count: 4), signals: rest(rested)).restingSongs
        let control = SeedRadioEngine.select([rested, reupload, next], excluding: [], disliked: [], tuning: RadioTuning(),
                                             heardTrackIDs: [], languageProfile: .init())
        XCTAssertTrue(control.contains { $0.id == rested.id })
        XCTAssertEqual(SeedRadioEngine.select([rested, reupload, next], excluding: [], disliked: [], tuning: RadioTuning(),
                                              heardTrackIDs: [], languageProfile: .init(), resting: resting).map(\.id), [next.id])

        let catalog = RecommendationCatalogMock()
        await catalog.setRadio([rested, reupload, next], for: anchor.id)
        let radio = SeedRadioEngine(catalog: catalog)
        let refill = try await radio.refill(anchors: [anchor], round: 0, excluding: [], disliked: [], tuning: RadioTuning(),
                                            heardTrackIDs: [], languageProfile: .init(), resting: resting)
        XCTAssertEqual(refill.map(\.id), [next.id])
        let calls = await catalog.callCount
        XCTAssertEqual(calls, 1, "Resting songs never cost another request")

        let starved = RecommendationCatalogMock()
        await starved.setRadio([rested, reupload], for: anchor.id)
        do {
            _ = try await SeedRadioEngine(catalog: starved).refill(anchors: [anchor], round: 0, excluding: [], disliked: [],
                                                                  tuning: RadioTuning(), heardTrackIDs: [], languageProfile: .init(),
                                                                  resting: resting)
            XCTFail("Only resting songs left means the radio is exhausted")
        } catch {
            guard case SeedRadioError.exhausted(language: nil) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let starvedCalls = await starved.callCount
        XCTAssertEqual(starvedCalls, 2, "The usual single fresh retry, as for any fully filtered answer")

        let top = (0..<4).map { Fixtures.track("alex-\($0)", title: "Alex Song \($0)", artist: "Alex", artistID: "UCalex") }
        let pages = RecommendationCatalogMock()
        await pages.setArtist(Fixtures.page("UCalex", name: "Alex", topSongs: top))
        let artistRadio = SeedRadioEngine(catalog: pages)
        let seed = RadioSeed.artist(.init(name: "Alex", id: "UCalex"))
        let topResting = taste(songs("seed", count: 4), signals: rest(top[0])).restingSongs
        let quietAnchors = try await artistRadio.anchors(for: seed, disliked: [])
        XCTAssertEqual(quietAnchors.map(\.id), top.prefix(3).map(\.id))
        let anchors = try await artistRadio.anchors(for: seed, disliked: [], resting: topResting)
        XCTAssertEqual(anchors.map(\.id), top.dropFirst().map(\.id), "A resting popular song never anchors artist radio")
        let allResting = taste(songs("seed", count: 4), signals: top.flatMap { rest($0) }).restingSongs
        let fallback = try await artistRadio.anchors(for: seed, disliked: [], resting: allResting)
        XCTAssertEqual(fallback.map(\.id), top.prefix(3).map(\.id), "Asking for the artist still starts radio when every popular song rests")
        let chosen = try await artistRadio.anchors(for: .song(top[0]), disliked: [], resting: topResting)
        XCTAssertEqual(chosen, [top[0]], "A song the listener picks starts radio whatever its skips")
        let pageCalls = await pages.callCount
        XCTAssertEqual(pageCalls, 3, "One artist page per artist lookup, none for the song seed")
    }

    func testHomeShelvesLeaveRestingSongsAndSeedsOutWithinTheirBudgets() async throws {
        let seedArtist = Fixtures.track("shelf-seed", artist: "Seed artist", artistID: "UCshelf", language: .hindi)
        // Distinct artists keep the language shelf's three-per-artist cap out of the comparison.
        let rested = Fixtures.track("shelf-rested", title: "Rested Shelf Song", artist: "Rested artist", language: .hindi)
        let fresh = (0..<6).map { Fixtures.track("shelf-fresh-\($0)", artist: "Fresh artist \($0)", language: .hindi) }
        let shelfCandidates = [rested] + fresh
        func shelfCatalog() -> ExperienceRadioCatalogFixture {
            ExperienceRadioCatalogFixture(searches: ["Hindi songs": .success(shelfCandidates)],
                                          artists: ["UCshelf": .success(Fixtures.page("UCshelf", name: "Seed artist", topSongs: shelfCandidates))])
        }
        let languages = ListeningLanguageProfile(fallback: [.hindi])
        let quiet = TasteProfile.build(events: [], favorites: [seedArtist], playlists: [], recents: [], now: now)
        let profile = TasteProfile.build(events: [], favorites: [seedArtist], playlists: [], recents: [], signals: rest(rested), now: now)
        XCTAssertTrue(profile.isResting(rested))

        let quietBecause = try await engine(shelfCatalog()).becauseYouListen(profile: quiet, languages: [], limit: 1, languageProfile: languages)
        XCTAssertEqual(quietBecause.first?.tracks.map(\.id), shelfCandidates.map(\.id))
        let becauseCatalog = shelfCatalog()
        let because = try await engine(becauseCatalog).becauseYouListen(profile: profile, languages: [], limit: 1, languageProfile: languages)
        XCTAssertEqual(because.first?.tracks.map(\.id), fresh.map(\.id))
        let artistCalls = await becauseCatalog.artistRequests
        XCTAssertEqual(artistCalls, ["UCshelf"])

        let quietLanguage = try await engine(shelfCatalog()).languageDiscovery(profile: quiet, languageProfile: languages, limit: 1)
        XCTAssertEqual(quietLanguage.first?.tracks.map(\.id), shelfCandidates.map(\.id))
        let languageCatalog = shelfCatalog()
        let language = try await engine(languageCatalog).languageDiscovery(profile: profile, languageProfile: languages, limit: 1)
        XCTAssertEqual(language.first?.tracks.map(\.id), fresh.map(\.id))
        let searches = await languageCatalog.searchRequests
        XCTAssertEqual(searches.count, 1)

        // A learned language seeds its shelf from the strongest song in it that does not rest.
        let top = Fixtures.track("hindi-top", artist: "Top Singer", language: .hindi)
        let second = Fixtures.track("hindi-second", artist: "Second Singer", language: .hindi)
        let learned = ListeningLanguageProfile(summary: ListeningLanguageSummary(
            rows: [LanguageListeningStat(language: .hindi, plays: 4, songs: 2, share: 1)], totalPlays: 4, totalSongs: 2))
        let played = (0..<3).map { _ in Fixtures.event(top, daysAgo: 0, seconds: 240) } + [Fixtures.event(second, daysAgo: 0, seconds: 240)]
        let seededProfile = TasteProfile.build(events: played, favorites: [], playlists: [], recents: [], signals: rest(top), now: now)
        XCTAssertEqual(seededProfile.topTracks(limit: 1).first?.id, top.id)
        let seededCatalog = ExperienceRadioCatalogFixture(searches: ["Hindi songs": .success(fresh)], radios: [second.id: .success(fresh)])
        let seeded = try await engine(seededCatalog).languageDiscovery(profile: seededProfile, languageProfile: learned, limit: 1)
        XCTAssertEqual(seeded.first?.tracks.map(\.id), fresh.map(\.id))
        let radios = await seededCatalog.radioRequests
        XCTAssertEqual(radios.map(\.id), [second.id], "The resting top song never seeds the shelf")
    }

    func testAutoplayHelpersDropRestingSongsFromContinuationsAndFallbackSeeds() {
        let rested = Fixtures.track("rested", title: "Rested Song", artist: "Rested Artist")
        let reupload = Fixtures.track("saavn:rested", title: "Rested Song (Remix)", artist: "Rested Artist")
        let kept = Fixtures.track("kept", artist: "Kept Artist")
        let resting = taste(songs("seed", count: 4), signals: rest(rested)).restingSongs
        XCTAssertEqual(resting.excluding([rested, kept, reupload]).map(\.id), [kept.id])
        XCTAssertEqual(RestingSongs().excluding([rested, kept]).map(\.id), [rested.id, kept.id], "No evidence changes nothing")

        let earlier = Fixtures.track("earlier", artist: "Earlier Artist")
        let last = Fixtures.track("last", artist: "Last Artist")
        let queue = [earlier, rested, last]
        XCTAssertEqual(AutoplayContinuation.fallbackSeed(queue: queue, after: last, recentIDs: [rested.id], autoplayIDs: [],
                                                         disliked: [])?.id, rested.id)
        XCTAssertEqual(AutoplayContinuation.fallbackSeed(queue: queue, after: last, recentIDs: [rested.id], autoplayIDs: [],
                                                         disliked: [], resting: resting)?.id, earlier.id,
                       "A resting queue song never seeds autoplay")
        XCTAssertNil(AutoplayContinuation.fallbackSeed(queue: [rested, last], after: last, recentIDs: [], autoplayIDs: [],
                                                       disliked: [], resting: resting))
    }

    // MARK: Budgets, stability and metrics

    func testSkipSignalsKeepTheTenCallBudgetAndAStableOrderWithinAPeriod() async throws {
        let rested = Fixtures.track("a1-1", artist: "New A1", language: .hindi)
        let mild = Fixtures.track("b1-1", artist: "New B1", language: .hindi)
        let profile = TasteProfile.build(events: Fixtures.events(), favorites: [], playlists: [], recents: [],
                                         signals: rest(rested) + [skip(mild, seconds: 20)], now: now)
        XCTAssertTrue(profile.isResting(rested))
        for kind in [GeneratedPlaylistKind.discoverWeekly, .dailyMix] {
            let catalog = await Fixtures.catalog()
            let result = try await mix(kind, catalog: catalog, profile: profile)
            let first = try XCTUnwrap(result)
            XCTAssertEqual(first.tracks.count, kind == .discoverWeekly ? 30 : 25)
            XCTAssertFalse(first.tracks.contains { $0.id == rested.id })
            let calls = await catalog.callCount
            XCTAssertEqual(calls, 10, "\(kind) keeps its ten-call budget")
            let again = try await mix(kind, catalog: await Fixtures.catalog(), profile: profile)
            XCTAssertEqual(first.tracks, again?.tracks, "\(kind) is stable within its period")
        }
    }

    func testSkipMetricsCountEachRestingOrDiscountedRecordingOnce() {
        let seeds = songs("seed", count: 4)
        let heardRested = Fixtures.track("heard-rested", artist: "Heard Artist")
        let rested = Fixtures.track("rested", title: "Rested Song", artist: "Rested Artist")
        let reupload = Fixtures.track("saavn:rested", title: "Rested Song (Live)", artist: "Rested Artist")
        let mild = Fixtures.track("mild", artist: "Mild Artist")
        let events = seeds.map { Fixtures.event($0, daysAgo: 0, seconds: 240) } + [Fixtures.event(heardRested, daysAgo: 0, seconds: 100)]
        let profile = TasteProfile.build(events: events, favorites: [], playlists: [], recents: [],
                                         signals: rest(rested) + rest(heardRested) + [skip(mild, seconds: 20)], now: now)
        let tracks = [rested, reupload, mild, rested] + songs("fresh", count: 3)
        let candidates = tracks.enumerated().map { Candidate(track: $0.element, score: 1, order: $0.offset) }
        let metrics = SkipSignalMetrics.mix(candidates: candidates, profile: profile, languages: [])
        XCTAssertEqual(metrics.restingExcluded, 3, "Two uploads of the rested song and the heard rested recording")
        XCTAssertEqual(metrics.downweighted, 1)
        XCTAssertEqual(metrics.artistsPenalized, 1, "Only an artist with affinity can lose some")
        let quiet = SkipSignalMetrics.mix(candidates: candidates, profile: taste(seeds), languages: [])
        XCTAssertEqual([quiet.restingExcluded, quiet.downweighted, quiet.artistsPenalized], [0, 0, 0])
    }

    // MARK: Helpers

    private func skip(_ track: Track, seconds: Double = 5, daysAgo: Double = 0, origin: ListeningSignal.Origin = .generated,
                      rapid: Bool = false) -> ListeningSignal {
        ListeningSignal(trackID: track.id, title: track.title, artists: track.artists,
                        endedAt: now.addingTimeInterval(-daysAgo * 86_400), listenedSeconds: seconds, duration: track.duration,
                        ending: .skipped, origin: origin, rapid: rapid)
    }

    private func finish(_ track: Track, daysAgo: Double = 0) -> ListeningSignal {
        ListeningSignal(trackID: track.id, title: track.title, artists: track.artists,
                        endedAt: now.addingTimeInterval(-daysAgo * 86_400), listenedSeconds: track.duration ?? 240,
                        duration: track.duration, ending: .completed, origin: .generated, rapid: false)
    }

    /// Two early skips of a song the app chose: the least evidence that rests it.
    private func rest(_ track: Track, daysAgo: Double = 0) -> [ListeningSignal] {
        [skip(track, daysAgo: daysAgo), skip(track, daysAgo: daysAgo)]
    }

    private func songs(_ prefix: String, count: Int) -> [Track] {
        (0..<count).map { Fixtures.track("\(prefix)-\($0)", artist: "Artist \(prefix)-\($0)") }
    }

    private func taste(_ played: [Track], favorites: [Track] = [], superLiked: [Track] = [],
                       signals: [ListeningSignal] = []) -> TasteProfile {
        TasteProfile.build(events: played.map { Fixtures.event($0, daysAgo: 0, seconds: 240) }, favorites: favorites + superLiked,
                           playlists: [], recents: [], superLikedIDs: Set(superLiked.map(\.id)), signals: signals, now: now)
    }

    private func catalog(seeds: [Track], radio: [Track]) async -> RecommendationCatalogMock {
        let catalog = RecommendationCatalogMock()
        for seed in seeds { await catalog.setRadio(radio, for: seed.id) }
        return catalog
    }

    private func engine(_ catalog: any MusicCatalogProviding) -> RecommendationEngine {
        RecommendationEngine(catalog: catalog, now: { RecommendationFixtures.now })
    }

    private func weekly(_ catalog: any MusicCatalogProviding, profile: TasteProfile) async throws -> GeneratedPlaylist? {
        try await engine(catalog).discoverWeekly(profile: profile, languages: [], periodKey: week, languageProfile: ListeningLanguageProfile())
    }

    private func daily(_ catalog: any MusicCatalogProviding, profile: TasteProfile) async throws -> GeneratedPlaylist? {
        try await engine(catalog).dailyMix(profile: profile, languages: [], periodKey: day, languageProfile: ListeningLanguageProfile())
    }

    private func mix(_ kind: GeneratedPlaylistKind, catalog: any MusicCatalogProviding,
                     profile: TasteProfile) async throws -> GeneratedPlaylist? {
        if kind == .discoverWeekly { return try await weekly(catalog, profile: profile) }
        return try await daily(catalog, profile: profile)
    }
}
