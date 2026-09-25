import XCTest
@testable import GanaBajana

@MainActor
final class DiscoveryFamiliarityShelfTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures
    private enum Shelf: CaseIterable { case because, language }
    private let modes: [DiscoveryFamiliarity] = [.familiar, .balanced, .newMusic]
    private let seed = Fixtures.track("shelf-seed", artist: "Seed artist", artistID: "UCshelf", language: .hindi)

    func testEachShelfModeChangesCompositionAndBalancedPreservesProviderOrder() async throws {
        let known = songs("known", count: 18)
        let fresh = songs("fresh", count: 18)
        let candidates = zip(fresh, known).flatMap { [$0.0, $0.1] }
        let profile = taste(seeds: [seed], heard: known)
        XCTAssertTrue(profile.isColdStart, "Home shelves remain available before mix qualification")
        let expectations: [(DiscoveryFamiliarity, Int)] = [(.familiar, 12), (.balanced, 6), (.newMusic, 0)]
        for shelf in Shelf.allCases {
            for (mode, expected) in expectations {
                let catalog = catalog(candidates)
                let result = try await sections(shelf, catalog: catalog, profile: profile, mode: mode)
                let section = try XCTUnwrap(result.first)
                XCTAssertEqual(result.count, 1)
                XCTAssertEqual(section.tracks.count, 12)
                XCTAssertEqual(section.tracks.filter { profile.heardTrackIDs.contains($0.id) }.count, expected)
                let repeated = try await sections(shelf, catalog: catalog, profile: profile, mode: mode)
                XCTAssertEqual(section.tracks, repeated.first?.tracks)
                if mode == .balanced {
                    XCTAssertEqual(section.tracks, Array(candidates.prefix(12)))
                    let defaulted: [DiscoverySection]
                    switch shelf {
                    case .because:
                        defaulted = try await engine(catalog).becauseYouListen(profile: profile, languages: [], limit: 1,
                            languageProfile: ListeningLanguageProfile(fallback: [.hindi]))
                    case .language:
                        defaulted = try await engine(catalog).languageDiscovery(profile: profile,
                            languageProfile: ListeningLanguageProfile(fallback: [.hindi]), limit: 1)
                    }
                    XCTAssertEqual(section.tracks, defaulted.first?.tracks)
                }
            }
        }
    }

    func testShelfFamiliarityUsesHeardTapsRecentsLikesAndPlaylistSaves() async throws {
        let known = songs("known", count: 4)
        let fresh = songs("fresh", count: 4)
        let profile = TasteProfile.build(events: [Fixtures.event(known[0], daysAgo: 0, seconds: 0.5)],
            favorites: [seed, known[1]], playlists: [UserPlaylist(name: "Saved", tracks: [known[2]])],
            recents: [RecentListen(track: known[3], playedAt: Fixtures.now, position: 5)], now: Fixtures.now)
        let candidates = zip(fresh, known).flatMap { [$0.0, $0.1] }
        for shelf in Shelf.allCases {
            for mode in [DiscoveryFamiliarity.familiar, .newMusic] {
                let result = try await sections(shelf, catalog: catalog(candidates), profile: profile, mode: mode)
                let tracks = try XCTUnwrap(result.first).tracks
                XCTAssertEqual(tracks.count, 8)
                XCTAssertEqual(Array(tracks.prefix(4)), mode == .familiar ? known : fresh)
                XCTAssertEqual(Set(tracks.map(\.id)), Set(candidates.map(\.id)))
            }
        }
    }

    func testFamiliarityAndLanguageNudgesBothAffectRankWithoutExcludingEitherGroup() async throws {
        let hindiNew = Fixtures.track("hindi-new", artist: "Hindi new", language: .hindi)
        let hindiKnown = Fixtures.track("hindi-known", artist: "Hindi known", language: .hindi)
        let englishNew = Fixtures.track("english-new", artist: "English new", language: .english)
        let englishKnown = Fixtures.track("english-known", artist: "English known", language: .english)
        let unknownNew = Fixtures.track("unknown-new", artist: "Unclassified new")
        let unknownKnown = Fixtures.track("unknown-known", artist: "Unclassified known")
        let candidates = [englishNew, englishKnown, hindiNew, hindiKnown, unknownNew, unknownKnown]
        let profile = taste(seeds: [seed], heard: [hindiKnown, englishKnown, unknownKnown])
        var nudges = LanguageRecommendationNudges()
        nudges[.hindi] = .more
        nudges[.english] = .less
        let languages = ListeningLanguageProfile(nudges: nudges)
        for shelf in Shelf.allCases {
            for mode in modes {
                let result = try await sections(shelf, catalog: catalog(candidates), profile: profile, mode: mode,
                                                languageProfile: languages)
                let tracks = try XCTUnwrap(result.first).tracks
                let expected: [Track] = switch mode {
                case .familiar: [hindiKnown, hindiNew, unknownKnown, englishKnown, unknownNew, englishNew]
                case .balanced: [hindiNew, hindiKnown, unknownNew, unknownKnown, englishNew, englishKnown]
                case .newMusic: [hindiNew, hindiKnown, unknownNew, englishNew, unknownKnown, englishKnown]
                }
                XCTAssertEqual(tracks, expected)
                XCTAssertNil(tracks.first { $0.id == unknownKnown.id }?.language)
                XCTAssertNil(tracks.first { $0.id == unknownNew.id }?.language)
                XCTAssertEqual(languages.summary.totalPlays, 0, "Preference weights cannot invent listening evidence")
            }
        }
    }

    func testSingleThinAndZeroShelfPoolsStayUsableWithoutPreferenceDrivenRefetches() async throws {
        for shelf in Shelf.allCases {
            for mode in modes {
                for (knownCount, freshCount) in [(15, 0), (0, 15), (2, 2), (0, 1), (0, 0)] {
                    let known = songs("known", count: knownCount)
                    let fresh = songs("fresh", count: freshCount)
                    let candidates = known + fresh
                    let catalog = catalog(candidates)
                    let result = try await sections(shelf, catalog: catalog, profile: taste(seeds: [seed], heard: known),
                        mode: mode, languageProfile: learnedLanguages(hindi: 3, english: 0))
                    let tracks = result.flatMap(\.tracks)
                    XCTAssertEqual(tracks.count, min(12, candidates.count))
                    XCTAssertTrue(Set(tracks.map(\.id)).isSubset(of: Set(candidates.map(\.id))))
                    if candidates.count <= 12 { XCTAssertEqual(Set(tracks.map(\.id)), Set(candidates.map(\.id))) }
                    let radios = await catalog.radioRequests
                    let searches = await catalog.searchRequests
                    let artists = await catalog.artistRequests
                    let expectedCalls = shelf == .language && candidates.isEmpty ? 2 : 1
                    XCTAssertEqual(radios.count + searches.count + artists.count, expectedCalls)
                }
            }
        }
    }

    func testShelfModesPreserveDislikesAudioFiltersDuplicatesAndTheirOwnArtistLimits() async throws {
        let known = songs("known", count: 6)
        let fresh = songs("fresh", count: 6)
        let prolific = Fixtures.tracks("prolific", count: 8, artist: "Prolific artist")
        let blocked = Fixtures.track("blocked", artist: "Blocked artist")
        let rejected = [blocked, Fixtures.track("video", audio: false), Fixtures.track("short", duration: 5),
                        Fixtures.track("long", duration: 1_200), Fixtures.track("karaoke", title: "Song (Karaoke Version)"),
                        Fixtures.track("")]
        let profile = TasteProfile.build(events: [], favorites: [seed, blocked], playlists: [],
            recents: known.map { RecentListen(track: $0, playedAt: Fixtures.now, position: 5) },
            disliked: [DislikedSong(id: blocked.id, title: blocked.title, artists: blocked.artists)], now: Fixtures.now)
        let candidates = rejected + prolific + known + fresh + [known[0]]
        for shelf in Shelf.allCases {
            for mode in modes {
                let result = try await sections(shelf, catalog: catalog(candidates), profile: profile, mode: mode)
                let tracks = try XCTUnwrap(result.first).tracks
                let ids = Set(tracks.map(\.id))
                XCTAssertEqual(tracks.count, 12)
                XCTAssertEqual(ids.count, tracks.count)
                XCTAssertTrue(ids.isDisjoint(with: rejected.map(\.id)))
                let count = tracks.filter { $0.artistName == "Prolific artist" }.count
                if shelf == .language { XCTAssertEqual(count, 3) }
                else { XCTAssertGreaterThanOrEqual(count, 6, "Artist-led shelves retain their uncapped artist contract") }
            }
        }
    }

    func testLanguageModesKeepTwoTargetsFourFallbackCallsAndStrictAudioValidation() async throws {
        let englishSeed = Fixtures.track("english-seed", artist: "English seed", language: .english)
        let known = songs("known", count: 6)
        let fresh = songs("fresh", count: 12)
        let blocked = Fixtures.track("blocked", artist: "Blocked artist")
        let bad = [blocked, Fixtures.track("video", audio: false), Fixtures.track("unverified", audio: nil),
                   Fixtures.track("short", duration: 5), Fixtures.track("long", duration: 1_200),
                   Fixtures.track("altered", title: "Song (Slowed + Reverb)"),
                   Fixtures.track(" ", title: "Missing ID"), Fixtures.track("missing-title", title: " ")]
        let profile = TasteProfile.build(events: [seed, englishSeed, seed].map { Fixtures.event($0, daysAgo: 0, seconds: 120) },
            favorites: [], playlists: [], recents: known.map { RecentListen(track: $0, playedAt: Fixtures.now, position: 5) },
            disliked: [DislikedSong(id: blocked.id, title: blocked.title, artists: blocked.artists)], now: Fixtures.now)
        for mode in modes {
            let catalog = ExperienceRadioCatalogFixture(searches: [
                "Hindi songs": .success(bad + known + fresh + [known[0]]),
                "English songs": .success(bad + known + fresh + [known[0]]),
            ], radios: [seed.id: .success([seed] + bad), englishSeed.id: .failure(MusicServiceError.rateLimited)])
            let result = try await engine(catalog).languageDiscovery(profile: profile,
                languageProfile: learnedLanguages(hindi: 90, english: 10), limit: 100, familiarity: mode)
            XCTAssertEqual(result.map(\.id), ["discovery.language.hi", "discovery.language.en"])
            for section in result {
                XCTAssertEqual(section.tracks.count, 12)
                XCTAssertEqual(Set(section.tracks.map(\.id)).count, 12)
                XCTAssertTrue(section.tracks.allSatisfy { $0.isAudioRecording == true })
                XCTAssertTrue(Set(section.tracks.map(\.id)).isDisjoint(with: bad.map(\.id)))
            }
            let radios = await catalog.radioRequests
            let searches = await catalog.searchRequests
            let targeted = await catalog.targetedRadioRequests
            let artists = await catalog.artistRequests
            let browses = await catalog.browseRequests
            XCTAssertEqual(radios.count, 2)
            XCTAssertEqual(searches.count, 2)
            XCTAssertEqual(Set(searches.map(\.query)), ["Hindi songs", "English songs"])
            XCTAssertTrue(searches.allSatisfy { $0.filter == .songs && $0.continuation == nil })
            XCTAssertEqual(targeted, 0)
            XCTAssertTrue(artists.isEmpty && browses.isEmpty)
        }
    }

    func testBecauseModesKeepTheTwoSeedFourArtistCallBudgetAndRelatedFailureFallback() async throws {
        for mode in modes {
            let catalog = await Fixtures.catalog()
            let result = try await engine(catalog).becauseYouListen(profile: Fixtures.profile(), languages: [], limit: 100,
                                                                   languageProfile: .init(), familiarity: mode)
            XCTAssertEqual(result.count, 2)
            XCTAssertTrue(result.allSatisfy { !$0.tracks.isEmpty && $0.tracks.count <= 12 })
            let calls = await catalog.callCount
            XCTAssertEqual(calls, 4)

            let partial = await Fixtures.catalog()
            await partial.failArtist("UCshreya")
            let recovered = try await engine(partial).becauseYouListen(profile: Fixtures.profile(), languages: [], limit: 1,
                                                                       languageProfile: .init(), familiarity: mode)
            XCTAssertEqual(recovered.count, 1)
            XCTAssertEqual(recovered.first?.tracks.count, 5)
            let partialCalls = await partial.callCount
            XCTAssertEqual(partialCalls, 2)
        }
    }

    func testShelfModesDistinguishPartialSuccessPartialEmptyAndAllSourceFailures() async throws {
        let a = Fixtures.track("a", artist: "Artist A", artistID: "UCa")
        let b = Fixtures.track("b", artist: "Artist B", artistID: "UCb")
        let available = Fixtures.track("available", artist: "Available artist")
        let cases: [(response: Result<[Track], any Error>, expected: Int?)] = [
            (.success([available]), 1), (.success([]), 0), (.failure(MusicServiceError.rateLimited), nil),
        ]
        for shelf in Shelf.allCases {
            for mode in modes {
                for item in cases {
                    let catalog = ExperienceRadioCatalogFixture(searches: [
                        "Hindi songs": .failure(MusicServiceError.rateLimited), "English songs": item.response,
                    ], artists: [
                        "UCa": .failure(MusicServiceError.rateLimited),
                        "UCb": item.response.map { Fixtures.page("UCb", name: "Artist B", topSongs: $0) },
                    ])
                    let profile = taste(seeds: shelf == .because ? [a, b] : [])
                    do {
                        let result = try await sections(shelf, catalog: catalog, profile: profile, mode: mode,
                                                        languageProfile: .init(), limit: 2)
                        guard let expected = item.expected else { XCTFail("All source failures must remain retryable"); continue }
                        XCTAssertEqual(result.count, expected)
                        XCTAssertEqual(result.flatMap(\.tracks), expected == 0 ? [] : [available])
                    } catch {
                        guard item.expected == nil, case .rateLimited? = error as? MusicServiceError else { throw error }
                    }
                    let searches = await catalog.searchRequests
                    let artists = await catalog.artistRequests
                    XCTAssertEqual(searches.count + artists.count, 2)
                }
            }
        }
    }

    func testNonpositiveShelfLimitsAndMissingArtistSeedsSpendNoCalls() async throws {
        for mode in modes {
            let catalog = catalog(songs("unused", count: 12))
            for shelf in Shelf.allCases {
                for limit in [0, -1] {
                    let result = try await sections(shelf, catalog: catalog, profile: taste(seeds: [seed]), mode: mode, limit: limit)
                    XCTAssertTrue(result.isEmpty)
                }
            }
            let empty = try await engine(catalog).becauseYouListen(profile: taste(), languages: [], familiarity: mode)
            XCTAssertTrue(empty.isEmpty)
            let searches = await catalog.searchRequests
            let artists = await catalog.artistRequests
            let radios = await catalog.radioRequests
            XCTAssertTrue(searches.isEmpty && artists.isEmpty && radios.isEmpty)
        }
    }

    func testPreCancelledShelfModesSpendNoCalls() async throws {
        for mode in modes {
            for shelf in Shelf.allCases {
                let catalog = catalog(songs("unused", count: 12))
                let profile = taste(seeds: [seed])
                let task = Task { try await self.sections(shelf, catalog: catalog, profile: profile, mode: mode) }
                task.cancel()
                do { _ = try await task.value; XCTFail("A cancelled shelf cannot publish") }
                catch { XCTAssertTrue(error is CancellationError) }
                let searches = await catalog.searchRequests
                let artists = await catalog.artistRequests
                let radios = await catalog.radioRequests
                XCTAssertTrue(searches.isEmpty && artists.isEmpty && radios.isEmpty)
            }
        }
    }

    func testCancelledLanguageModesRejectLateRadioAndSearchWithoutAnotherRequest() async throws {
        for mode in modes {
            for hasSeed in [true, false] {
                let catalog = AppModelCatalogProvider()
                addTeardownBlock { await catalog.close() }
                let profile = taste(seeds: hasSeed ? [seed] : [])
                let languages = learnedLanguages(hindi: 3, english: 0)
                let task = Task { try await self.sections(.language, catalog: catalog, profile: profile, mode: mode,
                                                          languageProfile: languages) }
                defer { task.cancel() }
                if hasSeed {
                    let request = try await catalog.autoplayRadios.request(at: 0)
                    task.cancel()
                    try await catalog.autoplayRadios.complete(request, with: .success(songs("late", count: 12)))
                } else {
                    let request = try await catalog.searches.request(at: 0)
                    task.cancel()
                    try await catalog.searches.complete(request, with: .success(CatalogPage(tracks: songs("late", count: 12))))
                }
                do { _ = try await task.value; XCTFail("Late responses cannot publish cancelled shelves") }
                catch { XCTAssertTrue(error is CancellationError) }
                let searches = await catalog.searches.requests
                let radios = await catalog.autoplayRadios.requests
                let targeted = await catalog.radios.requests
                XCTAssertEqual(searches.count, hasSeed ? 0 : 1)
                XCTAssertEqual(radios.count, hasSeed ? 1 : 0)
                XCTAssertTrue(targeted.isEmpty)
            }
        }
    }

    func testCancelledBecauseModesRejectLateSeedAndRelatedArtistResponses() async throws {
        for mode in modes {
            for cancelRelated in [false, true] {
                let catalog = AppModelCatalogProvider()
                addTeardownBlock { await catalog.close() }
                let profile = taste(seeds: [seed])
                let task = Task { try await self.sections(.because, catalog: catalog, profile: profile, mode: mode) }
                defer { task.cancel() }
                let request = try await catalog.artists.request(at: 0)
                let page = Fixtures.page(request.input, name: seed.artistName, topSongs: songs("seed-page", count: 12),
                                         related: [Fixtures.relatedArtist("UCrelated", name: "Related artist")])
                if cancelRelated {
                    try await catalog.artists.complete(request, with: .success(page))
                    let related = try await catalog.artists.request(at: 1)
                    task.cancel()
                    try await catalog.artists.complete(related, with: .success(Fixtures.page(related.input, name: "Related artist",
                                                                                           topSongs: songs("related-page", count: 12))))
                } else {
                    task.cancel()
                    try await catalog.artists.complete(request, with: .success(page))
                }
                do { _ = try await task.value; XCTFail("Cancelled artist shelves cannot publish") }
                catch { XCTAssertTrue(error is CancellationError) }
                let artists = await catalog.artists.requests
                let searches = await catalog.searches.requests
                let radios = await catalog.autoplayRadios.requests
                XCTAssertEqual(artists.count, cancelRelated ? 2 : 1)
                XCTAssertTrue(searches.isEmpty && radios.isEmpty)
            }
        }
    }

    private func songs(_ prefix: String, count: Int) -> [Track] {
        (0..<count).map { Fixtures.track("\(prefix)-\($0)", artist: "Artist \(prefix)-\($0)") }
    }

    private func taste(seeds: [Track] = [], heard: [Track] = []) -> TasteProfile {
        TasteProfile.build(events: [], favorites: seeds, playlists: [],
            recents: heard.map { RecentListen(track: $0, playedAt: Fixtures.now, position: 5) }, now: Fixtures.now)
    }

    private func learnedLanguages(hindi: Int, english: Int) -> ListeningLanguageProfile {
        let total = hindi + english
        let counts: [(ArtistSongLanguage, Int)] = [(.hindi, hindi), (.english, english)]
        let rows = counts.filter { $0.1 > 0 }.map {
            LanguageListeningStat(language: $0.0, plays: $0.1, songs: 1, share: Double($0.1) / Double(total))
        }
        return ListeningLanguageProfile(summary: ListeningLanguageSummary(rows: rows, totalPlays: total, totalSongs: rows.count))
    }

    private func catalog(_ candidates: [Track]) -> ExperienceRadioCatalogFixture {
        ExperienceRadioCatalogFixture(searches: ["Hindi songs": .success(candidates), "English songs": .success(candidates)],
            radios: [seed.id: .success(candidates)],
            artists: ["UCshelf": .success(Fixtures.page("UCshelf", name: seed.artistName, topSongs: candidates))])
    }

    private func engine(_ catalog: any MusicCatalogProviding) -> RecommendationEngine {
        RecommendationEngine(catalog: catalog, now: { Fixtures.now })
    }

    private func sections(_ shelf: Shelf, catalog: any MusicCatalogProviding, profile: TasteProfile, mode: DiscoveryFamiliarity,
                          languageProfile: ListeningLanguageProfile = ListeningLanguageProfile(fallback: [.hindi]),
                          limit: Int = 1) async throws -> [DiscoverySection] {
        switch shelf {
        case .because:
            try await engine(catalog).becauseYouListen(profile: profile, languages: [], limit: limit,
                                                       languageProfile: languageProfile, familiarity: mode)
        case .language:
            try await engine(catalog).languageDiscovery(profile: profile, languageProfile: languageProfile, limit: limit,
                                                        familiarity: mode)
        }
    }
}
