import XCTest
@testable import GanaBajana

final class RecommendationEngineTests: XCTestCase {
    private let profile = RecommendationFixtures.profile()
    private let languages: Set<MusicLanguage> = [.hindi, .english]

    private func engine(_ catalog: RecommendationCatalogMock) -> RecommendationEngine {
        RecommendationEngine(catalog: catalog, now: { RecommendationFixtures.now })
    }

    private func weekly(_ catalog: RecommendationCatalogMock, profile: TasteProfile? = nil, languages: Set<MusicLanguage>? = nil,
                        periodKey: String = "2026-W22") async throws -> GeneratedPlaylist {
        let playlist = try await engine(catalog).discoverWeekly(profile: profile ?? self.profile, languages: languages ?? self.languages,
                                                                periodKey: periodKey)
        return try XCTUnwrap(playlist, "Expected a Discover Weekly playlist")
    }

    private func daily(_ catalog: RecommendationCatalogMock, periodKey: String = "2026-05-28") async throws -> GeneratedPlaylist {
        let playlist = try await engine(catalog).dailyMix(profile: profile, languages: languages, periodKey: periodKey)
        return try XCTUnwrap(playlist, "Expected a Daily Mix playlist")
    }

    private func artistCounts(_ tracks: [Track]) -> [String: Int] {
        tracks.reduce(into: [:]) { $0[RecommendationEngine.primaryArtistKey($1), default: 0] += 1 }
    }

    // MARK: Discover Weekly

