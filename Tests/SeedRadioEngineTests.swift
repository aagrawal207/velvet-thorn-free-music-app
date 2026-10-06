import XCTest
@testable import GanaBajana

@MainActor
final class SeedRadioEngineTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures

    func testSelectionExcludesQueueDislikesAndAliasesWithoutDroppingOtherArtistsCommonTitles() {
        let queued = Fixtures.track("queue", title: "Home", artist: "Alex")
        let alias = Fixtures.track("alias", title: "Home (Remastered)", artist: "Alex")
        let otherHome = Fixtures.track("other-home", title: "Home", artist: "Blair")
        let excluded = Fixtures.track("excluded", title: "Echo (Remix)", artist: "Alex")
        let otherEcho = Fixtures.track("other-echo", title: "Echo", artist: "Blair")
        let disliked = DislikedSong(id: "original-echo", title: "Echo", artists: ["Alex"])
        let invalid = [Fixtures.track("video", audio: false), Fixtures.track("unknown-audio", audio: nil),
                       Fixtures.track(""), Fixtures.track("bad-duration", duration: .nan)]
        let result = select([queued, alias, otherHome, excluded, otherEcho] + invalid,
                            excluding: [queued], disliked: [disliked])
        XCTAssertEqual(result.map(\.id), [otherHome.id, otherEcho.id])
    }

    func testRecordingIdentityPreservesMeaningfulVersionsAndUncertainMatches() {
        let original = Fixtures.track("original", title: "Home", artist: "Alex", artistID: "artist-a")
        var remaster = original
        remaster.id = "remaster"
        remaster.title = "Home (2020 Remaster)"
        XCTAssertTrue(select([remaster], excluding: [original]).isEmpty)
        XCTAssertEqual(select([original, remaster]).map(\.id), [original.id])

        var live = remaster
        live.title = "Home (Live)"
        var missingDuration = remaster
        missingDuration.duration = nil
        var distantDuration = remaster
        distantDuration.duration = 251
        var namesake = remaster
        namesake.credits = [ArtistCredit(name: "Alex", id: "different-artist")]
        var collaboration = remaster
        collaboration.credits.append(ArtistCredit(name: "Blair", id: "artist-b"))
        var otherLanguage = remaster
        otherLanguage.language = .hindi
        var englishOriginal = original
        englishOriginal.language = .english
        for candidate in [live, missingDuration, distantDuration, namesake, collaboration, otherLanguage] {
            XCTAssertEqual(select([candidate], excluding: [englishOriginal]).map(\.id), [candidate.id], candidate.title)
        }
    }

    func testArtistCapAndAdjacencyIncludeTheExistingQueueTail() {
        let a = (0..<3).map { Fixtures.track("a\($0)", artist: "Alex") }
        let b = (0..<2).map { Fixtures.track("b\($0)", artist: "Blair") }
        let c = Fixtures.track("c", artist: "Casey")
        let tail = Fixtures.track("tail", artist: "Alex")
        let result = select(a + b + [c], excluding: [tail])
        XCTAssertEqual(result.map(\.id), ["b0", "a0", "b1", "a1", "c"])
        XCTAssertEqual(result.filter { $0.artists.first == "Alex" }.count, 2)
        for pair in zip([tail] + result, result) {
            XCTAssertNotEqual(RecommendationEngine.primaryArtistKey(pair.0), RecommendationEngine.primaryArtistKey(pair.1))
        }
    }

    func testFamiliarAndDiscoverPrioritizeOppositePoolsWhileBalancedInterleaves() {
        let known = songs("known", count: 3)
        let fresh = songs("fresh", count: 3)
        let heard = Set(known.map(\.id))
        let candidates = fresh + known
        let familiar = select(candidates, familiarity: .familiar, heard: heard, limit: 4)
        let discover = select(candidates, familiarity: .newMusic, heard: heard, limit: 4)
        let balanced = select(candidates, heard: heard, limit: 4)
        XCTAssertEqual(familiar.map(\.id), ["known0", "known1", "known2", "fresh0"])
        XCTAssertEqual(discover.map(\.id), ["fresh0", "fresh1", "fresh2", "known0"])
        XCTAssertEqual(balanced.map(\.id), ["fresh0", "known0", "fresh1", "known1"])
        XCTAssertEqual(select(known, familiarity: .newMusic, heard: heard), known)
        XCTAssertEqual(select(fresh, familiarity: .familiar, heard: heard), fresh)
    }

    func testAutomaticLanguageSoftlyRanksWithoutExcludingUnknownOrMinorityLanguages() {
        let english = Fixtures.track("english", artist: "English Artist", language: .english)
        let unknown = Fixtures.track("unknown", artist: "Unknown Artist")
        let hindi = Fixtures.track("hindi", artist: "Hindi Artist", language: .hindi)
        let profile = ListeningLanguageProfile(fallback: [.hindi])
        XCTAssertEqual(select([english, unknown, hindi], profile: profile).map(\.id), ["hindi", "unknown", "english"])
    }

    func testExplicitLanguageUsesExistingEvidenceAndCorrectionsAndExcludesUnknowns() {
        let corrected = Fixtures.track("corrected", artist: "One", language: .english)
        let identified = Fixtures.track("identified", artist: "Two")
        let likely = Fixtures.track("likely", artist: "Three")
        let unknown = Fixtures.track("unknown", artist: "Four")
        let profile = ListeningLanguageProfile(evidence: [
            LyricsRequestKey(identified): .identified(.bengali, source: .matchedLyrics),
            LyricsRequestKey(likely): .likely(.bengali, source: .titleScript),
        ], overrides: [corrected.id: ArtistSongLanguage.bengali.rawValue])
        let result = select([corrected, identified, likely, unknown], language: .bengali, profile: profile)
        XCTAssertEqual(result.map(\.id), [corrected.id, identified.id])
        XCTAssertTrue(select([corrected, identified, likely, unknown], language: .tamil, profile: profile).isEmpty)
    }

    func testSelectionBoundsCandidatesAndHonorsZeroAndNegativeLimits() {
        let invalid = (0..<100).map { Fixtures.track("video\($0)", audio: false) }
        XCTAssertTrue(select(invalid + songs("outside-bound", count: 1)).isEmpty)
        XCTAssertEqual(select(songs("song", count: 120), limit: 200).count, 100)
        XCTAssertTrue(select(songs("song", count: 3), limit: 0).isEmpty)
        XCTAssertTrue(select(songs("song", count: 3), limit: -1).isEmpty)
    }

    func testSongAnchorReturnsExactChosenRecordingWithoutCatalogRequests() async throws {
        let catalog = RecommendationCatalogMock()
        let track = Fixtures.arijit1
        let anchors = try await SeedRadioEngine(catalog: catalog).anchors(for: .song(track), disliked: [])
        XCTAssertEqual(anchors, [track])
        let calls = await catalog.callCount
        XCTAssertEqual(calls, 0)
    }

    func testInvalidAndDislikedSongAnchorsFailWithoutCatalogRequests() async {
        let catalog = RecommendationCatalogMock()
        let engine = SeedRadioEngine(catalog: catalog)
        let disliked = DislikedSong(id: Fixtures.arijit1.id, title: Fixtures.arijit1.title, artists: Fixtures.arijit1.artists)
        for track in [Fixtures.track(""), Fixtures.track("video", audio: false), Fixtures.arijit1] {
            do {
                _ = try await engine.anchors(for: .song(track), disliked: [disliked])
                XCTFail("Expected an unusable seed")
            } catch {
                guard case SeedRadioError.invalidSeed = error else { XCTFail("Unexpected error: \(error)"); continue }
            }
        }
        let calls = await catalog.callCount
        XCTAssertEqual(calls, 0)
    }

    func testLinkedArtistAnchorsCheckCreditsDeduplicateRecordingsAndStopAtThree() async throws {
        let catalog = RecommendationCatalogMock()
        let first = Fixtures.track("first", title: "Home", artist: "Alex", artistID: "chosen")
        let alias = Fixtures.track("alias", title: "Home (Remastered)", artist: "Alex", artistID: "chosen")
        let namesake = Fixtures.track("namesake", artist: "Alex", artistID: "wrong-id")
        let unrelated = Fixtures.track("unrelated", artist: "Blair")
        let video = Fixtures.track("video", artist: "Alex", artistID: "chosen", audio: false)
        let second = Fixtures.track("second", artist: "Alex", artistID: "chosen")
        let featured = Fixtures.track("featured", title: "Together (feat. Alex)", artist: "Blair")
        let fourth = Fixtures.track("fourth", artist: "Alex", artistID: "chosen")
        let excluded = Fixtures.track("disliked", artist: "Alex", artistID: "chosen")
        await catalog.setArtist(Fixtures.page("chosen", name: "Alex",
                                             topSongs: [excluded, first, alias, namesake, unrelated, video, second, featured, fourth]))
        let disliked = DislikedSong(id: excluded.id, title: excluded.title, artists: excluded.artists)
        let result = try await SeedRadioEngine(catalog: catalog).anchors(for: .artist(.init(name: "Alex", id: "chosen")), disliked: [disliked])
        XCTAssertEqual(result.map(\.id), [first.id, second.id, featured.id])
        let requests = await catalog.artistRequests
        let calls = await catalog.callCount
        XCTAssertEqual(requests, ["chosen"])
        XCTAssertEqual(calls, 1)
    }

    func testNameOnlyArtistResolvesOneBoundedArtistSearchThenChecksCredits() async throws {
        let catalog = AppModelCatalogProvider()
        let song = Fixtures.track("song", artist: "Alex", artistID: "chosen")
        await catalog.searches.enqueue(.success(CatalogPage(collections: [
            .init(id: "wrong", title: "Alex Tribute", kind: .artist),
            .init(id: "album", title: "Alex", kind: .album),
            .init(id: "chosen", title: "Alex", kind: .artist),
        ], continuation: "must-not-follow")))
        await catalog.artists.enqueue(.success(Fixtures.page("chosen", name: "Alex", topSongs: [song])))
        let result = try await SeedRadioEngine(catalog: catalog).anchors(for: .artist(.init(name: "Alex")), disliked: [])
        XCTAssertEqual(result, [song])
        let searches = await catalog.searches.requests
        let artists = await catalog.artists.requests
        XCTAssertEqual(searches.map(\.input), [AppModelSearchRequest(query: "Alex", filter: .artists, continuation: nil)])
        XCTAssertEqual(artists.map(\.input), ["chosen"])
        await catalog.close()
    }

    func testArtistLookupRejectsWrongPageAndUncreditedPopularSongs() async {
        let catalog = AppModelCatalogProvider()
        let engine = SeedRadioEngine(catalog: catalog)
        await catalog.artists.enqueue(.success(Fixtures.page("wrong-page", name: "Alex", topSongs: [Fixtures.arijit1])))
        do {
            _ = try await engine.anchors(for: .artist(.init(name: "Alex", id: "chosen")), disliked: [])
            XCTFail("Expected wrong-page rejection")
        } catch {
            guard case MusicServiceError.invalidResponse = error else { XCTFail("Unexpected error: \(error)"); return }
        }
        await catalog.artists.enqueue(.success(Fixtures.page("chosen", name: "Alex", topSongs: [Fixtures.arijit1])))
        do {
            _ = try await engine.anchors(for: .artist(.init(name: "Alex", id: "chosen")), disliked: [])
            XCTFail("Popular list alone must not prove credit")
        } catch {
            guard case SeedRadioError.noArtistRecordings = error else { XCTFail("Unexpected error: \(error)"); return }
        }
        await catalog.close()
    }

    func testNameOnlyArtistSearchDoesNotScanPastBoundOrFollowContinuation() async {
        let catalog = AppModelCatalogProvider()
        let unrelated = (0..<100).map { MusicCollection(id: "other\($0)", title: "Other Artist \($0)", kind: .artist) }
        await catalog.searches.enqueue(.success(CatalogPage(
            collections: unrelated + [.init(id: "chosen", title: "Alex", kind: .artist)], continuation: "more")))
        do {
            _ = try await SeedRadioEngine(catalog: catalog).anchors(for: .artist(.init(name: "Alex")), disliked: [])
            XCTFail("Expected bounded name resolution")
        } catch {
            guard case SeedRadioError.noArtistRecordings = error else { XCTFail("Unexpected error: \(error)"); return }
        }
        let searches = await catalog.searches.requests
        let artists = await catalog.artists.requests
        XCTAssertEqual(searches.count, 1)
        XCTAssertTrue(artists.isEmpty)
        await catalog.close()
    }

    func testMultipleRefillsRotateOriginalArtistAnchorsNeverTheQueueFrontier() async throws {
        let catalog = AppModelCatalogProvider()
        let engine = SeedRadioEngine(catalog: catalog)
        let originals = [Fixtures.arijit1, Fixtures.arijit2, Fixtures.arijit3]
        await catalog.artists.enqueue(.success(Fixtures.page("UCarijit", name: "Arijit Singh", topSongs: originals)))
        let anchors = try await engine.anchors(for: .artist(.init(name: "Arijit Singh", id: "UCarijit")), disliked: [])
        var queue: [Track] = []
        for round in 0..<4 {
            let next = Fixtures.track("next\(round)", artist: "New Artist \(round)")
            await catalog.autoplayRadios.enqueue(.success(queue + anchors + [next]))
            let batch = try await refill(engine, anchors: anchors, round: round, excluding: queue)
            XCTAssertEqual(batch, [next])
            queue += batch
        }
        let requests = await catalog.radioRefreshRequests
        let artistRequests = await catalog.artists.requests
        let searches = await catalog.searches.requests
        XCTAssertEqual(requests.map { $0.seed.id }, [originals[0].id, originals[1].id, originals[2].id, originals[0].id])
        XCTAssertTrue(requests.allSatisfy { !$0.forceRefresh })
        XCTAssertEqual(artistRequests.count, 1)
        XCTAssertTrue(searches.isEmpty)
        XCTAssertEqual(anchors, originals)
        await catalog.close()
    }

    func testEmptyFirstAnchorUsesOnlyOneAlternateWhenItHasResults() async throws {
        let catalog = AppModelCatalogProvider()
        let expected = songs("next", count: 2)
        await catalog.autoplayRadios.enqueue(.success([]))
        await catalog.autoplayRadios.enqueue(.success(expected))
        let result = try await refill(SeedRadioEngine(catalog: catalog), anchors: [Fixtures.arijit1, Fixtures.arijit2, Fixtures.arijit3])
        XCTAssertEqual(result, expected)
        let requests = await catalog.radioRefreshRequests
        XCTAssertEqual(requests.map { $0.seed.id }, [Fixtures.arijit1.id, Fixtures.arijit2.id])
        XCTAssertEqual(requests.map(\.forceRefresh), [false, false])
        await catalog.close()
    }

    func testFilteredCachedResultsGetExactlyOneFreshRetryOnTheOriginalSong() async throws {
        let catalog = AppModelCatalogProvider()
        let queued = Fixtures.weeknd1
        let next = Fixtures.pritam1
        await catalog.autoplayRadios.enqueue(.success([queued]))
        await catalog.autoplayRadios.enqueue(.success([next]))
        let result = try await refill(SeedRadioEngine(catalog: catalog), excluding: [queued])
        XCTAssertEqual(result, [next])
        let requests = await catalog.radioRefreshRequests
        XCTAssertEqual(requests.map { $0.seed.id }, [Fixtures.arijit1.id, Fixtures.arijit1.id])
        XCTAssertEqual(requests.map(\.forceRefresh), [false, true])
        await catalog.close()
    }

    func testRefillSpacesArtistsAgainstTheQueueTailRatherThanTheAnchorTail() async throws {
        let catalog = AppModelCatalogProvider()
        let sameArtist = Fixtures.track("weeknd-next", title: "Another Song", artist: "The Weeknd", artistID: "UCweeknd")
        await catalog.autoplayRadios.enqueue(.success([sameArtist, Fixtures.pritam1]))
        let result = try await refill(SeedRadioEngine(catalog: catalog), excluding: [Fixtures.weeknd1])
        XCTAssertEqual(result, [Fixtures.pritam1, sameArtist])
        await catalog.close()
    }

    func testLateDislikedAnchorsAreNotReplacedWithQueueSongs() async throws {
        let catalog = AppModelCatalogProvider()
        let engine = SeedRadioEngine(catalog: catalog)
        let disliked = DislikedSong(id: Fixtures.arijit1.id, title: Fixtures.arijit1.title, artists: Fixtures.arijit1.artists)
        do {
            _ = try await refill(engine, excluding: [Fixtures.weeknd1], disliked: [disliked])
            XCTFail("Expected an exhausted anchor set")
        } catch {
            guard case SeedRadioError.invalidSeed = error else { XCTFail("Unexpected error: \(error)"); return }
        }
        let before = await catalog.radioRefreshRequests
        XCTAssertTrue(before.isEmpty)
        await catalog.autoplayRadios.enqueue(.success([Fixtures.pritam1]))
        let result = try await refill(engine, anchors: [Fixtures.arijit1, Fixtures.arijit2],
                                      excluding: [Fixtures.weeknd1], disliked: [disliked])
        XCTAssertEqual(result, [Fixtures.pritam1])
        let requests = await catalog.radioRefreshRequests
        XCTAssertEqual(requests.map { $0.seed.id }, [Fixtures.arijit2.id])
        await catalog.close()
    }

    func testLanguageScarcityStopsAtThreeRequestsAndNamesTheExplicitLanguage() async {
        let catalog = AppModelCatalogProvider()
        for _ in 0..<3 { await catalog.autoplayRadios.enqueue(.success([Fixtures.weeknd1, Fixtures.track("unknown")])) }
        do {
            _ = try await refill(SeedRadioEngine(catalog: catalog), anchors: [Fixtures.arijit1, Fixtures.arijit2, Fixtures.arijit3],
                                 tuning: RadioTuning(language: .hindi))
            XCTFail("Expected explicit-language scarcity")
        } catch {
            guard case SeedRadioError.exhausted(language: .hindi) = error else { XCTFail("Unexpected error: \(error)"); return }
            XCTAssertTrue(error.localizedDescription.contains("Hindi"))
            XCTAssertTrue(error.localizedDescription.contains("Automatic Language"))
        }
        let requests = await catalog.radioRefreshRequests
        XCTAssertEqual(requests.map { $0.seed.id }, [Fixtures.arijit1.id, Fixtures.arijit2.id, Fixtures.arijit1.id])
        XCTAssertEqual(requests.map(\.forceRefresh), [false, false, true])
        await catalog.close()
    }

    func testAlreadyForcedRefillDoesNotForceAnotherRetry() async {
        for anchors in [[Fixtures.arijit1], [Fixtures.arijit1, Fixtures.arijit2]] {
            let catalog = AppModelCatalogProvider()
            for _ in anchors { await catalog.autoplayRadios.enqueue(.success([])) }
            do {
                _ = try await refill(SeedRadioEngine(catalog: catalog), anchors: anchors, forceRefresh: true)
                XCTFail("Expected scarcity")
            } catch {
                guard case SeedRadioError.exhausted(language: nil) = error else { XCTFail("Unexpected error: \(error)"); continue }
            }
            let requests = await catalog.radioRefreshRequests
            XCTAssertEqual(requests.count, anchors.count)
            XCTAssertEqual(requests.filter(\.forceRefresh).count, 1)
            await catalog.close()
        }
    }

    func testProviderCooldownNetworkAndTimeoutErrorsPropagateWithoutRetry() async {
        let failures: [any Error] = [MusicServiceError.rateLimited, MusicServiceError.network("fixture offline"),
                                    MusicServiceError.invalidResponse, PlaybackStreamError.timedOut, CancellationError()]
        for failure in failures {
            let catalog = AppModelCatalogProvider()
            await catalog.autoplayRadios.enqueue(.failure(failure))
            do {
                _ = try await refill(SeedRadioEngine(catalog: catalog), anchors: [Fixtures.arijit1, Fixtures.arijit2])
                XCTFail("Expected provider failure")
            } catch {
                XCTAssertEqual(String(reflecting: type(of: error)), String(reflecting: type(of: failure)))
                XCTAssertEqual(error.localizedDescription, failure.localizedDescription)
            }
            let requests = await catalog.radioRefreshRequests
            XCTAssertEqual(requests.count, 1)
            await catalog.close()
        }
    }

    func testRefillUsesEachCallsTuningDislikesAndHeardSnapshotWithoutRetainedState() async throws {
        let catalog = AppModelCatalogProvider()
        let engine = SeedRadioEngine(catalog: catalog)
        let candidates = [Fixtures.weeknd1, Fixtures.pritam1]
        for _ in 0..<3 { await catalog.autoplayRadios.enqueue(.success(candidates)) }
        let heard: Set<String> = [Fixtures.weeknd1.id]
        let familiar = try await refill(engine, tuning: RadioTuning(familiarity: .familiar), heard: heard)
        let discover = try await refill(engine, tuning: RadioTuning(familiarity: .newMusic), heard: heard)
        let disliked = DislikedSong(id: Fixtures.weeknd1.id, title: Fixtures.weeknd1.title, artists: Fixtures.weeknd1.artists)
        let tuned = try await refill(engine, disliked: [disliked], tuning: RadioTuning(language: .hindi))
        XCTAssertEqual(familiar.first, Fixtures.weeknd1)
        XCTAssertEqual(discover.first, Fixtures.pritam1)
        XCTAssertEqual(tuned, [Fixtures.pritam1])
        let requests = await catalog.radioRefreshRequests
        XCTAssertEqual(requests.count, 3)
        await catalog.close()
    }

    func testCancelledArtistLookupCannotPublishLateAnchorsOrAffectANewerSeed() async throws {
        let catalog = RecommendationCatalogMock()
        let latch = SeedRadioTestLatch()
        await catalog.setArtist(Fixtures.page("UCarijit", name: "Arijit Singh", topSongs: [Fixtures.arijit1]))
        await catalog.setBeforeArtist { _ in await latch.suspend() }
        let engine = SeedRadioEngine(catalog: catalog)
        let older = Task { try await engine.anchors(for: .artist(.init(name: "Arijit Singh", id: "UCarijit")), disliked: []) }
        await latch.waitUntilSuspended()
        older.cancel()
        let newer = try await engine.anchors(for: .song(Fixtures.weeknd1), disliked: [])
        await latch.release()
        do {
            _ = try await older.value
            XCTFail("A cancelled request must not return its late result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(newer, [Fixtures.weeknd1])
        let repeated = try await engine.anchors(for: .song(Fixtures.weeknd1), disliked: [])
        XCTAssertEqual(repeated, newer)
    }

    private func select(_ tracks: [Track], excluding: [Track] = [], disliked: [DislikedSong] = [],
                        familiarity: DiscoveryFamiliarity = .balanced, heard: Set<String> = [],
                        language: ArtistSongLanguage? = nil, profile: ListeningLanguageProfile = .init(),
                        limit: Int = 8) -> [Track] {
        SeedRadioEngine.select(tracks, excluding: excluding, disliked: disliked,
                               tuning: RadioTuning(familiarity: familiarity, language: language), heardTrackIDs: heard,
                               languageProfile: profile, limit: limit)
    }

    private func refill(_ engine: SeedRadioEngine, anchors: [Track] = [Fixtures.arijit1], round: Int = 0,
                        excluding: [Track] = [], disliked: [DislikedSong] = [], tuning: RadioTuning = .init(),
                        heard: Set<String> = [], forceRefresh: Bool = false) async throws -> [Track] {
        try await engine.refill(anchors: anchors, round: round, excluding: excluding, disliked: disliked,
                                tuning: tuning, heardTrackIDs: heard, languageProfile: .init(), forceRefresh: forceRefresh)
    }

    private func songs(_ prefix: String, count: Int) -> [Track] {
        (0..<count).map { Fixtures.track("\(prefix)\($0)", artist: "\(prefix) Artist \($0)") }
    }
}

private actor SeedRadioTestLatch {
    private var suspended = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            held = continuation
            suspended = true
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
