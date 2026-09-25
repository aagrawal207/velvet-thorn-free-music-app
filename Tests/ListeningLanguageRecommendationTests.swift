import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class ListeningLanguageRecommendationTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures

    func testLegacyCallersStillUseTargetedRecommendationsAndTheirLanguageScope() async throws {
        let seeds = songs("seed", count: 4, language: .hindi)
        let hindi = songs("hindi", count: 8, language: .hindi)
        let english = songs("english", count: 8, language: .english)
        let catalog = await catalog(seeds: seeds, candidates: hindi + english)
        let result = try await engine(catalog).discoverWeekly(profile: taste(seeds), languages: [.hindi], periodKey: "week")
        let playlist = try XCTUnwrap(result)

        XCTAssertEqual(Set(playlist.tracks.map(\.id)), Set(hindi.map(\.id)))
        let targeted = await catalog.radioRequests
        let unrestricted = await catalog.unrestrictedRadioRequests
        XCTAssertEqual(targeted.count, 4)
        XCTAssertTrue(targeted.allSatisfy { $0.language == .hindi })
        XCTAssertTrue(unrestricted.isEmpty)
    }

    func testAutomaticMixesIgnoreLegacyScopeWithoutDroppingUnknownOrOtherLanguageSongs() async throws {
        let seeds = songs("seed", count: 4, language: .hindi)
        let english = songs("english", count: 8, language: .english)
        let tamil = Fixtures.track("tamil", artist: "Tamil performer")
        let unknown = Fixtures.track("unknown", artist: "Unlisted performer")
        let likely = Fixtures.track("likely", artist: seeds[0].artistName)
        let good = english + [tamil, unknown, likely]
        let blocked = Fixtures.track("blocked", artist: "Blocked performer")
        let rejected = [blocked, Fixtures.track("video", audio: false), Fixtures.track("short", duration: 5),
                        Fixtures.track("long", duration: 1_200), Fixtures.track("altered", title: "Song (Slowed + Reverb)")]
        let profile = taste(seeds, disliked: [DislikedSong(id: blocked.id, title: blocked.title, artists: blocked.artists)])
        let languages = ListeningLanguageProfile(evidence: [LyricsRequestKey(likely): .likely(.hindi, source: .titleLabel)],
                                                overrides: [tamil.id: "ta"], fallback: [.hindi])
        XCTAssertEqual(languages.language(for: tamil), .tamil)
        XCTAssertNil(languages.language(for: unknown))
        XCTAssertNil(languages.language(for: likely))
        XCTAssertEqual(languages.multiplier(for: unknown), 1)
        XCTAssertEqual(languages.multiplier(for: likely), 1)

        for kind in [GeneratedPlaylistKind.discoverWeekly, .dailyMix] {
            let catalog = await catalog(seeds: seeds, candidates: good + rejected)
            let playlist = try await playlist(kind, catalog: catalog, profile: profile, languageProfile: languages, scope: [.hindi])
            let ids = Set(playlist.tracks.map(\.id))
            XCTAssertTrue(Set(good.map(\.id)).isSubset(of: ids))
            XCTAssertTrue(ids.isDisjoint(with: rejected.map(\.id)))
            XCTAssertEqual(ids.count, playlist.tracks.count)
            XCTAssertNil(playlist.tracks.first { $0.id == tamil.id }?.language)
            XCTAssertNil(playlist.tracks.first { $0.id == unknown.id }?.language)
            XCTAssertNil(playlist.tracks.first { $0.id == likely.id }?.language)
            let targeted = await catalog.radioRequests
            let unrestricted = await catalog.unrestrictedRadioRequests
            XCTAssertTrue(targeted.isEmpty, "Automatic mixes cannot use the fixed catalog artist allow-list")
            XCTAssertEqual(unrestricted.count, 4)
        }
    }

    func testAutomaticPlaylistsKeepTheTenCallBudgetAndArtistCaps() async throws {
        for kind in [GeneratedPlaylistKind.discoverWeekly, .dailyMix] {
            let catalog = await Fixtures.catalog()
            let playlist = try await playlist(kind, catalog: catalog, profile: Fixtures.profile(), languageProfile: .init())
            let calls = await catalog.callCount
            let targeted = await catalog.radioRequests
            let radios = await catalog.unrestrictedRadioRequests
            let artists = await catalog.artistRequests
            XCTAssertEqual(calls, 10)
            XCTAssertLessThanOrEqual(calls, RecommendationEngine.providerCallBudget)
            XCTAssertTrue(targeted.isEmpty)
            XCTAssertEqual(radios.count, 4)
            XCTAssertEqual(Set(artists).count, artists.count)
            let cap = kind == .discoverWeekly ? 2 : 3
            let counts = Dictionary(grouping: playlist.tracks, by: RecommendationEngine.primaryArtistKey).mapValues(\.count)
            XCTAssertTrue(counts.values.allSatisfy { $0 <= cap })
            if kind == .discoverWeekly {
                XCTAssertTrue(Set(playlist.tracks.map(\.id)).isDisjoint(with: Fixtures.profile().heardTrackIDs))
            }
        }
    }

    func testAutomaticPlaylistsAreDeterministicWithinTheirPeriod() async throws {
        let seeds = songs("seed", count: 4, language: .english)
        let candidates = songs("candidate", count: 40)
        let profile = taste(seeds)
        for kind in [GeneratedPlaylistKind.discoverWeekly, .dailyMix] {
            let first = try await playlist(kind, catalog: await catalog(seeds: seeds, candidates: candidates),
                                           profile: profile, languageProfile: .init())
            let again = try await playlist(kind, catalog: await catalog(seeds: seeds, candidates: candidates),
                                           profile: profile, languageProfile: .init())
            XCTAssertEqual(first.tracks.map(\.id), again.tracks.map(\.id))
            XCTAssertEqual(first.periodKey, again.periodKey)
            XCTAssertEqual(first.seedArtists, again.seedArtists)
        }
    }

    func testNinetyTenListeningCountsMoveSeedAllocationAndCandidateOrder() async throws {
        let seeds = songs("hindi-seed", count: 6, language: .hindi) + songs("english-seed", count: 6, language: .english)
        let candidates = songs("hindi-new", count: 18, language: .hindi) + songs("english-new", count: 18, language: .english)
        let profile = taste(seeds)
        var orders: [[String]] = []
        for dominant in [MusicLanguage.hindi, .english] {
            let counts: [ArtistSongLanguage: Int] = dominant == .hindi ? [.hindi: 90, .english: 10] : [.hindi: 10, .english: 90]
            let catalog = await catalog(seeds: seeds, candidates: candidates)
            let playlist = try await playlist(.discoverWeekly, catalog: catalog, profile: profile,
                                              languageProfile: languageProfile(counts))
            let requests = await catalog.unrestrictedRadioRequests
            XCTAssertEqual(requests.count, 4)
            XCTAssertEqual(requests.filter { $0.language == dominant }.count, 3)
            XCTAssertEqual(requests.filter { $0.language != dominant }.count, 1, "Minority listening retains a seed slot")
            XCTAssertTrue(playlist.tracks.prefix(10).allSatisfy { $0.language == dominant })
            XCTAssertEqual(playlist.tracks.count, 30)
            orders.append(playlist.tracks.map(\.id))
        }
        XCTAssertNotEqual(orders[0], orders[1])
    }

    func testMoreCanAllocateASeedFromRecordingEvidenceOutsideTheEditorialLanguages() async throws {
        let tamil = Fixtures.track("tamil-seed", artist: "Tamil performer")
        let seeds = songs("hindi-seed", count: 6, language: .hindi) + songs("english-seed", count: 6, language: .english) + [tamil]
        var nudges = LanguageRecommendationNudges()
        nudges[.tamil] = .more
        let languages = languageProfile([.hindi: 90, .english: 10], nudges: nudges, overrides: [tamil.id: "ta"])
        let catalog = await catalog(seeds: seeds, candidates: songs("new", count: 12))
        _ = try await playlist(.discoverWeekly, catalog: catalog, profile: taste(seeds), languageProfile: languages)

        let requests = await catalog.unrestrictedRadioRequests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.contains { $0.id == tamil.id })
        XCTAssertNil(requests.first { $0.id == tamil.id }?.language, "Seed targeting cannot rewrite recording metadata")
        let targeted = await catalog.radioRequests
        XCTAssertTrue(targeted.isEmpty)
    }

    func testDailyFamiliarSamplingRespondsToCountsWhileKeepingItsShareAndArtistCaps() async throws {
        let seeds = songs("familiar-hindi", count: 24, language: .hindi) + songs("familiar-english", count: 24, language: .english)
        let fresh = songs("fresh", count: 24)
        let profile = taste(seeds)
        var hindiWithHindiPreference = 0
        var hindiWithEnglishPreference = 0
        for day in 21...28 {
            for dominant in [MusicLanguage.hindi, .english] {
                let counts: [ArtistSongLanguage: Int] = dominant == .hindi ? [.hindi: 90, .english: 10] : [.hindi: 10, .english: 90]
                let playlist = try await playlist(.dailyMix, catalog: await catalog(seeds: seeds, candidates: fresh), profile: profile,
                                                  languageProfile: languageProfile(counts), period: "2026-05-\(day)")
                let familiar = playlist.tracks.filter { profile.heardTrackIDs.contains($0.id) }
                XCTAssertEqual(playlist.tracks.count, 25)
                XCTAssertEqual(familiar.count, 10)
                XCTAssertEqual(Set(playlist.tracks.map(\.id)).count, 25)
                let artists = Dictionary(grouping: playlist.tracks, by: RecommendationEngine.primaryArtistKey)
                XCTAssertTrue(artists.values.allSatisfy { $0.count <= 3 })
                let hindiCount = familiar.filter { $0.language == .hindi }.count
                if dominant == .hindi { hindiWithHindiPreference += hindiCount }
                else { hindiWithEnglishPreference += hindiCount }
            }
        }
        XCTAssertGreaterThan(hindiWithHindiPreference, hindiWithEnglishPreference)
    }

    func testBecauseYouListenWeightsRecordingsWithoutTreatingTheArtistsLanguageAsProof() async throws {
        let seed = Fixtures.track("artist-seed", artist: "Known artist", artistID: "UCweightedArtist", language: .hindi)
        let unknown = Fixtures.track("unknown-neighbor", artist: seed.artistName)
        let candidates = songs("hindi", count: 4, language: .hindi) + songs("english", count: 4, language: .english) + [unknown]
        let blocked = Fixtures.track("blocked", artist: "Blocked artist", language: .english)
        let profile = taste([seed] + songs("other-seed", count: 2),
                            disliked: [DislikedSong(id: blocked.id, title: blocked.title, artists: blocked.artists)])
        for dominant in [MusicLanguage.hindi, .english] {
            let counts: [ArtistSongLanguage: Int] = dominant == .hindi ? [.hindi: 90, .english: 10] : [.hindi: 10, .english: 90]
            let languages = languageProfile(counts)
            let catalog = RecommendationCatalogMock()
            await catalog.setArtist(Fixtures.page("UCweightedArtist", name: seed.artistName, topSongs: candidates + [blocked]))
            let sections = try await engine(catalog).becauseYouListen(profile: profile, languages: [.hindi], languageProfile: languages)
            let section = try XCTUnwrap(sections.first)
            XCTAssertEqual(sections.count, 1)
            XCTAssertEqual(Set(section.tracks.map(\.id)), Set(candidates.map(\.id)))
            XCTAssertEqual(section.tracks.first?.language, dominant)
            XCTAssertNil(section.language, "An artist-led section has no single recording language")
            XCTAssertNil(section.tracks.first { $0.id == unknown.id }?.language)
            XCTAssertNil(languages.language(for: unknown))
            XCTAssertEqual(languages.multiplier(for: unknown), 1)
        }
    }

    func testAutomaticPlaylistPartialFailuresKeepUsefulCandidatesAndAllFailuresThrow() async throws {
        let seeds = songs("seed", count: 4, language: .hindi)
        let candidates = songs("candidate", count: 12)
        for kind in [GeneratedPlaylistKind.discoverWeekly, .dailyMix] {
            let partial = await catalog(seeds: seeds, candidates: candidates)
            await partial.failRadio(for: seeds[0].id)
            let recovered = try await playlist(kind, catalog: partial, profile: taste(seeds), languageProfile: .init())
            XCTAssertTrue(Set(candidates.map(\.id)).isSubset(of: Set(recovered.tracks.map(\.id))))

            let failed = RecommendationCatalogMock()
            for seed in seeds { await failed.failRadio(for: seed.id) }
            do {
                _ = try await playlist(kind, catalog: failed, profile: taste(seeds), languageProfile: .init())
                XCTFail("A provider outage must remain retryable")
            } catch let error as RecommendationTestFailure {
                guard case .provider = error else { return XCTFail("Unexpected failure") }
            }
            let calls = await failed.callCount
            XCTAssertEqual(calls, 4)
        }
    }

    func testLessLowersPriorityWithoutBanningTheLanguageOrUnknownSongs() async throws {
        let seed = Fixtures.track("seed", artist: "Known performer", artistID: "UCsoftNudge", language: .hindi)
        let hindi = Fixtures.track("hindi", artist: "Hindi performer", language: .hindi)
        let english = Fixtures.track("english", artist: "English performer", language: .english)
        let unknown = Fixtures.track("unknown", artist: "Unclassified performer")
        var nudges = LanguageRecommendationNudges()
        nudges[.hindi] = .less
        let languages = languageProfile([.hindi: 50, .english: 50], nudges: nudges)
        let catalog = RecommendationCatalogMock()
        await catalog.setArtist(Fixtures.page("UCsoftNudge", name: seed.artistName, topSongs: [hindi, unknown, english]))
        let sections = try await engine(catalog).becauseYouListen(profile: taste([seed]), languages: [.hindi], languageProfile: languages)
        XCTAssertEqual(sections.first?.tracks.map(\.id), [english.id, unknown.id, hindi.id])
        XCTAssertNil(sections.first?.tracks.first { $0.id == unknown.id }?.language)
    }

    func testAutomaticMixColdStartDoesNotSpendTheProviderBudget() async throws {
        let catalog = RecommendationCatalogMock()
        let cold = taste([])
        let weekly = try await engine(catalog).discoverWeekly(profile: cold, languages: [], periodKey: "week", languageProfile: .init())
        let daily = try await engine(catalog).dailyMix(profile: cold, languages: [], periodKey: "day", languageProfile: .init())
        XCTAssertNil(weekly)
        XCTAssertNil(daily)
        let calls = await catalog.callCount
        XCTAssertEqual(calls, 0)
    }

    func testCancelledAutomaticHarvestRejectsLateResultsWithoutFurtherFanout() async throws {
        let catalog = AppModelCatalogProvider()
        addTeardownBlock { await catalog.close() }
        let profile = taste(songs("seed", count: 4, language: .english))
        let engine = engine(catalog)
        let task = Task {
            try await engine.discoverWeekly(profile: profile, languages: [], periodKey: "week", languageProfile: .init())
        }
        defer { task.cancel() }
        var requests: [AppModelRequestGate<Track, [Track]>.Request] = []
        for index in 0..<4 { requests.append(try await catalog.autoplayRadios.request(at: index)) }
        task.cancel()
        for request in requests {
            try await catalog.autoplayRadios.complete(request, with: .success(songs("late", count: 12)))
        }
        do { _ = try await task.value; XCTFail("Cancelled recommendations cannot publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let artists = await catalog.artists.requests
        let targeted = await catalog.radios.requests
        let radios = await catalog.autoplayRadios.requests
        XCTAssertTrue(artists.isEmpty && targeted.isEmpty)
        XCTAssertEqual(radios.count, 4)
    }

    func testMoreForAnUnheardLanguageSearchesWithoutInventingListeningOrRecordingLabels() async throws {
        var nudges = LanguageRecommendationNudges()
        nudges[.tamil] = .more
        let unknown = Fixtures.track("unknown", artist: "Unlisted performer")
        let english = Fixtures.track("english", artist: "English performer", language: .english)
        let tamil = Fixtures.track("tamil", artist: "Tamil performer")
        let languages = languageProfile([.hindi: 50, .english: 50], nudges: nudges, overrides: [tamil.id: "ta"])
        let catalog = ExperienceRadioCatalogFixture(searches: ["Tamil songs": .success([unknown, english, tamil])])
        let sections = try await engine(catalog).languageDiscovery(profile: taste([]), languageProfile: languages, limit: 1)
        let section = try XCTUnwrap(sections.first)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(section.id, "discovery.language.ta")
        XCTAssertEqual(section.title, "Tamil to explore")
        XCTAssertEqual(section.subtitle, "A little more Tamil")
        XCTAssertNil(section.language)
        XCTAssertEqual(Set(section.tracks.map(\.id)), [unknown.id, english.id, tamil.id])
        XCTAssertEqual(section.tracks.map(\.id), [english.id, unknown.id, tamil.id], "The target does not override soft recording weights")
        XCTAssertNil(section.tracks.first { $0.id == unknown.id }?.language)
        XCTAssertNil(section.tracks.first { $0.id == tamil.id }?.language)
        XCTAssertEqual(languages.summary.totalPlays, 100)
        XCTAssertFalse(languages.summary.rows.contains { $0.language == .tamil && $0.plays > 0 })
        let requests = await catalog.searchRequests
        let radios = await catalog.radioRequests
        XCTAssertEqual(requests.map(\.query), ["Tamil songs"])
        XCTAssertTrue(requests.allSatisfy { $0.filter == .songs && $0.continuation == nil })
        XCTAssertTrue(radios.isEmpty)
    }

    func testLanguageDiscoverySeedsUseRecordingEvidenceAndReturnUnrestrictedNeighbors() async throws {
        let seed = Fixtures.track("corrected-seed", artist: "Known performer", language: .hindi)
        let unknown = Fixtures.track("unknown-seed", artist: seed.artistName)
        let other = Fixtures.track("other-seed", artist: "Other performer", language: .english)
        let candidates = songs("unclassified-new", count: 6) + songs("english-new", count: 3, language: .english)
        let languages = languageProfile([.tamil: 90, .english: 10], overrides: [seed.id: "ta"])
        let catalog = ExperienceRadioCatalogFixture(radios: [seed.id: .success([seed] + candidates)])
        let sections = try await engine(catalog).languageDiscovery(profile: taste([seed, unknown, other]),
                                                                   languageProfile: languages, limit: 1)
        let section = try XCTUnwrap(sections.first)
        XCTAssertEqual(section.id, "discovery.language.ta")
        XCTAssertEqual(section.subtitle, "Inspired by your listening")
        XCTAssertNil(section.language)
        XCTAssertEqual(Set(section.tracks.map(\.id)), Set(candidates.map(\.id)))
        XCTAssertTrue(section.tracks.filter { $0.id.hasPrefix("unclassified") }.allSatisfy { $0.language == nil })
        let radios = await catalog.radioRequests
        let targeted = await catalog.targetedRadioRequests
        let searches = await catalog.searchRequests
        XCTAssertEqual(radios.map(\.id), [seed.id])
        XCTAssertEqual(targeted, 0)
        XCTAssertTrue(searches.isEmpty)
    }

    func testLanguageDiscoveryCapsTargetsAndFallbackCallsAndFiltersUnusableAudio() async throws {
        let hindi = Fixtures.track("hindi-seed", artist: "Hindi performer", language: .hindi)
        let english = Fixtures.track("english-seed", artist: "English performer", language: .english)
        let blocked = Fixtures.track("blocked", artist: "Blocked performer")
        let bad = [blocked, Fixtures.track("video", audio: false), Fixtures.track("unverified", audio: nil),
                   Fixtures.track("short", duration: 5), Fixtures.track("altered", title: "Song (Karaoke Version)"),
                   Fixtures.track(" ", title: "Missing ID"), Fixtures.track("empty-title", title: " ")]
        let good = songs("unknown", count: 6) + songs("english", count: 6, language: .english)
        let prolific = Fixtures.tracks("prolific", count: 8, artist: "Prolific performer")
        let profile = taste([hindi, english], disliked: [DislikedSong(id: blocked.id, title: blocked.title, artists: blocked.artists)])
        let languages = languageProfile([.hindi: 90, .english: 10, .bengali: 4, .tamil: 2, .telugu: 1])
        let catalog = ExperienceRadioCatalogFixture(searches: [
            "Hindi songs": .success(bad + good + prolific + [good[0]]),
            "English songs": .success(bad + good + prolific + [good[0]]),
        ], radios: [hindi.id: .success(bad + [hindi]), english.id: .failure(MusicServiceError.network("Offline fixture"))])
        let sections = try await engine(catalog).languageDiscovery(profile: profile, languageProfile: languages, limit: 100)

        XCTAssertEqual(sections.map(\.id), ["discovery.language.hi", "discovery.language.en"])
        XCTAssertEqual(sections.map(\.language), [.hindi, .english])
        for section in sections {
            XCTAssertEqual(section.subtitle, "Inspired by your listening")
            XCTAssertEqual(section.tracks.count, 12)
            XCTAssertTrue(section.tracks.allSatisfy { $0.isAudioRecording == true })
            XCTAssertTrue(Set(section.tracks.map(\.id)).isDisjoint(with: bad.map(\.id)))
            XCTAssertEqual(Set(section.tracks.map(\.id)).count, section.tracks.count)
            XCTAssertTrue(section.tracks.contains { $0.id == good[0].id && $0.language == nil })
            XCTAssertTrue(section.tracks.contains { $0.language == .english })
            let artists = Dictionary(grouping: section.tracks, by: RecommendationEngine.primaryArtistKey)
            XCTAssertTrue(artists.values.allSatisfy { $0.count <= 3 })
        }
        let searches = await catalog.searchRequests
        let radios = await catalog.radioRequests
        XCTAssertEqual(searches.count, 2)
        XCTAssertEqual(Set(searches.map(\.query)), ["Hindi songs", "English songs"])
        XCTAssertTrue(searches.allSatisfy { $0.filter == .songs && $0.continuation == nil })
        XCTAssertEqual(radios.count, 2)
        XCTAssertLessThanOrEqual(searches.count + radios.count, 4)
    }

    func testColdLanguageDiscoveryUsesLabelledSearchTargetsWithoutGatingOnTaste() async throws {
        let candidates = songs("cold", count: 4)
        let catalog = ExperienceRadioCatalogFixture(searches: ["Hindi songs": .success(candidates), "English songs": .success(candidates)])
        let profile = taste([])
        XCTAssertTrue(profile.isColdStart)
        let sections = try await engine(catalog).languageDiscovery(profile: profile, languageProfile: .init())
        XCTAssertEqual(Set(sections.map(\.id)), ["discovery.language.hi", "discovery.language.en"])
        XCTAssertTrue(sections.allSatisfy { $0.subtitle == "A starting point while Breezy learns your listening" })
        XCTAssertTrue(sections.flatMap(\.tracks).allSatisfy { $0.language == nil })
        let requests = await catalog.searchRequests
        let radios = await catalog.radioRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(radios.isEmpty)
    }

    func testLanguageDiscoveryPartialFailuresKeepTheAvailableSection() async throws {
        let candidate = Fixtures.track("available", artist: "Unlisted performer")
        let catalog = ExperienceRadioCatalogFixture(searches: [
            "Hindi songs": .failure(MusicServiceError.network("Offline fixture")), "English songs": .success([candidate]),
        ])
        let sections = try await engine(catalog).languageDiscovery(profile: taste([]), languageProfile: .init())
        XCTAssertEqual(sections.map(\.id), ["discovery.language.en"])
        XCTAssertEqual(sections.first?.tracks, [candidate])
    }

    func testLanguageDiscoveryEmptyAndPartiallyFailedEmptyResponsesStayEmpty() async throws {
        for failure in [false, true] {
            let hindi: Result<[Track], any Error> = failure ? .failure(MusicServiceError.network("Offline fixture")) : .success([])
            let catalog = ExperienceRadioCatalogFixture(searches: ["Hindi songs": hindi, "English songs": .success([])])
            let sections = try await engine(catalog).languageDiscovery(profile: taste([]), languageProfile: .init())
            XCTAssertTrue(sections.isEmpty)
            let requests = await catalog.searchRequests
            let browses = await catalog.browseRequests
            let radios = await catalog.radioRequests
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(browses.isEmpty && radios.isEmpty, "An empty result does not manufacture an editorial fallback")
        }
    }

    func testLanguageDiscoveryAllSourcesFailWithARetryableServiceError() async throws {
        let hindi = Fixtures.track("hindi-seed", artist: "Hindi performer", language: .hindi)
        let english = Fixtures.track("english-seed", artist: "English performer", language: .english)
        let catalog = ExperienceRadioCatalogFixture(searches: [
            "Hindi songs": .failure(MusicServiceError.rateLimited), "English songs": .failure(MusicServiceError.rateLimited),
        ], radios: [hindi.id: .failure(MusicServiceError.rateLimited), english.id: .failure(MusicServiceError.rateLimited)])
        do {
            _ = try await engine(catalog).languageDiscovery(profile: taste([hindi, english]),
                                                            languageProfile: languageProfile([.hindi: 90, .english: 10]))
            XCTFail("An outage must not look like a successful empty catalog")
        } catch { guard case .rateLimited? = error as? MusicServiceError else { return XCTFail("Expected the service cooldown") } }
        let searches = await catalog.searchRequests
        let radios = await catalog.radioRequests
        XCTAssertEqual(searches.count + radios.count, 4)
    }

    func testLanguageDiscoveryNonpositiveLimitsSpendNoCalls() async throws {
        let catalog = ExperienceRadioCatalogFixture()
        for limit in [0, -1] {
            let sections = try await engine(catalog).languageDiscovery(profile: taste([]), languageProfile: .init(), limit: limit)
            XCTAssertTrue(sections.isEmpty)
        }
        let searches = await catalog.searchRequests
        let radios = await catalog.radioRequests
        XCTAssertTrue(searches.isEmpty && radios.isEmpty)
    }

    func testCancelledLanguageDiscoveryRejectsLateRadioAndSearchWithoutMoreRequests() async throws {
        for hasSeed in [true, false] {
            let catalog = AppModelCatalogProvider()
            addTeardownBlock { await catalog.close() }
            let seed = Fixtures.track("seed", artist: "Known performer", language: .hindi)
            let profile = taste(hasSeed ? [seed] : [])
            let languages = languageProfile([.hindi: 3])
            let engine = engine(catalog)
            let task = Task { try await engine.languageDiscovery(profile: profile, languageProfile: languages, limit: 1) }
            defer { task.cancel() }
            if hasSeed {
                let request = try await catalog.autoplayRadios.request(at: 0)
                task.cancel()
                try await catalog.autoplayRadios.complete(request, with: .success(songs("late", count: 4)))
            } else {
                let request = try await catalog.searches.request(at: 0)
                task.cancel()
                try await catalog.searches.complete(request, with: .success(CatalogPage(tracks: songs("late", count: 4))))
            }
            do { _ = try await task.value; XCTFail("A cancelled discovery cannot publish") }
            catch { XCTAssertTrue(error is CancellationError) }
            let searches = await catalog.searches.requests
            let radios = await catalog.autoplayRadios.requests
            let targeted = await catalog.radios.requests
            XCTAssertEqual(searches.count, hasSeed ? 0 : 1)
            XCTAssertEqual(radios.count, hasSeed ? 1 : 0)
            XCTAssertTrue(targeted.isEmpty)
        }
    }

    private func songs(_ prefix: String, count: Int, language: MusicLanguage? = nil) -> [Track] {
        (0..<count).map { Fixtures.track("\(prefix)-\($0)", artist: "Artist \(prefix)-\($0)", language: language) }
    }

    private func taste(_ tracks: [Track], disliked: [DislikedSong] = []) -> TasteProfile {
        TasteProfile.build(events: tracks.map { Fixtures.event($0, daysAgo: 0, seconds: 120) },
                           favorites: [], playlists: [], recents: [], disliked: disliked, now: Fixtures.now)
    }

    private func catalog(seeds: [Track], candidates: [Track]) async -> RecommendationCatalogMock {
        let catalog = RecommendationCatalogMock()
        for seed in seeds { await catalog.setRadio(candidates, for: seed.id) }
        return catalog
    }

    private func engine(_ catalog: any MusicCatalogProviding) -> RecommendationEngine {
        RecommendationEngine(catalog: catalog, now: { Fixtures.now })
    }

    private func languageProfile(_ counts: [ArtistSongLanguage: Int], nudges: LanguageRecommendationNudges = .init(),
                                 evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [:],
                                 overrides: [String: String] = [:]) -> ListeningLanguageProfile {
        let total = counts.values.reduce(0, +)
        let rows = ArtistSongLanguage.allCases.compactMap { language -> LanguageListeningStat? in
            guard let plays = counts[language], plays > 0 else { return nil }
            return LanguageListeningStat(language: language, plays: plays, songs: 1, share: Double(plays) / Double(total))
        }
        return ListeningLanguageProfile(summary: ListeningLanguageSummary(rows: rows, totalPlays: total, totalSongs: rows.count),
                                        nudges: nudges, evidence: evidence, overrides: overrides)
    }

    private func playlist(_ kind: GeneratedPlaylistKind, catalog: any MusicCatalogProviding, profile: TasteProfile,
                          languageProfile: ListeningLanguageProfile, scope: Set<MusicLanguage> = [],
                          period: String = "2026-05-28") async throws -> GeneratedPlaylist {
        let result: GeneratedPlaylist?
        switch kind {
        case .discoverWeekly:
            result = try await engine(catalog).discoverWeekly(profile: profile, languages: scope, periodKey: period,
                                                              languageProfile: languageProfile)
        case .dailyMix:
            result = try await engine(catalog).dailyMix(profile: profile, languages: scope, periodKey: period,
                                                       languageProfile: languageProfile)
        }
        return try XCTUnwrap(result)
    }
}
