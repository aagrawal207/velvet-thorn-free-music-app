import XCTest
@testable import GanaBajana

/// Canned MusicBrainz answers keyed by track id; records every call so budgets can be asserted.
final class GenreMetadataMock: GenreMetadataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var recordingAnswers: [String: MusicBrainzGenreLookup] = [:]
    private var artistAnswers: [String: [GenreVote]] = [:]
    private var groupAnswers: [String: [GenreVote]] = [:]
    private var failing: Set<String> = []
    private(set) var recordingLookups: [String] = []
    private(set) var artistLookups: [String] = []
    private(set) var groupLookups: [String] = []
    var delay: Duration = .zero

    func answer(_ trackID: String, with lookup: MusicBrainzGenreLookup) { lock.withLock { recordingAnswers[trackID] = lookup } }
    func answerArtist(_ id: String, with votes: [GenreVote]) { lock.withLock { artistAnswers[id] = votes } }
    func answerReleaseGroup(_ id: String, with votes: [GenreVote]) { lock.withLock { groupAnswers[id] = votes } }
    func fail(_ trackID: String) { lock.withLock { _ = failing.insert(trackID) } }

    func recordingGenres(for track: Track) async throws -> MusicBrainzGenreLookup {
        if delay > .zero { try await Task.sleep(for: delay) }
        let (answer, fails) = lock.withLock {
            recordingLookups.append(track.id)
            return (recordingAnswers[track.id], failing.contains(track.id))
        }
        if fails { throw MusicServiceError.unavailable("Synthetic MusicBrainz failure") }
        return answer ?? MusicBrainzGenreLookup(genres: nil, requests: 1)
    }

    func releaseGroupGenres(id: String) async throws -> [GenreVote] {
        lock.withLock { groupLookups.append(id); return groupAnswers[id] ?? [] }
    }

    func artistGenres(id: String) async throws -> [GenreVote] {
        lock.withLock { artistLookups.append(id); return artistAnswers[id] ?? [] }
    }
}

enum GenreFixtures {
    static let now = RecommendationFixtures.now
    static let recordingID = "3e5bc764-dfa4-454d-a2a9-0ee84ae35db2"
    static let artistID = "a1111111-1111-4111-8111-111111111111"
    static let groupID = "b2222222-2222-4222-8222-222222222222"

    static func track(_ id: String, title: String? = nil, artist: String = "Fixture Artist", language: MusicLanguage? = nil) -> Track {
        RecommendationFixtures.track(id, title: title, artist: artist, language: language)
    }

    static func votes(_ names: [String: Int]) -> [GenreVote] {
        names.map { GenreVote($0.key, count: $0.value) }.sorted { $0.name < $1.name }
    }

    static func distribution(_ shares: [(GenreFamily, Double)], source: GenreEvidenceSource = .recording) -> GenreDistribution {
        GenreDistribution(shares: shares.map { GenreShare(family: $0.0, share: $0.1) }, source: source)
    }

    /// Recording JSON in the shape of `recording/<id>?inc=artist-credits+releases+release-groups+genres+tags`.
    static func recording(id: String = recordingID, genres: [(String, Int)] = [], tags: [(String, Int)] = [],
                          artistGenres: [(String, Int)]? = nil, releaseGroupGenres: [(String, Int)]? = nil,
                          title: String = "Tum Hi Ho", artist: String = "Arijit Singh", length: Int = 262_000) -> CatalogJSON {
        func list(_ items: [(String, Int)]) -> CatalogJSON {
            .array(items.map { ["name": .string($0.0), "count": .number(Double($0.1))] })
        }
        var artistObject: [String: CatalogJSON] = ["id": .string(artistID), "name": .string(artist)]
        if let artistGenres { artistObject["genres"] = list(artistGenres) }
        var group: [String: CatalogJSON] = ["id": .string(groupID), "title": .string("Aashiqui 2")]
        if let releaseGroupGenres { group["genres"] = list(releaseGroupGenres) }
        return ["id": .string(id), "title": .string(title), "length": .number(Double(length)), "video": false, "disambiguation": "",
                "artist-credit": [["name": .string(artist), "artist": .object(artistObject)]],
                "genres": list(genres), "tags": list(tags + genres),
                "releases": [["id": "55555555-5555-4555-8555-555555555555", "title": "Aashiqui 2", "date": "2013-04-03",
                              "status": "Official", "release-group": .object(group)]]]
    }

    static func search(_ records: [CatalogJSON]) -> CatalogJSON {
        ["count": .number(Double(records.count)), "recordings": .array(records)]
    }

    static func entity(id: String, genres: [(String, Int)]) -> CatalogJSON {
        ["id": .string(id), "genres": .array(genres.map { ["name": .string($0.0), "count": .number(Double($0.1))] })]
    }

    /// Earlier tracks and earlier plays are more recent, so recency ordering is deterministic.
    static func events(_ plays: [(Track, Int)], daysAgo: Double = 1) -> [ListeningEvent] {
        plays.enumerated().flatMap { position, entry in
            let (track, count) = entry
            return (0..<count).map { index in
                RecommendationFixtures.event(track, daysAgo: daysAgo + Double(position) * 0.01 + Double(index) * 0.001, seconds: 200)
            }
        }
    }

    static func summary(_ events: [ListeningEvent], evidence: [LyricsRequestKey: GenreDistribution],
                        window: ListeningWindow = .month) -> ListeningGenreSummary {
        ListeningAnalytics.genreSummary(events: events, for: window, now: now, calendar: RecommendationFixtures.calendar,
                                        evidence: evidence)
    }

    static func profile(_ plays: [(Track, GenreDistribution?, Int)], nudges: GenreNudges = GenreNudges(),
                        extraEvidence: [Track: GenreDistribution] = [:]) -> ListeningGenreProfile {
        var evidence: [LyricsRequestKey: GenreDistribution] = [:]
        for (track, distribution, _) in plays { if let distribution { evidence[LyricsRequestKey(track)] = distribution } }
        for (track, distribution) in extraEvidence { evidence[LyricsRequestKey(track)] = distribution }
        let summary = summary(events(plays.map { ($0.0, $0.2) }), evidence: evidence)
        return ListeningGenreProfile(summary: summary, nudges: nudges, evidence: evidence)
    }
}