    func testDiscoverWeeklyFillsThirtyUnheardSongsWithinTheProviderBudget() async throws {
        let catalog = await RecommendationFixtures.catalog()
        let playlist = try await weekly(catalog)

        XCTAssertEqual(playlist.kind, .discoverWeekly)
        XCTAssertEqual(playlist.periodKey, "2026-W22")
        XCTAssertEqual(playlist.generatedAt, RecommendationFixtures.now)
        XCTAssertEqual(playlist.tracks.count, 30)
        XCTAssertEqual(Set(playlist.tracks.map(\.id)).count, 30, "No duplicate songs")
        XCTAssertTrue(playlist.tracks.allSatisfy { !profile.heardTrackIDs.contains($0.id) }, "Heard songs never resurface")
        XCTAssertFalse(playlist.tracks.contains { $0.id == "tap-1" }, "A half-second tap still counts as heard")
        XCTAssertTrue(artistCounts(playlist.tracks).values.allSatisfy { $0 <= 2 }, "At most two songs per artist")
        XCTAssertEqual(artistCounts(playlist.tracks)["bulk artist"], 2)
        XCTAssertEqual(playlist.seedArtists, ["Arijit Singh", "The Weeknd", "Pritam"])

        let callCount = await catalog.callCount
        let radioRequests = await catalog.radioRequests
        let artistRequests = await catalog.artistRequests
        XCTAssertLessThanOrEqual(callCount, RecommendationEngine.providerCallBudget)
        XCTAssertEqual(callCount, 10)
        let radioLanguages = Dictionary(radioRequests.map { ($0.seed.id, $0.language) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(radioLanguages, ["arijit-1": .hindi, "arijit-2": .hindi, "weeknd-1": .english, "weeknd-2": .english])
        XCTAssertEqual(Set(artistRequests).count, artistRequests.count, "Each artist page is fetched once")
        XCTAssertEqual(Set(artistRequests.prefix(3)), ["UCarijit", "UCweeknd", "UCpritam"])
        XCTAssertEqual(Set(artistRequests.dropFirst(3)), ["UCshreya", "UCdrake", "UCatif"], "Related artists round-robin across seeds")
    }

    func testDiscoverWeeklyDropsUnplayableVariantsAndForeignLanguages() async throws {
        let catalog = await RecommendationFixtures.catalog()
        await catalog.setRadio([RecommendationFixtures.track("tamil", title: "Some Song", artist: "New T", language: .english)], for: "weeknd-2")
        let playlist = try await weekly(catalog, languages: [.hindi])
        let ids = Set(playlist.tracks.map(\.id))
        for excluded in ["a-karaoke", "a-slowed", "a-video", "a-long", "a-short", "tamil", "c1-1", "weeknd-3", "UCdrake-1"] {
            XCTAssertFalse(ids.contains(excluded), "\(excluded) must not be recommended")
        }
        XCTAssertTrue(playlist.tracks.allSatisfy { $0.language != .english })
    }

    func testDiscoverWeeklyIsStableWithinAWeekAndChangesAcrossWeeks() async throws {
        let first = try await weekly(await RecommendationFixtures.catalog(), periodKey: "2026-W22")
        let repeated = try await weekly(await RecommendationFixtures.catalog(), periodKey: "2026-W22")
        let nextWeek = try await weekly(await RecommendationFixtures.catalog(), periodKey: "2026-W23")
        XCTAssertEqual(first.tracks.map(\.id), repeated.tracks.map(\.id))
        XCTAssertNotEqual(first.tracks.map(\.id), nextWeek.tracks.map(\.id))
    }

    func testDiscoverWeeklyRanksNewArtistsAboveAlreadyLovedOnes() async throws {
        let a = RecommendationFixtures.track("a", artist: "Arijit Singh", artistID: "UCarijit")
        let b = RecommendationFixtures.track("b", artist: "The Weeknd", artistID: "UCweeknd")
        let profile = TasteProfile.build(events: [
            RecommendationFixtures.event(a, daysAgo: 0, seconds: 200),
            RecommendationFixtures.event(a, daysAgo: 1, seconds: 200),
            RecommendationFixtures.event(b, daysAgo: 1, seconds: 100),
        ], favorites: [], playlists: [], recents: [], now: RecommendationFixtures.now)
        let catalog = RecommendationCatalogMock()
        var radio = (1...8).map { RecommendationFixtures.track("n-\($0)", artist: "Newcomer \($0)") }
        radio.insert(RecommendationFixtures.track("arijit-unheard", artist: "Arijit Singh", artistID: "UCarijit"), at: 0)
        var duet = RecommendationFixtures.track("duet", title: "Duet", artist: "Fresh Face")
        duet.artists.append("The Weeknd")
        radio.insert(duet, at: 4)
        await catalog.setRadio(radio, for: "a")
        await catalog.setArtist(RecommendationFixtures.page("UCarijit", name: "Arijit Singh"))
        await catalog.setArtist(RecommendationFixtures.page("UCweeknd", name: "The Weeknd"))

        let playlist = try await weekly(catalog, profile: profile)
        XCTAssertEqual(playlist.tracks.count, 10)
        XCTAssertEqual(Set(playlist.tracks.suffix(2).map(\.id)), ["arijit-unheard", "duet"], "Songs by or featuring loved artists sink below newcomers")
        XCTAssertEqual(playlist.seedArtists, ["Arijit Singh", "The Weeknd"])
    }

    func testDiscoverWeeklyReturnsNilOnColdStartWithoutTouchingTheProvider() async throws {
        let a = RecommendationFixtures.track("a", artist: "Arijit Singh", artistID: "UCarijit")
        let cold = TasteProfile.build(events: [
            RecommendationFixtures.event(a, daysAgo: 0, seconds: 200),
            RecommendationFixtures.event(a, daysAgo: 1, seconds: 200),
        ], favorites: [], playlists: [], recents: [], now: RecommendationFixtures.now)
        let catalog = await RecommendationFixtures.catalog()
        let engine = engine(catalog)
        let weekly = try await engine.discoverWeekly(profile: cold, languages: languages, periodKey: "2026-W22")
        let daily = try await engine.dailyMix(profile: cold, languages: languages, periodKey: "2026-05-28")
        XCTAssertNil(weekly)
        XCTAssertNil(daily)
        let callCount = await catalog.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testDiscoverWeeklyReturnsNilWhenTooFewSongsSurvive() async throws {
        let catalog = RecommendationCatalogMock()
        await catalog.setRadio(RecommendationFixtures.tracks("few", count: 7, artist: "Only Artist"), for: "arijit-1")
        for id in ["UCarijit", "UCweeknd", "UCpritam"] { await catalog.setArtist(RecommendationFixtures.page(id, name: id)) }
        let playlist = try await engine(catalog).discoverWeekly(profile: profile, languages: languages, periodKey: "2026-W22")
        XCTAssertNil(playlist)
    }

    func testDiscoverWeeklyToleratesFailingSeedsAndThrowsOnlyWhenEverythingFails() async throws {
        let catalog = await RecommendationFixtures.catalog()
        await catalog.failRadio(for: "arijit-1")
        await catalog.failArtist("UCweeknd")
        await catalog.failArtist("UCshreya")
        let playlist = try await weekly(catalog)
        XCTAssertGreaterThanOrEqual(playlist.tracks.count, RecommendationEngine.minimumPlaylistSize)
        XCTAssertFalse(playlist.tracks.contains { $0.id.hasPrefix("a1-") }, "The failed radio contributed nothing")
        XCTAssertEqual(playlist.seedArtists, ["Arijit Singh", "The Weeknd", "Pritam"], "Seeds still used through other sources stay credited")

        let broken = RecommendationCatalogMock()
        for id in ["arijit-1", "arijit-2", "weeknd-1", "weeknd-2"] { await broken.failRadio(for: id) }
        for id in ["UCarijit", "UCweeknd", "UCpritam"] { await broken.failArtist(id) }
        do {
            _ = try await engine(broken).discoverWeekly(profile: profile, languages: languages, periodKey: "2026-W22")
            XCTFail("Expected the last provider error")
        } catch let error as RecommendationTestFailure {
            guard case .provider = error else { return XCTFail("Unexpected error \(error)") }
        }
        let brokenCalls = await broken.callCount
        XCTAssertEqual(brokenCalls, 7, "No related-artist fetches are attempted once every seed fails")
    }

    func testDiscoverWeeklyUsesThePreferredLanguageForSeedsWithoutOne() async throws {
        let a = RecommendationFixtures.track("a", artist: "Arijit Singh", duration: 240, language: nil)
        let b = RecommendationFixtures.track("b", artist: "The Weeknd", duration: 240, language: .english)
        let profile = TasteProfile.build(events: [
            RecommendationFixtures.event(a, daysAgo: 0, seconds: 200),
            RecommendationFixtures.event(a, daysAgo: 1, seconds: 200),
            RecommendationFixtures.event(b, daysAgo: 1, seconds: 100),
        ], favorites: [], playlists: [], recents: [], now: RecommendationFixtures.now)
        let catalog = RecommendationCatalogMock()
        await catalog.setRadio(RecommendationFixtures.tracks("n", count: 8, artist: "Newcomer"), for: "a")
        _ = try await engine(catalog).discoverWeekly(profile: profile, languages: [.hindi, .english], periodKey: "2026-W22")
        var requests = await catalog.radioRequests
        XCTAssertEqual(requests.first { $0.seed.id == "a" }?.language, .english, "The profile's dominant preferred language wins")
        XCTAssertEqual(requests.first { $0.seed.id == "b" }?.language, .english)

        let hindiOnly = RecommendationCatalogMock()
        await hindiOnly.setRadio(RecommendationFixtures.tracks("n", count: 8, artist: "Newcomer"), for: "a")
        _ = try await engine(hindiOnly).discoverWeekly(profile: profile, languages: [.hindi], periodKey: "2026-W22")
        requests = await hindiOnly.radioRequests
        XCTAssertEqual(requests.first { $0.seed.id == "a" }?.language, .hindi)
        XCTAssertEqual(requests.first { $0.seed.id == "b" }?.language, .english, "A known song language is never overridden")
    }

    // MARK: Daily Mix

    func testDailyMixBlendsFamiliarAndFreshSongsWithoutRepeats() async throws {
        let catalog = await RecommendationFixtures.catalog()
        let mix = try await daily(catalog)
        XCTAssertEqual(mix.kind, .dailyMix)
        XCTAssertEqual(mix.periodKey, "2026-05-28")
        XCTAssertEqual(mix.tracks.count, 25)
        XCTAssertEqual(Set(mix.tracks.map(\.id)).count, 25)
        XCTAssertTrue(artistCounts(mix.tracks).values.allSatisfy { $0 <= 3 }, "At most three songs per artist")
        let familiar = mix.tracks.filter { profile.trackAffinity[$0.id] != nil }
        XCTAssertEqual(familiar.count, 6, "Every listened song fits under the artist cap and is worth replaying")
        XCTAssertEqual(mix.tracks.count - familiar.count, 19)
        XCTAssertEqual(artistCounts(mix.tracks)["arijit singh"], 3, "Three listened Arijit songs leave no room for his unheard ones")
        XCTAssertEqual(mix.seedArtists, ["Arijit Singh", "The Weeknd", "Pritam"])
        let callCount = await catalog.callCount
        XCTAssertLessThanOrEqual(callCount, RecommendationEngine.providerCallBudget)
    }

    func testDailyMixInterleavesInsteadOfClumpingFamiliarSongs() async throws {
        let mix = try await daily(await RecommendationFixtures.catalog())
        let familiarPositions = mix.tracks.indices.filter { profile.trackAffinity[mix.tracks[$0].id] != nil }
        let gaps = zip(familiarPositions.dropFirst(), familiarPositions).map { $0 - $1 }
        XCTAssertTrue(gaps.allSatisfy { $0 >= 2 }, "Familiar songs are spaced out: \(familiarPositions)")
    }

    func testDailyMixIsStableWithinADayAndVariesAcrossDays() async throws {
        let today = try await daily(await RecommendationFixtures.catalog(), periodKey: "2026-05-28")
        let again = try await daily(await RecommendationFixtures.catalog(), periodKey: "2026-05-28")
        let tomorrow = try await daily(await RecommendationFixtures.catalog(), periodKey: "2026-05-29")
        XCTAssertEqual(today.tracks.map(\.id), again.tracks.map(\.id))
        XCTAssertNotEqual(today.tracks.map(\.id), tomorrow.tracks.map(\.id))
    }

    func testDailyMixFallsBackToFamiliarSongsWhenTheProviderIsThin() async throws {
        let catalog = RecommendationCatalogMock()
        await catalog.setRadio(RecommendationFixtures.tracks("n", count: 3, artist: "Newcomer"), for: "arijit-1")
        for id in ["UCarijit", "UCweeknd", "UCpritam"] { await catalog.setArtist(RecommendationFixtures.page(id, name: id)) }
        let mix = try await daily(catalog)
        XCTAssertEqual(mix.tracks.count, 9, "Six listened songs plus three recommendations")
        XCTAssertEqual(mix.tracks.filter { $0.artists == ["Newcomer"] }.count, 3)
    }

    func testDailyMixFiltersFamiliarSongsAndThinProviderTopupsByTheSameEligibility() async throws {
        let eligible = (0..<12).map {
            RecommendationFixtures.track("eligible-\($0)", artist: "Familiar Artist \($0)", language: $0 == 11 ? nil : .hindi)
        }
        let rejected = [
            RecommendationFixtures.track("known-english", artist: "English Artist", language: .english),
            RecommendationFixtures.track("karaoke", title: "A Song (Karaoke Version)", artist: "Karaoke Artist", language: .hindi),
            RecommendationFixtures.track("slowed", title: "A Song (Slowed + Reverb)", artist: "Slowed Artist", language: .hindi),
            RecommendationFixtures.track("video", artist: "Video Artist", language: .hindi, audio: false),
            RecommendationFixtures.track("too-short", artist: "Short Artist", duration: 5, language: .hindi),
            RecommendationFixtures.track("too-long", artist: "Long Artist", duration: 1_200, language: .hindi),
        ]
        let profile = TasteProfile.build(events: (eligible + rejected).map {
            RecommendationFixtures.event($0, daysAgo: 0, seconds: 100)
        }, favorites: [], playlists: [], recents: [], now: RecommendationFixtures.now)
        for freshCount in [20, 0] {
            let catalog = RecommendationCatalogMock()
            let fresh = (0..<freshCount).map { RecommendationFixtures.track("fresh-\($0)", artist: "Fresh Artist \($0)", language: .hindi) }
            for seed in profile.topTracks(limit: 4) { await catalog.setRadio(fresh, for: seed.id) }
            let result = try await engine(catalog).dailyMix(profile: profile, languages: [.hindi], periodKey: "2026-05-28")
            let mix = try XCTUnwrap(result)
            let ids = Set(mix.tracks.map(\.id))
            XCTAssertTrue(ids.isDisjoint(with: rejected.map(\.id)))
            XCTAssertTrue(mix.tracks.allSatisfy { $0.language != .english && $0.isAudioRecording != false })
            if freshCount == 0 {
                XCTAssertEqual(ids, Set(eligible.map(\.id)), "Topups must use the filtered familiar pool too")
                XCTAssertNil(mix.tracks.first { $0.id == "eligible-11" }?.language)
            } else {
                XCTAssertEqual(mix.tracks.count, 25)
                XCTAssertEqual(mix.tracks.filter { profile.trackAffinity[$0.id] != nil }.count, 10)
            }
        }
    }

    // MARK: Because you like

    func testBecauseYouListenBuildsASectionPerTopArtistWithAChannel() async throws {
        let catalog = await RecommendationFixtures.catalog()
        let sections = try await engine(catalog).becauseYouListen(profile: profile, languages: languages, limit: 2)
        XCTAssertEqual(sections.map(\.id), ["personal.UCarijit", "personal.UCweeknd"])
        XCTAssertEqual(sections.map(\.title), ["Because you like Arijit Singh", "Because you like The Weeknd"])
        XCTAssertEqual(sections.map(\.language), [.hindi, .english])
        XCTAssertTrue(sections.allSatisfy { $0.subtitle.isEmpty && $0.tracks.count <= 12 && !$0.tracks.isEmpty })
        XCTAssertEqual(sections[0].tracks.prefix(5).map(\.id), ["arijit-1", "arijit-2", "arijit-3", "arijit-top-4", "arijit-top-5"],
                       "The artist's own songs outrank the related artist's")
        XCTAssertTrue(sections[0].tracks.contains { $0.id == "UCshreya-1" })
        XCTAssertTrue(sections[1].tracks.contains { $0.id == "UCdrake-1" })
        let artistRequests = await catalog.artistRequests
        let callCount = await catalog.callCount
        XCTAssertEqual(callCount, 4)
        XCTAssertEqual(Set(artistRequests), ["UCarijit", "UCshreya", "UCweeknd", "UCdrake"])
    }

    func testBecauseYouListenHonorsTheLimitAndSkipsBrokenSeeds() async throws {
        let catalog = await RecommendationFixtures.catalog()
        let single = try await engine(catalog).becauseYouListen(profile: profile, languages: languages, limit: 1)
        XCTAssertEqual(single.map(\.id), ["personal.UCarijit"])
        await catalog.failArtist("UCarijit")
        let partial = try await engine(catalog).becauseYouListen(profile: profile, languages: languages, limit: 2)
        XCTAssertEqual(partial.map(\.id), ["personal.UCweeknd"])
        await catalog.failArtist("UCweeknd")
        do {
            _ = try await engine(catalog).becauseYouListen(profile: profile, languages: languages, limit: 2)
            XCTFail("Expected the provider error when every seed fails")
        } catch let error as RecommendationTestFailure {
            guard case .provider = error else { return XCTFail("Unexpected error \(error)") }
        }
        let empty = try await engine(catalog).becauseYouListen(profile: TasteProfile.build(events: [], favorites: [], playlists: [], recents: [], now: RecommendationFixtures.now),
                                                               languages: languages, limit: 2)
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: Period keys

    func testWeekKeysFollowISO8601WeeksStartingMonday() {
        let calendar = RecommendationFixtures.calendar
        XCTAssertEqual(RecommendationEngine.weekKey(for: libraryTestDate(2026, 9, 19, calendar: calendar), calendar: calendar), "2026-W38")
        XCTAssertEqual(RecommendationEngine.weekKey(for: libraryTestDate(2026, 9, 21, calendar: calendar), calendar: calendar), "2026-W39")
        XCTAssertEqual(RecommendationEngine.weekKey(for: libraryTestDate(2026, 9, 20, calendar: calendar), calendar: calendar), "2026-W38", "Sunday closes the week")
        XCTAssertEqual(RecommendationEngine.weekKey(for: libraryTestDate(2026, 1, 1, calendar: calendar), calendar: calendar), "2026-W01")
        XCTAssertEqual(RecommendationEngine.weekKey(for: libraryTestDate(2027, 1, 1, calendar: calendar), calendar: calendar), "2026-W53")
        XCTAssertEqual(RecommendationEngine.weekKey(for: libraryTestDate(2024, 12, 30, calendar: calendar), calendar: calendar), "2025-W01")
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        XCTAssertEqual(RecommendationEngine.weekKey(for: libraryTestDate(2026, 9, 20, calendar: calendar), calendar: sundayFirst), "2026-W38",
                       "The user's first weekday does not move ISO weeks")
    }

    func testDayKeysUseTheUsersTimeZone() {
        let utc = RecommendationFixtures.calendar
        let kolkata = libraryTestCalendar(timeZone: "Asia/Kolkata")
        let lateEvening = libraryTestDate(2026, 9, 19, hour: 22, calendar: utc)
        XCTAssertEqual(RecommendationEngine.dayKey(for: lateEvening, calendar: utc), "2026-09-19")
        XCTAssertEqual(RecommendationEngine.dayKey(for: lateEvening, calendar: kolkata), "2026-09-20")
        XCTAssertEqual(RecommendationEngine.dayKey(for: libraryTestDate(2026, 1, 5, calendar: utc), calendar: utc), "2026-01-05")
    }

    func testJitterIsDeterministicAndStaysInsideTheUnitInterval() {
        let first = RecommendationEngine.jitter(periodKey: "2026-W22", id: "abc")
        XCTAssertEqual(first, RecommendationEngine.jitter(periodKey: "2026-W22", id: "abc"))
        XCTAssertNotEqual(first, RecommendationEngine.jitter(periodKey: "2026-W23", id: "abc"))
        XCTAssertNotEqual(first, RecommendationEngine.jitter(periodKey: "2026-W22", id: "abd"))
        for id in (0..<200).map(String.init) {
            let value = RecommendationEngine.jitter(periodKey: "k", id: id)
            XCTAssertTrue(value > 0 && value < 1)
        }
    }
}
