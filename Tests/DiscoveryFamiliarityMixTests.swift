import XCTest
@testable import GanaBajana

@MainActor
final class DiscoveryFamiliarityMixTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures
    private let modes: [DiscoveryFamiliarity] = [.familiar, .balanced, .newMusic]

    func testDailyModesTargetEighteenTenAndFourFamiliarSongsWithStableDailyOrders() async throws {
        let known = songs("known", count: 32)
        let fresh = songs("fresh", count: 40)
        let profile = taste(known)
        let expectations: [(DiscoveryFamiliarity, Int)] = [(.familiar, 18), (.balanced, 10), (.newMusic, 4)]
        for (mode, expected) in expectations {
            let catalog = await catalog(profile: profile, candidates: fresh)
            let result = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode)
            let playlist = try XCTUnwrap(result)
            XCTAssertEqual(playlist.tracks.count, 25)
            XCTAssertEqual(familiarCount(playlist.tracks, profile: profile), expected)
            XCTAssertEqual(playlist.periodKey, "2026-05-28")
            XCTAssertEqual(playlist.generatedAt, Fixtures.now)
            assertSelection(playlist.tracks, allowed: known + fresh, artistCap: 3)

            let repeated = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode)
            XCTAssertEqual(playlist.tracks, repeated?.tracks)
            XCTAssertEqual(playlist.seedArtists, repeated?.seedArtists)
            let requests = await catalog.unrestrictedRadioRequests
            XCTAssertEqual(requests.count, 8, "Two generations reuse the same four-call seed budget")
        }
    }

    func testEveryDailyModeKeepsItsTargetWhenHeardNeighborsDominateProviderScores() async throws {
        let known = songs("known", count: 32)
        let fresh = songs("fresh", count: 40)
        let profile = taste(known)
        let expectations: [(DiscoveryFamiliarity, Int)] = [(.familiar, 18), (.balanced, 10), (.newMusic, 4)]
        let languageProfiles: [ListeningLanguageProfile?] = [nil, ListeningLanguageProfile()]
        for (mode, expected) in expectations {
            for languageProfile in languageProfiles {
                let catalog = RecommendationCatalogMock()
                for (index, seed) in profile.topTracks(limit: 4).enumerated() {
                    await catalog.setRadio(known + (index == 0 ? fresh : []), for: seed.id)
                }
                let result = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode, languageProfile: languageProfile)
                let playlist = try XCTUnwrap(result)
                XCTAssertEqual(playlist.tracks.count, 25)
                XCTAssertEqual(familiarCount(playlist.tracks, profile: profile), expected)
                XCTAssertEqual(playlist.tracks.filter { !profile.heardTrackIDs.contains($0.id) }.count, 25 - expected)
                assertSelection(playlist.tracks, allowed: known + fresh, artistCap: 3)
                let calls = await catalog.callCount
                XCTAssertEqual(calls, 4)
                if mode == .balanced {
                    let defaulted = try await engine(catalog).dailyMix(profile: profile, languages: [], periodKey: "2026-05-28",
                                                                      languageProfile: languageProfile)
                    XCTAssertEqual(playlist.tracks, defaulted?.tracks)
                }
            }
        }
    }

    func testDailyModesKeepLanguageRankingIndependentOfTheFamiliarQuota() async throws {
        let known = songs("known", count: 32)
        let fresh = songs("hindi", count: 20, language: .hindi) + songs("english", count: 20, language: .english)
        let profile = taste(known)
        let expectations: [(DiscoveryFamiliarity, Int)] = [(.familiar, 18), (.balanced, 10), (.newMusic, 4)]
        for (mode, expected) in expectations {
            for dominant in [MusicLanguage.hindi, .english] {
                var nudges = LanguageRecommendationNudges()
                nudges[.hindi] = dominant == .hindi ? .more : .less
                nudges[.english] = dominant == .english ? .more : .less
                let languages = ListeningLanguageProfile(nudges: nudges)
                let catalog = await catalog(profile: profile, candidates: fresh)
                let result = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode,
                                           languages: [.hindi], languageProfile: languages)
                let playlist = try XCTUnwrap(result)
                XCTAssertEqual(playlist.tracks.count, 25)
                XCTAssertEqual(familiarCount(playlist.tracks, profile: profile), expected)
                let discovered = playlist.tracks.filter { !profile.heardTrackIDs.contains($0.id) }
                XCTAssertTrue(discovered.prefix(20).allSatisfy { $0.language == dominant })
                if mode == .newMusic {
                    XCTAssertEqual(discovered.count, 21)
                    XCTAssertNotEqual(discovered.last?.language, dominant, "A minority language remains eligible")
                }
                let targeted = await catalog.radioRequests
                let radios = await catalog.unrestrictedRadioRequests
                XCTAssertTrue(targeted.isEmpty)
                XCTAssertEqual(radios.count, 4)
            }
        }
    }

    func testDailyFamiliarEvidenceIncludesProviderRecentsTapsLikesAndPlaylistSaves() async throws {
        let seeds = songs("seed", count: 3)
        let liked = songs("liked", count: 4)
        let saved = songs("saved", count: 4)
        let recents = songs("recent-only", count: 4)
        let taps = songs("tap-only", count: 4)
        let events = seeds.map { Fixtures.event($0, daysAgo: 0, seconds: 240) }
            + taps.map { Fixtures.event($0, daysAgo: 0, seconds: 0.5) }
        let profile = TasteProfile.build(events: events, favorites: liked, playlists: [UserPlaylist(name: "Saved", tracks: saved)],
            recents: recents.map { RecentListen(track: $0, playedAt: Fixtures.now, position: 5) }, now: Fixtures.now)
        let known = seeds + liked + saved + recents + taps
        let fresh = songs("fresh", count: 30)
        XCTAssertFalse(profile.isColdStart)
        XCTAssertTrue((recents + taps).allSatisfy { profile.trackAffinity[$0.id] == nil })
        let expectations: [(DiscoveryFamiliarity, Int)] = [(.familiar, 18), (.balanced, 10), (.newMusic, 4)]
        for (mode, expected) in expectations {
            let catalog = await catalog(profile: profile, candidates: known + fresh)
            let result = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode)
            let playlist = try XCTUnwrap(result)
            XCTAssertEqual(playlist.tracks.count, 25)
            XCTAssertEqual(familiarCount(playlist.tracks, profile: profile), expected)
            if mode == .familiar {
                let ids = Set(playlist.tracks.map(\.id))
                XCTAssertTrue(Set((liked + saved).map(\.id)).isSubset(of: ids))
                XCTAssertFalse(ids.isDisjoint(with: recents.map(\.id)))
                XCTAssertFalse(ids.isDisjoint(with: taps.map(\.id)))
            }
            assertSelection(playlist.tracks, allowed: known + fresh, artistCap: 3)
        }
    }

    func testDailySingleThinAndZeroPoolsRelaxSharesWithoutInventingSongsOrRequests() async throws {
        let seeds = songs("seed", count: 4, language: .hindi)
        let cases = [(known: 30, fresh: 0, count: 25, familiar: 25),
                     (known: 0, fresh: 30, count: 25, familiar: 0),
                     (known: 2, fresh: 30, count: 25, familiar: 2),
                     (known: 30, fresh: 2, count: 25, familiar: 23),
                     (known: 5, fresh: 4, count: 9, familiar: 5),
                     (known: 3, fresh: 4, count: 0, familiar: 0),
                     (known: 0, fresh: 0, count: 0, familiar: 0)]
        for mode in modes {
            for item in cases {
                let known = songs("known", count: item.known, language: .english)
                let fresh = songs("fresh", count: item.fresh, language: .english)
                let profile = taste(seeds, favorites: known)
                let catalog = await catalog(profile: profile, candidates: fresh)
                let result = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode,
                                           languages: [.english], languageProfile: nil)
                if item.count == 0 {
                    XCTAssertNil(result, "Fewer than eight eligible songs cannot publish a mix")
                } else {
                    let playlist = try XCTUnwrap(result)
                    XCTAssertEqual(playlist.tracks.count, item.count)
                    XCTAssertEqual(familiarCount(playlist.tracks, profile: profile), item.familiar)
                    assertSelection(playlist.tracks, allowed: known + fresh, artistCap: 3)
                }
                let calls = await catalog.callCount
                XCTAssertEqual(calls, 4, "A shortage cannot spend another provider request")
            }
        }
    }

    func testDailyModesUseLocalRecentsWithoutAffinityOrAProviderEcho() async throws {
        let seeds = songs("seed", count: 4)
        let recents = songs("recent-only", count: 24)
        let profile = taste(seeds, recents: recents)
        XCTAssertTrue(recents.allSatisfy { profile.trackAffinity[$0.id] == nil })
        let expectations: [(DiscoveryFamiliarity, Int)] = [(.familiar, 18), (.balanced, 10), (.newMusic, 4)]
        for (mode, expected) in expectations {
            for freshCount in [30, 0] {
                let fresh = songs("fresh", count: freshCount)
                let catalog = await catalog(profile: profile, candidates: fresh)
                let result = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode)
                let playlist = try XCTUnwrap(result)
                XCTAssertEqual(playlist.tracks.count, 25)
                XCTAssertEqual(familiarCount(playlist.tracks, profile: profile), freshCount == 0 ? 25 : expected)
                assertSelection(playlist.tracks, allowed: seeds + recents + fresh, artistCap: 3)
                let repeated = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode)
                XCTAssertEqual(result?.tracks, repeated?.tracks)
                let calls = await catalog.callCount
                XCTAssertEqual(calls, 8, "Both generations retain the four-call budget")
            }
        }
    }

    func testDailyModesPreserveAchievableQuotasAcrossSharedArtistCaps() async throws {
        let known = (0..<4).map { Fixtures.track("shared-known-\($0)", artist: "Shared artist \($0 / 3)") }
        let alternatives = songs("recent-only", count: 18)
        let profile = taste(known, recents: alternatives)
        let expectations: [(DiscoveryFamiliarity, Int)] = [(.familiar, 18), (.balanced, 10), (.newMusic, 4)]
        for (mode, expected) in expectations {
            let fresh = (0..<(25 - expected)).map { Fixtures.track("fresh-\($0)", artist: "Shared artist \($0 / 3)") }
            let catalog = await catalog(profile: profile, candidates: fresh)
            let result = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode)
            let playlist = try XCTUnwrap(result)
            XCTAssertEqual(playlist.tracks.count, 25)
            XCTAssertEqual(familiarCount(playlist.tracks, profile: profile), expected)
            XCTAssertTrue(Set(fresh.map(\.id)).isSubset(of: Set(playlist.tracks.map(\.id))),
                          "Higher-affinity familiar songs must not displace an achievable unheard quota through artist caps")
            XCTAssertTrue(Set(playlist.tracks.map(\.id)).isDisjoint(with: known.map(\.id)))
            assertSelection(playlist.tracks, allowed: known + alternatives + fresh, artistCap: 3)
            let calls = await catalog.callCount
            XCTAssertEqual(calls, 4)
        }
    }

    func testDailyModesRelaxQuotasForGenuineSharedArtistShortages() async throws {
        let known = (0..<4).map { Fixtures.track("shared-known-\($0)", artist: "Shared artist \($0 / 3)") }
        let profile = taste(known)
        for mode in modes {
            for freshCount in [6, 9] {
                let fresh = (0..<freshCount).map { Fixtures.track("fresh-\($0)", artist: "Shared artist \($0 / 3)") }
                let catalog = await catalog(profile: profile, candidates: fresh)
                let result = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode)
                if freshCount == 6 {
                    XCTAssertNil(result, "Two shared artists allow only six songs, below the eight-song minimum")
                } else {
                    let playlist = try XCTUnwrap(result)
                    XCTAssertEqual(playlist.tracks.count, 9)
                    XCTAssertEqual(familiarCount(playlist.tracks, profile: profile), 4)
                    assertSelection(playlist.tracks, allowed: known + fresh, artistCap: 3)
                }
                let calls = await catalog.callCount
                XCTAssertEqual(calls, 4)
            }
        }
    }

    func testDailyTopupsKeepDislikesAudioEligibilityArtistCapsAndRecordingDeduplication() async throws {
        let known = songs("known", count: 20) + Fixtures.tracks("known-bulk", count: 8, artist: "Known prolific artist")
        let fresh = songs("fresh", count: 3) + Fixtures.tracks("fresh-bulk", count: 8, artist: "New prolific artist")
        let blocked = [Fixtures.track("blocked-known", artist: "Blocked known"), Fixtures.track("blocked-new", artist: "Blocked new")]
        let rejected = [Fixtures.track("video", audio: false), Fixtures.track("short", duration: 5),
                        Fixtures.track("long", duration: 1_200), Fixtures.track("karaoke", title: "Song (Karaoke Version)"),
                        Fixtures.track("sped-up", title: "Song (Sped Up)"), Fixtures.track("")]
        let profile = taste(known, favorites: blocked + rejected,
                            disliked: blocked.map { DislikedSong(id: $0.id, title: $0.title, artists: $0.artists) })
        for mode in modes {
            let catalog = await catalog(profile: profile, candidates: known + fresh + blocked + rejected + [fresh[0]])
            let result = try await mix(.dailyMix, catalog: catalog, profile: profile, mode: mode)
            let playlist = try XCTUnwrap(result)
            XCTAssertEqual(playlist.tracks.count, 25)
            assertSelection(playlist.tracks, allowed: known + fresh, artistCap: 3)
            XCTAssertTrue(Set(playlist.tracks.map(\.id)).isDisjoint(with: (blocked + rejected).map(\.id)))
        }
    }

    func testWeeklyModesShiftKnownAndFeaturedArtistsButNeverReplayAnyHeardEvidence() async throws {
        let seeds = songs("seed", count: 4)
        let liked = Fixtures.track("liked", artist: "Liked artist")
        let saved = Fixtures.track("saved", artist: "Saved artist")
        let recent = Fixtures.track("recent", artist: "Recent artist")
        let tap = Fixtures.track("tap", artist: "Tap artist")
        let blocked = Fixtures.track("blocked", artist: "Blocked artist")
        let profile = TasteProfile.build(events: seeds.map { Fixtures.event($0, daysAgo: 0, seconds: 240) }
            + [Fixtures.event(tap, daysAgo: 0, seconds: 0.5)], favorites: [liked],
            playlists: [UserPlaylist(name: "Saved", tracks: [saved])],
            recents: [RecentListen(track: recent, playedAt: Fixtures.now, position: 5)],
            disliked: [DislikedSong(id: blocked.id, title: blocked.title, artists: blocked.artists)], now: Fixtures.now)
        let solo = Fixtures.track("known-solo", artist: seeds[0].artistName)
        var feature = Fixtures.track("known-feature", artist: "Guest singer")
        feature.artists.append("  \(seeds[1].artistName.uppercased())  ")
        let known = [solo, feature]
        let high = Fixtures.track("new-high", artist: "High affinity newcomer")
        let middle = songs("new-middle", count: 8) + Fixtures.tracks("bulk", count: 8, artist: "Prolific newcomer")
        let heard = seeds + [liked, saved, recent, tap]
        for mode in modes {
            let catalog = RecommendationCatalogMock()
            for (index, seed) in seeds.enumerated() {
                let candidates = known + heard + [blocked, solo] + (index < 3 ? [high] : []) + (index < 2 ? middle : [])
                await catalog.setRadio(candidates, for: seed.id)
            }
            let result = try await mix(.discoverWeekly, catalog: catalog, profile: profile, mode: mode)
            let playlist = try XCTUnwrap(result)
            XCTAssertEqual(playlist.tracks.count, 13)
            XCTAssertTrue(Set(playlist.tracks.map(\.id)).isDisjoint(with: profile.heardTrackIDs))
            assertSelection(playlist.tracks, allowed: known + [high] + middle, artistCap: 2)
            let knownIDs = Set(known.map(\.id))
            switch mode {
            case .familiar:
                XCTAssertEqual(Set(playlist.tracks.prefix(2).map(\.id)), knownIDs)
            case .balanced:
                XCTAssertEqual(playlist.tracks.first?.id, high.id)
                XCTAssertEqual(Set(playlist.tracks.dropFirst().prefix(2).map(\.id)), knownIDs)
                let defaulted = try await engine(catalog).discoverWeekly(profile: profile, languages: [], periodKey: "2026-W22",
                                                                         languageProfile: .init())
                XCTAssertEqual(playlist.tracks, defaulted?.tracks)
            case .newMusic:
                XCTAssertEqual(Set(playlist.tracks.suffix(2).map(\.id)), knownIDs)
            }
            let repeated = try await mix(.discoverWeekly, catalog: catalog, profile: profile, mode: mode)
            XCTAssertEqual(playlist.tracks, repeated?.tracks)

            let heardOnly = await self.catalog(profile: profile, candidates: heard)
            let empty = try await mix(.discoverWeekly, catalog: heardOnly, profile: profile, mode: mode)
            XCTAssertNil(empty, "Even More familiar cannot fill a weekly shortage by replaying a recording")
        }
    }

    func testEveryMixModeRetainsTheTenCallBudgetAndAutomaticRadioRouting() async throws {
        for mode in modes {
            for kind in GeneratedPlaylistKind.allCases {
                let catalog = await Fixtures.catalog()
                let result = try await mix(kind, catalog: catalog, profile: Fixtures.profile(), mode: mode)
                let playlist = try XCTUnwrap(result)
                XCTAssertEqual(playlist.tracks.count, kind == .discoverWeekly ? 30 : 25)
                let calls = await catalog.callCount
                let targeted = await catalog.radioRequests
                let radios = await catalog.unrestrictedRadioRequests
                let artists = await catalog.artistRequests
                XCTAssertEqual(calls, 10)
                XCTAssertTrue(targeted.isEmpty)
                XCTAssertEqual(radios.count, 4)
                XCTAssertEqual(Set(artists).count, artists.count)
            }
        }
    }

    func testMixModesKeepPartialResponsesEmptyResultsAndAllSourceErrorsDistinct() async throws {
        let seeds = songs("seed", count: 4)
        let profile = taste(seeds)
        let fresh = songs("fresh", count: 30)
        for mode in modes {
            for kind in GeneratedPlaylistKind.allCases {
                for failures in [1, 3, 4] {
                    let catalog = await catalog(profile: profile, candidates: failures == 3 ? [] : fresh)
                    for seed in seeds.prefix(failures) { await catalog.failRadio(for: seed.id) }
                    do {
                        let result = try await mix(kind, catalog: catalog, profile: profile, mode: mode)
                        if failures == 4 { XCTFail("A provider outage must remain retryable") }
                        else if failures == 3 { XCTAssertNil(result) }
                        else {
                            let playlist = try XCTUnwrap(result)
                            XCTAssertEqual(playlist.tracks.count, kind == .discoverWeekly ? 30 : 25)
                        }
                    } catch {
                        guard failures == 4, case .provider? = error as? RecommendationTestFailure else { throw error }
                    }
                    let calls = await catalog.callCount
                    XCTAssertEqual(calls, 4)
                }
            }
        }
    }

    func testColdStartAndPreCancelledMixesSpendNoProviderCallsInAnyMode() async throws {
        let cold = taste([], favorites: songs("liked", count: 30))
        XCTAssertTrue(cold.isColdStart)
        for mode in modes {
            for kind in GeneratedPlaylistKind.allCases {
                let catalog = RecommendationCatalogMock()
                let result = try await mix(kind, catalog: catalog, profile: cold, mode: mode)
                XCTAssertNil(result)
                let task = Task { try await self.mix(kind, catalog: catalog, profile: cold, mode: mode) }
                task.cancel()
                do { _ = try await task.value; XCTFail("Cancellation precedes the cold-start shortcut") }
                catch { XCTAssertTrue(error is CancellationError) }
                let calls = await catalog.callCount
                XCTAssertEqual(calls, 0)
            }
        }
    }

    func testCancelledMixModesRejectLateRadioAndArtistResponsesBeforeRelatedFanout() async throws {
        let profile = Fixtures.profile()
        let late = songs("late", count: 30)
        for mode in modes {
            for kind in GeneratedPlaylistKind.allCases {
                let catalog = AppModelCatalogProvider()
                addTeardownBlock { await catalog.close() }
                let task = Task { try await self.mix(kind, catalog: catalog, profile: profile, mode: mode) }
                defer { task.cancel() }
                var radios: [AppModelRequestGate<Track, [Track]>.Request] = []
                var artists: [AppModelRequestGate<String, ArtistPage>.Request] = []
                for index in 0..<4 { radios.append(try await catalog.autoplayRadios.request(at: index)) }
                for index in 0..<3 { artists.append(try await catalog.artists.request(at: index)) }
                task.cancel()
                for request in radios { try await catalog.autoplayRadios.complete(request, with: .success(late)) }
                for request in artists {
                    let page = Fixtures.page(request.input, name: request.input, topSongs: late,
                                             related: [Fixtures.relatedArtist("related-\(request.input)", name: "Related artist")])
                    try await catalog.artists.complete(request, with: .success(page))
                }
                do { _ = try await task.value; XCTFail("Cancelled generations cannot return a playlist") }
                catch { XCTAssertTrue(error is CancellationError) }
                let radioCalls = await catalog.autoplayRadios.requests
                let artistCalls = await catalog.artists.requests
                let targeted = await catalog.radios.requests
                let searches = await catalog.searches.requests
                XCTAssertEqual(radioCalls.count, 4)
                XCTAssertEqual(artistCalls.count, 3)
                XCTAssertTrue(targeted.isEmpty && searches.isEmpty)
            }
        }
    }

    private func songs(_ prefix: String, count: Int, language: MusicLanguage? = nil) -> [Track] {
        (0..<count).map { Fixtures.track("\(prefix)-\($0)", artist: "Artist \(prefix)-\($0)", language: language) }
    }

    private func taste(_ tracks: [Track], favorites: [Track] = [], recents: [Track] = [],
                       disliked: [DislikedSong] = []) -> TasteProfile {
        TasteProfile.build(events: tracks.map { Fixtures.event($0, daysAgo: 0, seconds: 240) }, favorites: favorites,
            playlists: [], recents: recents.map { RecentListen(track: $0, playedAt: Fixtures.now, position: 5) },
            disliked: disliked, now: Fixtures.now)
    }

    private func catalog(profile: TasteProfile, candidates: [Track]) async -> RecommendationCatalogMock {
        let catalog = RecommendationCatalogMock()
        for seed in profile.topTracks(limit: profile.trackAffinity.count) { await catalog.setRadio(candidates, for: seed.id) }
        return catalog
    }

    private func engine(_ catalog: any MusicCatalogProviding) -> RecommendationEngine {
        RecommendationEngine(catalog: catalog, now: { Fixtures.now })
    }

    private func mix(_ kind: GeneratedPlaylistKind, catalog: any MusicCatalogProviding, profile: TasteProfile,
                     mode: DiscoveryFamiliarity, languages: Set<MusicLanguage> = [],
                     languageProfile: ListeningLanguageProfile? = ListeningLanguageProfile()) async throws -> GeneratedPlaylist? {
        switch kind {
        case .discoverWeekly:
            try await engine(catalog).discoverWeekly(profile: profile, languages: languages, periodKey: "2026-W22",
                languageProfile: languageProfile, familiarity: mode)
        case .dailyMix, .dailyMix2, .dailyMix3:
            try await engine(catalog).dailyMix(profile: profile, languages: languages, periodKey: "2026-05-28",
                languageProfile: languageProfile, familiarity: mode)
        }
    }

    private func familiarCount(_ tracks: [Track], profile: TasteProfile) -> Int {
        tracks.filter { profile.heardTrackIDs.contains($0.id) }.count
    }

    private func assertSelection(_ tracks: [Track], allowed: [Track], artistCap: Int,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let ids = Set(tracks.map(\.id))
        XCTAssertEqual(ids.count, tracks.count, file: file, line: line)
        XCTAssertTrue(ids.isSubset(of: Set(allowed.map(\.id))), file: file, line: line)
        let artists = Dictionary(grouping: tracks, by: RecommendationEngine.primaryArtistKey)
        XCTAssertTrue(artists.values.allSatisfy { $0.count <= artistCap }, file: file, line: line)
    }
}