final class GenreTaxonomyTests: XCTestCase {
    func testSampleTagsMapToFamiliesAndUnknownOrMoodWordsMapToNothing() {
        let samples: [(String, GenreFamily)] = [
            ("filmi", .bollywood), ("bollywood", .bollywood), ("bhangra", .punjabi), ("qawwali", .sufi), ("sufi", .sufi),
            ("ghazal", .ghazal), ("bhajan", .devotional), ("gurbani", .devotional), ("hindustani classical", .hindustani),
            ("carnatic", .carnatic), ("indie pop", .indiePop), ("shoegaze", .indiePop), ("pop", .pop), ("rap", .hipHop),
            ("trap", .hipHop), ("desi hip hop", .hipHop), ("neo soul", .rnb), ("grunge", .rock), ("death metal", .metal),
            ("drum and bass", .electronic), ("disco", .dance), ("chillhop", .lofi), ("bebop", .jazz), ("delta blues", .blues),
            ("orchestral", .classical), ("bluegrass", .folk), ("honky tonk", .country), ("korean pop", .kpop),
            ("reggaeton", .latin), ("dancehall", .reggae), ("film score", .soundtrack), ("singer songwriter", .acoustic),
            ("new age", .ambient), ("afrobeats", .world), ("instrumental", .instrumental),
        ]
        for (tag, family) in samples {
            XCTAssertEqual(GenreTaxonomy.family(forTag: tag), family, tag)
        }
        for unknown in ["romantic", "sad", "party", "90s", "80s", "love", "summer", "workout", "favourite", "seen live", ""] {
            XCTAssertNil(GenreTaxonomy.family(forTag: unknown), unknown)
        }
        XCTAssertGreaterThanOrEqual(GenreTaxonomy.table.count, 200)
        XCTAssertEqual(GenreFamily.allCases.count, 29)
        XCTAssertEqual(Set(GenreFamily.allCases.map(\.title)).count, GenreFamily.allCases.count)
    }

    func testNormalisationMakesPunctuationCaseAndDiacriticVariantsAgree() {
        for variant in ["Hip-Hop", "hip hop", "HipHop", "HIP HOP", "hip_hop", "hip  hop "] {
            XCTAssertEqual(GenreTaxonomy.family(forTag: variant), .hipHop, variant)
        }
        XCTAssertEqual(GenreTaxonomy.normalize("Hip-Hop"), "hip hop")
        XCTAssertEqual(GenreTaxonomy.normalize("R&B"), "r b")
        XCTAssertEqual(GenreTaxonomy.family(forTag: "R&B"), .rnb)
        XCTAssertEqual(GenreTaxonomy.family(forTag: "RnB"), .rnb)
        XCTAssertEqual(GenreTaxonomy.family(forTag: "Lo-Fi"), .lofi)
        XCTAssertEqual(GenreTaxonomy.family(forTag: "lofi"), .lofi)
        XCTAssertEqual(GenreTaxonomy.family(forTag: "Reggaetón"), .latin)
        XCTAssertEqual(GenreTaxonomy.family(forTag: "drum 'n' bass"), .electronic)
        XCTAssertEqual(GenreTaxonomy.family(forTag: "K-Pop"), .kpop)
    }

    func testVotesAreNormalisedPerSourceAndKeepTheTopThreeFamilies() throws {
        let votes = GenreFixtures.votes(["filmi": 6, "bollywood": 2, "pop": 4, "romantic": 9, "sufi": 2, "ghazal": 1])
        let distribution = try XCTUnwrap(GenreTaxonomy.distribution(votes: votes, source: .recording))
        XCTAssertEqual(distribution.source, .recording)
        XCTAssertEqual(distribution.families, [.bollywood, .pop, .sufi], "Ghazal drops out of the top three; the mood word never counted")
        XCTAssertEqual(distribution.share(of: .bollywood), 8.0 / 14, accuracy: 1e-12)
        XCTAssertEqual(distribution.share(of: .pop), 4.0 / 14, accuracy: 1e-12)
        XCTAssertEqual(distribution.share(of: .sufi), 2.0 / 14, accuracy: 1e-12)
        XCTAssertEqual(distribution.shares.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-12)
        XCTAssertNil(GenreTaxonomy.distribution(votes: GenreFixtures.votes(["romantic": 3, "seen live": 1]), source: .recording))
        let zeroCount = try XCTUnwrap(GenreTaxonomy.distribution(votes: [GenreVote("jazz", count: 0), GenreVote("blues", count: 0)], source: .artist))
        XCTAssertEqual(zeroCount.share(of: .jazz), 0.5, accuracy: 1e-12, "A vote without a count still counts once")
    }
}

final class GenreEvidenceTests: XCTestCase {
    func testRecordingGenresWinOverEmbeddedReleaseGroupAndArtistVotes() throws {
        let json = GenreFixtures.recording(genres: [("filmi", 5), ("pop", 1)], artistGenres: [("playback singer", 3), ("bollywood", 2)],
                                           releaseGroupGenres: [("soundtrack", 4)])
        let parsed = ArtistSpotlightMusicBrainz.recordingGenres(in: json, recordingID: GenreFixtures.recordingID)
        XCTAssertEqual(parsed.recording, [GenreVote("filmi", count: 5), GenreVote("pop", count: 1)])
        XCTAssertEqual(parsed.artistIDs, [GenreFixtures.artistID])
        XCTAssertEqual(parsed.artists[GenreFixtures.artistID], [GenreVote("playback singer", count: 3), GenreVote("bollywood", count: 2)])
        XCTAssertEqual(parsed.releaseGroupID, GenreFixtures.groupID)
        XCTAssertEqual(parsed.releaseGroup, [GenreVote("soundtrack", count: 4)])

        guard case .settled(let outcome) = GenreClassifier.plan(MusicBrainzGenreLookup(genres: parsed, requests: 2), cachedArtist: { _ in nil }) else {
            return XCTFail("Recording votes settle the classification without a follow-up")
        }
        XCTAssertEqual(outcome.distribution.source, .recording)
        XCTAssertEqual(outcome.distribution.families, [.bollywood, .pop])
        XCTAssertEqual(outcome.distribution.share(of: .bollywood), 5.0 / 6, accuracy: 1e-12)
        XCTAssertEqual(outcome.artists[GenreFixtures.artistID]?.families, [.bollywood], "Embedded artist votes are cached for free")
        XCTAssertEqual(outcome.requests, 2)
    }

    func testEmbeddedReleaseGroupGenresFillInWhenTheRecordingHasNone() throws {
        let json = GenreFixtures.recording(tags: [("romantic", 3)], releaseGroupGenres: [("soundtrack", 2), ("filmi", 6)])
        let parsed = ArtistSpotlightMusicBrainz.recordingGenres(in: json, recordingID: GenreFixtures.recordingID)
        guard case .settled(let outcome) = GenreClassifier.plan(MusicBrainzGenreLookup(genres: parsed, requests: 2), cachedArtist: { _ in nil }) else {
            return XCTFail("Embedded release-group votes settle the classification")
        }
        XCTAssertEqual(outcome.distribution.source, .releaseGroup)
        XCTAssertEqual(outcome.distribution.families, [.bollywood, .soundtrack])
        XCTAssertEqual(outcome.distribution.share(of: .bollywood), 0.75, accuracy: 1e-12)
    }

    func testArtistFallbackUsesTheCacheFirstAndSpendsTheThirdRequestOnAnUnknownArtist() throws {
        let json = GenreFixtures.recording(tags: [("favourite", 2)], releaseGroupGenres: [])
        let parsed = ArtistSpotlightMusicBrainz.recordingGenres(in: json, recordingID: GenreFixtures.recordingID)
        let cached = GenreFixtures.distribution([(.hipHop, 1)], source: .artist)
        guard case .settled(let fromCache) = GenreClassifier.plan(MusicBrainzGenreLookup(genres: parsed, requests: 2),
                                                                cachedArtist: { $0 == GenreFixtures.artistID ? cached : nil }) else {
            return XCTFail("A cached artist answers without another request")
        }
        XCTAssertEqual(fromCache.distribution, cached)
        XCTAssertEqual(fromCache.requests, 2)

        guard case .followUp(let followUp, let partial) = GenreClassifier.plan(MusicBrainzGenreLookup(genres: parsed, requests: 2),
                                                                             cachedArtist: { _ in nil }) else {
            return XCTFail("An unknown artist earns the one follow-up request")
        }
        XCTAssertEqual(followUp, .artist(GenreFixtures.artistID))
        let finished = GenreClassifier.finish(followUp, votes: GenreFixtures.votes(["punjabi": 4, "bhangra": 2, "romantic": 9]), partial: partial)
        XCTAssertEqual(finished.requests, 3)
        XCTAssertEqual(finished.distribution.source, .artist)
        XCTAssertEqual(finished.distribution.families, [.punjabi])
        XCTAssertEqual(finished.artists[GenreFixtures.artistID]?.families, [.punjabi])

        let bare = GenreClassifier.finish(followUp, votes: [], partial: partial)
        XCTAssertEqual(bare.distribution, .unclassified)
        XCTAssertEqual(bare.artists[GenreFixtures.artistID], .unclassified, "A bare artist is remembered so the next song does not ask again")
    }

    func testKnownArtistWithoutGenresSendsTheFollowUpToTheReleaseGroupAndNothingEndsUnclassified() throws {
        let json = GenreFixtures.recording(tags: [("favourite", 1)])
        let parsed = ArtistSpotlightMusicBrainz.recordingGenres(in: json, recordingID: GenreFixtures.recordingID)
        XCTAssertNil(parsed.releaseGroup, "Without embedded lists the release group is still only an id")
        guard case .followUp(let followUp, let partial) = GenreClassifier.plan(MusicBrainzGenreLookup(genres: parsed, requests: 2),
                                                                             cachedArtist: { _ in .unclassified }) else {
            return XCTFail("A known bare artist leaves the follow-up for the release group")
        }
        XCTAssertEqual(followUp, .releaseGroup(GenreFixtures.groupID))
        XCTAssertEqual(GenreClassifier.finish(followUp, votes: GenreFixtures.votes(["jazz": 3]), partial: partial).distribution.families, [.jazz])
        let nothing = GenreClassifier.finish(followUp, votes: [], partial: partial)
        XCTAssertEqual(nothing.distribution, .unclassified)
        XCTAssertEqual(nothing.requests, 3)

        let exhausted = GenreClassifier.plan(MusicBrainzGenreLookup(genres: parsed, requests: 3), cachedArtist: { _ in nil })
        XCTAssertEqual(exhausted, .settled(GenreClassifier.Outcome(distribution: .unclassified, artists: [:], requests: 3)),
                       "The budget of three requests is never exceeded")
        XCTAssertEqual(GenreClassifier.plan(MusicBrainzGenreLookup(genres: nil, requests: 1), cachedArtist: { _ in nil }),
                       .settled(GenreClassifier.Outcome(distribution: .unclassified, artists: [:], requests: 1)))
    }

    func testLiveShapedLookupStaysWithinThreeRateLimitedRequestsAndReusesADetailsMatch() async throws {
        let clock = CatalogTestClock()
        let limiter = MusicBrainzRateLimiter(now: { clock.now }, sleep: { clock.advance($0) })
        let track = SongDetailsFixtures.track
        let recording = try GenreFixtures.recording(tags: [("favourite", 1)]).encoded()
        let search = try GenreFixtures.search([GenreFixtures.recording()]).encoded()
        let artist = try GenreFixtures.entity(id: GenreFixtures.artistID, genres: [("filmi", 7), ("playback", 1)]).encoded()
        let paths = CatalogTestRecorder<String>()
        let mock = CatalogMockSession { request in
            let url = try XCTUnwrap(request.url)
            paths.record(url.path)
            let inc = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "inc" }?.value
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Breezy/1.0 (https://example.org/support)")
            if url.path.hasSuffix(GenreFixtures.recordingID) {
                XCTAssertTrue([ArtistSpotlightMusicBrainz.recordingGenresInc, ArtistSpotlightMusicBrainz.recordingDetailsInc].contains(inc ?? ""))
                return CatalogStub(data: recording)
            }
            if url.path.hasSuffix(GenreFixtures.artistID) {
                XCTAssertEqual(inc, "genres+tags")
                return CatalogStub(data: artist)
            }
            return CatalogStub(data: search)
        }
        defer { mock.close() }
        let service = ArtistSpotlightMusicBrainz(contactURL: try XCTUnwrap(URL(string: "https://example.org/support")),
                                                session: mock.session, limiter: limiter, now: { clock.now })
        let lookup = try await service.recordingGenres(for: track)
        XCTAssertEqual(lookup.requests, 2)
        XCTAssertEqual(lookup.genres?.recordingID, GenreFixtures.recordingID)
        XCTAssertEqual(lookup.genres?.artistIDs, [GenreFixtures.artistID])
        let plan = GenreClassifier.plan(lookup, cachedArtist: { _ in nil })
        guard case .followUp(.artist(let id), let partial) = plan else { return XCTFail("The bare recording asks its artist") }
        let votes = try await service.artistGenres(id: id)
        let outcome = GenreClassifier.finish(.artist(id), votes: votes, partial: partial)
        XCTAssertEqual(outcome.requests, 3)
        XCTAssertEqual(outcome.distribution.families, [.bollywood])
        XCTAssertEqual(paths.values.count, 3)
        XCTAssertEqual(mock.state.requests.count, 3, "Search, recording, artist: never a fourth request")

        // A Song details fetch that already matched this recording answers the genre lookup for free.
        let details = try await service.recordingDetails(for: track)
        XCTAssertNotNil(details?.genres, "The details lookup now carries the genre votes")
        let requestsBefore = mock.state.requests.count
        let reused = try await service.recordingGenres(for: track)
        XCTAssertEqual(reused.requests, 0)
        XCTAssertEqual(reused.genres?.recordingID, GenreFixtures.recordingID)
        XCTAssertEqual(mock.state.requests.count, requestsBefore)
        XCTAssertTrue(ArtistSpotlightMusicBrainz.recordingDetailsInc.contains("genres+tags"))
        XCTAssertTrue(ArtistSpotlightMusicBrainz.recordingDetailsInc.contains("release-groups"))
    }

    @MainActor
    func testStoreKeepsFiveThousandRecordingsAndTwoThousandArtistsByLastUse() async throws {
        let clock = RecommendationTestClock()
        let store = GenreEvidenceStore(url: nil, now: { clock.now }, maximumRecordings: 4, maximumArtists: 2)
        let tracks = (0..<6).map { GenreFixtures.track("lru-\($0)") }
        for (index, track) in tracks.prefix(4).enumerated() {
            clock.advance(by: 1)
            store.record(GenreFixtures.distribution([(.pop, 1)]), for: LyricsRequestKey(track))
            XCTAssertNotNil(store.distribution(for: track), "recording \(index)")
        }
        clock.advance(by: 1)
        // Touching the oldest entry makes it the newest; the second entry becomes the eviction victim.
        store.touch([LyricsRequestKey(tracks[0])])
        clock.advance(by: 1)
        store.record(GenreFixtures.distribution([(.rock, 1)]), for: LyricsRequestKey(tracks[4]))
        XCTAssertEqual(store.recordingCount, 4)
        XCTAssertNotNil(store.distribution(for: tracks[0]))
        XCTAssertNil(store.distribution(for: tracks[1]))
        XCTAssertNotNil(store.distribution(for: tracks[4]))
        XCTAssertEqual(GenreEvidenceStore.maximumRecordings, 5_000)
        XCTAssertEqual(GenreEvidenceStore.maximumArtists, 2_000)

        for id in ["a", "b", "c"] {
            clock.advance(by: 1)
            store.recordArtist(GenreFixtures.distribution([(.jazz, 1)], source: .artist), id: id)
        }
        XCTAssertEqual(store.artistCount, 2)
        XCTAssertNil(store.artistDistribution(id: "a"))
        XCTAssertNotNil(store.artistDistribution(id: "c"))
        clock.advance(by: GenreEvidenceStore.artistLifetime + 1)
        XCTAssertNil(store.artistDistribution(id: "c"), "Artist evidence is reused for 30 days")
    }

    @MainActor
    func testNegativeResultsExpireAfterThirtyDaysWhilePositiveOnesStayUntilEvicted() {
        let clock = RecommendationTestClock()
        let store = GenreEvidenceStore(url: nil, now: { clock.now })
        let classified = GenreFixtures.track("classified")
        let bare = GenreFixtures.track("bare")
        store.record(GenreFixtures.distribution([(.metal, 1)]), for: LyricsRequestKey(classified))
        store.record(.unclassified, for: LyricsRequestKey(bare))
        XCTAssertFalse(store.needsClassification(LyricsRequestKey(classified)))
        XCTAssertFalse(store.needsClassification(LyricsRequestKey(bare)), "A recent miss is not asked again")
        XCTAssertEqual(store.distribution(for: bare), .unclassified)
        clock.advance(by: GenreEvidenceStore.negativeLifetime + 1)
        XCTAssertTrue(store.needsClassification(LyricsRequestKey(bare)))
        XCTAssertFalse(store.needsClassification(LyricsRequestKey(classified)))
        XCTAssertTrue(store.needsClassification(LyricsRequestKey(GenreFixtures.track("never"))))
    }

    @MainActor
    func testStorePersistsAVersionedFileDecodesLenientlyAndResetDeletesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajana-Genres-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(GenreEvidenceStore.fileName)
        let track = GenreFixtures.track("persisted")
        let clock = RecommendationTestClock()
        let store = GenreEvidenceStore(url: url, now: { clock.now })
        await store.load()
        store.record(GenreFixtures.distribution([(.sufi, 0.6), (.ghazal, 0.4)]), for: LyricsRequestKey(track))
        store.recordArtist(GenreFixtures.distribution([(.sufi, 1)], source: .artist), id: GenreFixtures.artistID)
        await store.flush()
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, GenreEvidenceSnapshot.formatVersion)
        XCTAssertEqual(object["taxonomyVersion"] as? Int, GenreTaxonomy.version)
        XCTAssertEqual((object["recordings"] as? [Any])?.count, 1)
        XCTAssertEqual((object["artists"] as? [Any])?.count, 1)

        let reloaded = GenreEvidenceStore(url: url, now: { clock.now })
        await reloaded.load()
        XCTAssertEqual(reloaded.distribution(for: track), GenreFixtures.distribution([(.sufi, 0.6), (.ghazal, 0.4)]))
        XCTAssertEqual(reloaded.artistDistribution(id: GenreFixtures.artistID)?.families, [.sufi])

        // Unknown families and a malformed record are dropped; the rest of the file survives.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var recordings = try XCTUnwrap(json["recordings"] as? [[String: Any]])
        var record = recordings[0]
        record["distribution"] = ["source": "recording", "shares": [["family": "sufi", "share": 0.5], ["family": "future-family", "share": 0.5]]]
        recordings[0] = record
        recordings.append(["key": "not-a-key"])
        json["recordings"] = recordings
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let lenient = GenreEvidenceStore(url: url, now: { clock.now })
        await lenient.load()
        XCTAssertEqual(lenient.recordingCount, 1)
        XCTAssertEqual(lenient.distribution(for: track), GenreFixtures.distribution([(.sufi, 1)]))

        var newer = json
        newer["taxonomyVersion"] = GenreTaxonomy.version + 1
        try JSONSerialization.data(withJSONObject: newer).write(to: url)
        let rebuilt = GenreEvidenceStore(url: url, now: { clock.now })
        await rebuilt.load()
        XCTAssertEqual(rebuilt.recordingCount, 0, "A different taxonomy version starts over and reclassifies lazily")

        lenient.reset()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(lenient.distribution(for: track))
    }
}

final class ListeningGenreProfileTests: XCTestCase {
    private typealias Fixtures = GenreFixtures

    func testSummarySpreadsPlaysOverFamiliesAndReportsHonestCoverage() throws {
        let bollywood = Fixtures.track("bollywood")
        let mixed = Fixtures.track("mixed")
        let unknown = Fixtures.track("unknown")
        let bare = Fixtures.track("bare")
        let evidence: [LyricsRequestKey: GenreDistribution] = [
            LyricsRequestKey(bollywood): Fixtures.distribution([(.bollywood, 1)]),
            LyricsRequestKey(mixed): Fixtures.distribution([(.hipHop, 0.5), (.pop, 0.5)]),
            LyricsRequestKey(bare): .unclassified,
        ]
        let events = Fixtures.events([(bollywood, 6), (mixed, 2), (unknown, 1), (bare, 1)])
        let summary = Fixtures.summary(events, evidence: evidence)
        XCTAssertEqual(summary.totalPlays, 10)
        XCTAssertEqual(summary.totalSongs, 4)
        XCTAssertEqual(summary.classifiedPlays, 8)
        XCTAssertEqual(summary.classifiedSongs, 2)
        XCTAssertEqual(summary.unclassifiedPlays, 2)
        XCTAssertEqual(summary.coverage, 0.8, accuracy: 1e-12)
        XCTAssertEqual(summary.rows.map(\.family), [.bollywood, .pop, .hipHop], "Ties follow the taxonomy order")
        XCTAssertEqual(try XCTUnwrap(summary.rows.first).plays, 6, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(summary.rows.first).share, 0.75, accuracy: 1e-12)
        XCTAssertEqual(summary.rows[1].plays, 1, accuracy: 1e-12)
        XCTAssertEqual(summary.rows[1].share, 0.125, accuracy: 1e-12)
        XCTAssertEqual(summary.rows[1].songs, 1)
        XCTAssertEqual(summary.rows.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-12, "Shares divide the classified plays")
        XCTAssertEqual(summary.totalPlays, ListeningAnalytics.summary(events: events, for: .month, now: Fixtures.now,
                                                                       calendar: RecommendationFixtures.calendar).plays)
    }

    func testProfileUsesTheThirtyDayWindowWithTheRecapQualification() {
        let old = Fixtures.track("old")
        let recent = Fixtures.track("recent")
        let short = Fixtures.track("short")
        let evidence: [LyricsRequestKey: GenreDistribution] = [
            LyricsRequestKey(old): Fixtures.distribution([(.jazz, 1)]),
            LyricsRequestKey(recent): Fixtures.distribution([(.rock, 1)]),
            LyricsRequestKey(short): Fixtures.distribution([(.metal, 1)]),
        ]
        let events = [RecommendationFixtures.event(old, daysAgo: 31, seconds: 200),
                      RecommendationFixtures.event(recent, daysAgo: 29, seconds: 30),
                      RecommendationFixtures.event(short, daysAgo: 1, seconds: 29.9)]
        let summary = Fixtures.summary(events, evidence: evidence)
        XCTAssertEqual(summary.rows.map(\.family), [.rock], "31 days ago and a 29.9 second session do not count")
        let profile = ListeningGenreProfile(summary: summary, evidence: evidence)
        XCTAssertTrue(profile.isLearned)
        XCTAssertEqual(profile.weights[.rock] ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(profile.dominantFamily(for: old), .jazz, "Evidence for an old play is still evidence about the song")
        XCTAssertEqual(profile.affinity(for: old), 0, "but an unheard family has no weight")
        XCTAssertEqual(Fixtures.summary(events, evidence: evidence, window: .year).rows.map(\.family), [.rock, .jazz])
        XCTAssertEqual(ListeningGenreProfile().isLearned, false)
        XCTAssertEqual(ListeningGenreProfile().multiplier(for: recent), 1)
    }

    func testMoreDoublesAndLessQuartersWeightsWhileStatisticsStayUntouched() {
        let hipHop = Fixtures.track("hiphop")
        let pop = Fixtures.track("pop")
        let plays: [(Track, GenreDistribution?, Int)] = [
            (hipHop, Fixtures.distribution([(.hipHop, 1)]), 6),
            (pop, Fixtures.distribution([(.pop, 1)]), 2),
        ]
        let automatic = Fixtures.profile(plays)
        XCTAssertEqual(automatic.weights[.hipHop] ?? 0, 0.9 * 0.75 + 0.05, accuracy: 1e-12)
        XCTAssertEqual(automatic.weights[.pop] ?? 0, 0.9 * 0.25 + 0.05, accuracy: 1e-12)
        XCTAssertEqual(automatic.orderedFamilies, [.hipHop, .pop])
        XCTAssertEqual(automatic.topFamily, .hipHop)

        var nudges = GenreNudges()
        nudges[.pop] = .more
        nudges[.hipHop] = .less
        nudges[.jazz] = .more
        let nudged = Fixtures.profile(plays, nudges: nudges)
        let popBase = 0.9 * 0.25 + 0.05
        let hipHopBase = 0.9 * 0.75 + 0.05
        let total = 2 * popBase + 0.25 * hipHopBase + 0.2
        XCTAssertEqual(nudged.weights[.pop] ?? 0, 2 * popBase / total, accuracy: 1e-12)
        XCTAssertEqual(nudged.weights[.hipHop] ?? 0, 0.25 * hipHopBase / total, accuracy: 1e-12)
        XCTAssertEqual(nudged.weights[.jazz] ?? 0, 0.2 / total, accuracy: 1e-12, "More activates an unheard family at 0.2")
        XCTAssertEqual(nudged.orderedFamilies, [.pop, .jazz, .hipHop])
        XCTAssertEqual(nudged.summary, automatic.summary, "Nudges never change the statistics")
        XCTAssertEqual(nudged.summary.rows.map(\.family), [.hipHop, .pop])
        XCTAssertNotEqual(nudged.requestKey, automatic.requestKey)
        var less = GenreNudges()
        less[.metal] = .less
        XCTAssertNil(Fixtures.profile(plays, nudges: less).weights[.metal], "Less cannot activate an unheard family")
        XCTAssertTrue(GenreNudges().isAutomatic)
        XCTAssertEqual(nudges.adjusted.map(\.family), [.pop, .hipHop, .jazz])
    }

    func testNudgesEncodeEveryFamilyAsItsOwnSyncRegisterAndDecodeLeniently() throws {
        let defaults = try LibrarySyncPreferences.fields(UserPreferences())
        let paths = GenreFamily.allCases.map { "genreNudges/\($0.rawValue)" }
        for path in paths { XCTAssertEqual(defaults[path], Data("\"automatic\"".utf8), path) }
        var preferences = UserPreferences()
        preferences.genreNudges[.hipHop] = .more
        preferences.genreNudges[.pop] = .less
        let fields = try LibrarySyncPreferences.fields(preferences)
        XCTAssertEqual(fields["genreNudges/hipHop"], Data("\"more\"".utf8))
        XCTAssertEqual(fields.filter { defaults[$0.key] != $0.value }.keys.sorted(), ["genreNudges/hipHop", "genreNudges/pop"])
        XCTAssertEqual(try LibrarySyncPreferences.applying(fields, to: UserPreferences()), preferences)
        XCTAssertThrowsError(try LibrarySyncPreferences.applying(["genreNudges/hipHop": Data("\"boost\"".utf8)], to: UserPreferences()),
                             "A value the lenient decoder would rewrite is refused by sync")
        XCTAssertThrowsError(try LibrarySyncPreferences.applying(["genreNudges/futureFamily": Data("\"more\"".utf8)], to: UserPreferences()))

        let partial = try LibrarySyncCodec.decode(UserPreferences.self, from: Data(#"{"genreNudges":{"sufi":"more","ghazal":"boost","unknown":"less"}}"#.utf8))
        XCTAssertEqual(partial.genreNudges[.sufi], .more)
        XCTAssertEqual(partial.genreNudges[.ghazal], .automatic)
        for json in [#"{"genreNudges":null}"#, #"{"genreNudges":true}"#, #"{"languages":["english"]}"#] {
            XCTAssertTrue(try LibrarySyncCodec.decode(UserPreferences.self, from: Data(json.utf8)).genreNudges.isAutomatic, json)
        }
    }

    func testRapHeavyProfileLiftsHipHopAboveAnEqualPopCandidateWithoutBeatingLanguageOrDislikes() throws {
        let rap = Fixtures.track("rap-history")
        let profile = Fixtures.profile([(rap, Fixtures.distribution([(.hipHop, 1)]), 8), (Fixtures.track("pop-history"), Fixtures.distribution([(.pop, 1)]), 2)])
        let hipHop = Fixtures.track("cand-hiphop", language: .english)
        let pop = Fixtures.track("cand-pop", language: .english)
        let unknown = Fixtures.track("cand-unknown", language: .english)
        var evidence: [LyricsRequestKey: GenreDistribution] = [:]
        evidence[LyricsRequestKey(hipHop)] = Fixtures.distribution([(.hipHop, 0.7), (.rnb, 0.3)])
        evidence[LyricsRequestKey(pop)] = Fixtures.distribution([(.pop, 1)])
        let ranked = ListeningGenreProfile(summary: profile.summary, nudges: profile.nudges, evidence: evidence)
        XCTAssertEqual(ranked.multiplier(for: hipHop), 1.15, accuracy: 1e-12)
        XCTAssertEqual(ranked.multiplier(for: unknown), 1, "No evidence is neutral, never a penalty")
        let popMultiplier = ranked.multiplier(for: pop)
        XCTAssertGreaterThan(popMultiplier, 1)
        XCTAssertLessThan(popMultiplier, 1.15)

        typealias Candidate = RecommendationEngine.Candidate
        let equal = [Candidate(track: pop, score: 1, order: 0), Candidate(track: hipHop, score: 1, order: 1), Candidate(track: unknown, score: 1, order: 2)]
        XCTAssertEqual(equal.sorted(by: Candidate.ranks).map(\.track.id), ["cand-pop", "cand-hiphop", "cand-unknown"])
        let boosted = RecommendationEngine.applyingGenres(equal, profile: ranked, mix: false).sorted(by: Candidate.ranks)
        XCTAssertEqual(boosted.map(\.track.id), ["cand-hiphop", "cand-pop", "cand-unknown"])

        // Language preference: a dominant-language pop song stays above a minority-language hip hop song.
        let hindiPop = Fixtures.track("cand-hindi-pop", language: .hindi)
        let englishRap = Fixtures.track("cand-english-rap", language: .english)
        evidence[LyricsRequestKey(hindiPop)] = Fixtures.distribution([(.pop, 1)])
        evidence[LyricsRequestKey(englishRap)] = Fixtures.distribution([(.hipHop, 1)])
        let genres = ListeningGenreProfile(summary: profile.summary, evidence: evidence)
        let languages = ListeningLanguageProfile(summary: ListeningLanguageSummary(rows: [
            LanguageListeningStat(language: .hindi, plays: 9, songs: 3, share: 0.9),
            LanguageListeningStat(language: .english, plays: 1, songs: 1, share: 0.1),
        ], totalPlays: 10, totalSongs: 4))
        let byLanguage = [Candidate(track: englishRap, score: 1, order: 0), Candidate(track: hindiPop, score: 1, order: 1)]
            .map { $0.weighted(by: languages) }
        let weighted = RecommendationEngine.applyingGenres(byLanguage, profile: genres, mix: false).sorted(by: Candidate.ranks)
        XCTAssertEqual(weighted.map(\.track.id), ["cand-hindi-pop", "cand-english-rap"])

        var less = GenreNudges()
        less[.pop] = .less
        let lowered = ListeningGenreProfile(summary: profile.summary, nudges: less, evidence: evidence)
        XCTAssertEqual(lowered.multiplier(for: pop), 0.85, accuracy: 1e-12)
        XCTAssertEqual(lowered.multiplier(for: unknown), 1)
    }

    @MainActor
    func testBecauseYouListenRanksHipHopFirstOnlyWithAGenreProfileAndNeverShowsDislikes() async throws {
        let taste = RecommendationFixtures.profile()
        let pop = Fixtures.track("shelf-pop", artist: "Arijit Singh", language: .hindi)
        let hipHop = Fixtures.track("shelf-hiphop", artist: "Arijit Singh", language: .hindi)
        let disliked = Fixtures.track("shelf-disliked", artist: "Arijit Singh", language: .hindi)
        let catalog = RecommendationCatalogMock()
        await catalog.setArtist(RecommendationFixtures.page("UCarijit", name: "Arijit Singh", topSongs: [pop, hipHop, disliked]))
        await catalog.setArtist(RecommendationFixtures.page("UCweeknd", name: "The Weeknd", topSongs: [RecommendationFixtures.weeknd1]))
        let engine = RecommendationEngine(catalog: catalog, now: { RecommendationFixtures.now })
        let plain = try await engine.becauseYouListen(profile: taste, languages: [])
        XCTAssertEqual(plain.first?.tracks.prefix(2).map(\.id), ["shelf-pop", "shelf-hiphop"])

        let evidence: [LyricsRequestKey: GenreDistribution] = [
            LyricsRequestKey(hipHop): Fixtures.distribution([(.hipHop, 1)]),
            LyricsRequestKey(pop): Fixtures.distribution([(.pop, 1)]),
            LyricsRequestKey(disliked): Fixtures.distribution([(.hipHop, 1)]),
        ]
        let history = Fixtures.track("rap-history")
        let rapHeavy = Fixtures.profile([(history, Fixtures.distribution([(.hipHop, 1)]), 8)], extraEvidence: [
            hipHop: evidence[LyricsRequestKey(hipHop)]!, pop: evidence[LyricsRequestKey(pop)]!, disliked: evidence[LyricsRequestKey(disliked)]!,
        ])
        let dislikes = TasteProfile.build(events: RecommendationFixtures.events(), favorites: [], playlists: [], recents: [],
                                          disliked: [DislikedSong(id: disliked.id, title: disliked.title, artists: disliked.artists)],
                                          now: RecommendationFixtures.now)
        let ranked = try await engine.becauseYouListen(profile: dislikes, languages: [], genreProfile: rapHeavy)
        let shelf = try XCTUnwrap(ranked.first)
        XCTAssertEqual(shelf.tracks.prefix(2).map(\.id), ["shelf-hiphop", "shelf-pop"])
        XCTAssertFalse(shelf.tracks.contains { $0.id == disliked.id }, "A disliked hip hop song never returns through a genre boost")
    }

    func testMixBoostWaitsForFortyPercentCoverageAndThenLiftsOnlyTopThreeFamilies() {
        let hipHop = Fixtures.track("mix-hiphop")
        let folk = Fixtures.track("mix-folk")
        let classified: [(Track, GenreDistribution?, Int)] = [
            (Fixtures.track("h1"), Fixtures.distribution([(.hipHop, 1)]), 4), (Fixtures.track("h2"), Fixtures.distribution([(.pop, 1)]), 2),
            (Fixtures.track("h3"), Fixtures.distribution([(.rock, 1)]), 1), (Fixtures.track("h4"), Fixtures.distribution([(.folk, 1)]), 1),
        ]
        let extra: [Track: GenreDistribution] = [hipHop: Fixtures.distribution([(.hipHop, 1)]), folk: Fixtures.distribution([(.folk, 1)])]
        // 8 classified of 21 plays is 38%: below the gate, mixes stay neutral while Home shelves already use the term.
        let sparse = Fixtures.profile(classified + [(Fixtures.track("u1"), nil, 13)], extraEvidence: extra)
        XCTAssertEqual(sparse.coverage, 8.0 / 21, accuracy: 1e-12)
        XCTAssertFalse(sparse.qualifiesForMixBoost)
        XCTAssertEqual(sparse.mixMultiplier(for: hipHop), 1)
        XCTAssertEqual(sparse.multiplier(for: hipHop), 1.15, accuracy: 1e-12)
        typealias Candidate = RecommendationEngine.Candidate
        let candidates = [Candidate(track: hipHop, score: 1, order: 0), Candidate(track: folk, score: 1, order: 1)]
        XCTAssertEqual(RecommendationEngine.applyingGenres(candidates, profile: sparse, mix: true).map(\.score), [1, 1])

        // 8 of 20 is exactly 40%: hip hop, pop and rock are the top three; folk is fourth and stays neutral.
        let covered = Fixtures.profile(classified + [(Fixtures.track("u1"), nil, 12)], extraEvidence: extra)
        XCTAssertEqual(covered.coverage, 0.4, accuracy: 1e-12)
        XCTAssertTrue(covered.qualifiesForMixBoost)
        XCTAssertEqual(covered.topFamilies, [.hipHop, .pop, .rock])
        XCTAssertEqual(covered.mixMultiplier(for: hipHop), 1.15, accuracy: 1e-12)
        XCTAssertEqual(covered.mixMultiplier(for: folk), 1)
        XCTAssertGreaterThan(covered.multiplier(for: folk), 1, "Home shelves still give a small lift to a heard minority family")
        let boosted = RecommendationEngine.applyingGenres(candidates, profile: covered, mix: true)
        XCTAssertEqual(boosted.map(\.score)[0], 1.15, accuracy: 1e-12)
        XCTAssertEqual(boosted.map(\.score)[1], 1)
        var less = GenreNudges()
        less[.folk] = .less
        let lowered = ListeningGenreProfile(summary: covered.summary, nudges: less, evidence: [LyricsRequestKey(folk): extra[folk]!])
        XCTAssertEqual(lowered.mixMultiplier(for: folk), 0.85, accuracy: 1e-12, "Less applies in mixes once the gate passes")
        XCTAssertEqual(ListeningGenreProfile.mixCoverageGate, 0.4)
        XCTAssertEqual(ListeningGenreProfile.rankingWeight, 0.15)
    }

    func testRadioStationsWithAffinityMoveToTheFrontOfTheirGroupAndTheRestKeepTheirOrder() {
        let stations = RadioExperience.discoveryStations
        XCTAssertEqual(ExperienceRadioEngine.orderedStations(stations, genreProfile: nil).map(\.id), stations.map(\.id))
        XCTAssertEqual(ExperienceRadioEngine.orderedStations(stations, genreProfile: ListeningGenreProfile()).map(\.id), stations.map(\.id),
                       "An unlearned profile keeps the curated order")
        let profile = Fixtures.profile([
            (Fixtures.track("s1"), Fixtures.distribution([(.sufi, 1)]), 5),
            (Fixtures.track("s2"), Fixtures.distribution([(.metal, 1)]), 3),
            (Fixtures.track("s3"), Fixtures.distribution([(.devotional, 1)]), 1),
        ])
        let ordered = ExperienceRadioEngine.orderedStations(stations, genreProfile: profile)
        let genres = ordered.filter { $0.group == .genres }.map(\.id)
        XCTAssertEqual(Array(genres.prefix(3)), ["sufi", "qawwali", "metal"], "Both Sufi-tagged stations lead, in curated order, then Metal")
        XCTAssertEqual(Array(genres.dropFirst(3)), stations.filter { $0.group == .genres && !["sufi", "qawwali", "metal"].contains($0.id) }.map(\.id))
        XCTAssertEqual(genres.last, "nineties", "Era stations carry no family and stay at the end")
        let moods = ordered.filter { $0.group == .moods }.map(\.id)
        XCTAssertEqual(moods.first, "devotional")
        XCTAssertEqual(Array(moods.dropFirst()), stations.filter { $0.group == .moods && $0.id != "devotional" }.map(\.id))
        XCTAssertEqual(ordered.count, stations.count)
        XCTAssertEqual(Set(ordered.map(\.id)), Set(stations.map(\.id)))
        XCTAssertTrue(ordered.prefix(12).allSatisfy { $0.group == .moods }, "Groups keep their headers")
        XCTAssertEqual(stations.first { $0.id == "english-golden-oldies" }?.genreFamilies, [])
        XCTAssertEqual(stations.first { $0.id == "classical" }?.genreFamilies, [.classical, .hindustani, .carnatic, .instrumental])
    }

    func testRecapAggregatesTheSelectedPeriod() {
        let week = Fixtures.track("week-song")
        let month = Fixtures.track("month-song")
        let year = Fixtures.track("year-song")
        let evidence: [LyricsRequestKey: GenreDistribution] = [
            LyricsRequestKey(week): Fixtures.distribution([(.lofi, 1)]),
            LyricsRequestKey(month): Fixtures.distribution([(.jazz, 1)]),
            LyricsRequestKey(year): Fixtures.distribution([(.country, 1)]),
        ]
        let events = [RecommendationFixtures.event(week, daysAgo: 2, seconds: 100),
                      RecommendationFixtures.event(month, daysAgo: 20, seconds: 100),
                      RecommendationFixtures.event(month, daysAgo: 21, seconds: 100),
                      RecommendationFixtures.event(year, daysAgo: 200, seconds: 100),
                      RecommendationFixtures.event(Fixtures.track("unknown"), daysAgo: 3, seconds: 100)]
        XCTAssertEqual(Fixtures.summary(events, evidence: evidence, window: .week).rows.map(\.family), [.lofi])
        XCTAssertEqual(Fixtures.summary(events, evidence: evidence, window: .week).coverage, 0.5, accuracy: 1e-12)
        let monthly = Fixtures.summary(events, evidence: evidence, window: .month)
        XCTAssertEqual(monthly.rows.map(\.family), [.jazz, .lofi])
        XCTAssertEqual(monthly.top(1).map(\.family), [.jazz])
        XCTAssertEqual(monthly.coverage, 0.75, accuracy: 1e-12)
        let yearly = Fixtures.summary(events, evidence: evidence, window: .year)
        XCTAssertEqual(yearly.rows.map(\.family), [.jazz, .lofi, .country], "Ties follow the taxonomy order")
        XCTAssertEqual(yearly.totalPlays, 5)
        XCTAssertEqual(yearly.classifiedPlays, 4)
        XCTAssertTrue(Fixtures.summary([], evidence: evidence, window: .year).isEmpty)
    }
}

@MainActor
final class GenreEvidenceLoaderTests: XCTestCase {
    private typealias Fixtures = GenreFixtures

    private func lookup(_ family: GenreFamily) -> MusicBrainzGenreLookup {
        MusicBrainzGenreLookup(genres: MusicBrainzRecordingGenres(recordingID: Fixtures.recordingID,
                                                                  recording: [GenreVote(family == .hipHop ? "rap" : "pop", count: 3)]), requests: 2)
    }

    func testSixtyClassificationsPerSessionOncePerRecordingAndNoneWhileOffline() async throws {
        let provider = GenreMetadataMock()
        let store = GenreEvidenceStore(url: nil, now: { Fixtures.now })
        let loader = GenreEvidenceLoader(store: store, provider: provider,
                                         configuration: .init(sessionBudget: 60, launchDelay: 0), now: { Fixtures.now })
        let tracks = (0..<70).map { Fixtures.track("budget-\($0)") }
        for track in tracks { provider.answer(track.id, with: lookup(.hipHop)) }
        var events = Fixtures.events(tracks.map { ($0, 1) })
        events += Fixtures.events([(tracks[0], 3)], daysAgo: 2)
        events.append(RecommendationFixtures.event(Fixtures.track("short"), daysAgo: 1, seconds: 10))

        loader.refresh(events: events, enabled: false, now: Fixtures.now)
        await loader.waitForChecks()
        XCTAssertEqual(provider.recordingLookups.count, 0, "Known offline or inactive services classify nothing")
        XCTAssertFalse(loader.isChecking)

        loader.refresh(events: events, enabled: true, now: Fixtures.now)
        XCTAssertTrue(loader.isChecking)
        await loader.waitForChecks()
        XCTAssertEqual(provider.recordingLookups.count, 60, "The session budget caps classification at 60 recordings")
        XCTAssertEqual(Set(provider.recordingLookups).count, 60, "Repeated plays of one recording cost one lookup")
        XCTAssertFalse(provider.recordingLookups.contains("short"), "Unqualified sessions are never classified")
        XCTAssertEqual(provider.recordingLookups.first, tracks[0].id, "Most recent plays go first")
        XCTAssertEqual(store.recordingCount, 60)
        XCTAssertEqual(loader.classifiedThisSession, 60)
        XCTAssertEqual(loader.pendingCount, 10)

        loader.refresh(events: events, enabled: true, now: Fixtures.now)
        await loader.waitForChecks()
        XCTAssertEqual(provider.recordingLookups.count, 60, "A later refresh in the same session cannot spend more")
        XCTAssertEqual(store.distribution(for: tracks[0])?.families, [.hipHop])
        XCTAssertNil(store.distribution(for: tracks[69]), "The oldest ten wait for the next session")
    }

    func testFailuresAreNotCachedAndAFreshSessionRetriesOnlyTheMissingRecordings() async throws {
        let provider = GenreMetadataMock()
        let store = GenreEvidenceStore(url: nil, now: { Fixtures.now })
        let good = Fixtures.track("good")
        let bad = Fixtures.track("bad")
        let bare = Fixtures.track("bare")
        provider.answer(good.id, with: lookup(.pop))
        provider.fail(bad.id)
        provider.answer(bare.id, with: MusicBrainzGenreLookup(genres: nil, requests: 1))
        let events = Fixtures.events([(good, 1), (bad, 1), (bare, 1)])
        let first = GenreEvidenceLoader(store: store, provider: provider, configuration: .init(launchDelay: 0), now: { Fixtures.now })
        first.refresh(events: events, enabled: true, now: Fixtures.now)
        await first.waitForChecks()
        XCTAssertEqual(Set(provider.recordingLookups), [good.id, bad.id, bare.id])
        XCTAssertEqual(store.distribution(for: good)?.families, [.pop])
        XCTAssertEqual(store.distribution(for: bare), .unclassified, "A confirmed miss is remembered for 30 days")
        XCTAssertNil(store.distribution(for: bad), "A transport failure leaves no evidence")
        first.refresh(events: events, enabled: true, now: Fixtures.now)
        await first.waitForChecks()
        XCTAssertEqual(provider.recordingLookups.filter { $0 == bad.id }.count, 1, "One attempt per recording per session")

        let second = GenreEvidenceLoader(store: store, provider: provider, configuration: .init(launchDelay: 0), now: { Fixtures.now })
        second.refresh(events: events, enabled: true, now: Fixtures.now)
        await second.waitForChecks()
        XCTAssertEqual(provider.recordingLookups.filter { $0 == bad.id }.count, 2, "The next session retries the failure")
        XCTAssertEqual(provider.recordingLookups.filter { $0 == good.id }.count, 1)
        XCTAssertEqual(provider.recordingLookups.filter { $0 == bare.id }.count, 1)
    }

    func testPauseStopsTheQueueAndArtistEvidenceIsReusedAcrossSongs() async throws {
        let provider = GenreMetadataMock()
        provider.delay = .milliseconds(50)
        let store = GenreEvidenceStore(url: nil, now: { Fixtures.now })
        let songs = (0..<3).map { Fixtures.track("artist-song-\($0)") }
        for song in songs {
            provider.answer(song.id, with: MusicBrainzGenreLookup(genres: MusicBrainzRecordingGenres(
                recordingID: Fixtures.recordingID, artistIDs: [Fixtures.artistID]), requests: 2))
        }
        provider.answerArtist(Fixtures.artistID, with: [GenreVote("qawwali", count: 4)])
        let loader = GenreEvidenceLoader(store: store, provider: provider, configuration: .init(launchDelay: 0), now: { Fixtures.now })
        loader.refresh(events: Fixtures.events(songs.map { ($0, 1) }), enabled: true, now: Fixtures.now)
        await loader.waitForChecks()
        XCTAssertEqual(provider.artistLookups, [Fixtures.artistID], "One artist request serves every song by that artist")
        for song in songs { XCTAssertEqual(store.distribution(for: song)?.families, [.sufi]) }
        XCTAssertEqual(store.distribution(for: songs[0])?.source, .artist)

        let more = (0..<5).map { Fixtures.track("paused-\($0)") }
        for song in more { provider.answer(song.id, with: lookup(.pop)) }
        loader.refresh(events: Fixtures.events(more.map { ($0, 1) }), enabled: true, now: Fixtures.now)
        loader.pause()
        XCTAssertFalse(loader.isChecking)
        await loader.waitForChecks()
        XCTAssertLessThan(provider.recordingLookups.count, 3 + 5, "Pause retires the remaining queue")
    }
}
