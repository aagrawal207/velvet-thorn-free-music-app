import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class DailyMixClusteringTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures
    private let day = "2026-05-28"

    // Two Hindi Bollywood artists and two English hip hop artists, each pair played in its own sessions.
    private static let hindiArtists = [("Arijit Singh", "UCarijit"), ("Pritam", "UCpritam")]
    private static let englishArtists = [("Drake", "UCdrake"), ("Kendrick Lamar", "UCkendrick")]

    private func heard(_ artists: [(String, String)], prefix: String, language: MusicLanguage) -> [Track] {
        artists.flatMap { name, id in
            (1...3).map { Fixtures.track("\(prefix)-\(id)-\($0)", artist: name, artistID: id, language: language) }
        }
    }

    private var hindi: [Track] { heard(Self.hindiArtists, prefix: "hi", language: .hindi) }
    private var english: [Track] { heard(Self.englishArtists, prefix: "en", language: .english) }

    /// Hindi sessions on even days, English sessions on odd days; songs inside a session run back to back.
    private func events(_ groups: [[Track]], days: Int = 6) -> [ListeningEvent] {
        var events: [ListeningEvent] = []
        for day in 0..<days {
            let group = groups[day % groups.count]
            for (offset, track) in group.enumerated() {
                events.append(ListeningEvent(id: UUID(), track: track,
                                             startedAt: Fixtures.now.addingTimeInterval(-Double(day + 1) * 86_400 + Double(offset) * 250),
                                             listenedSeconds: 240))
            }
        }
        return events
    }

    private func genreProfile(_ families: [(Track, GenreFamily)], events: [ListeningEvent]) -> ListeningGenreProfile {
        var evidence: [LyricsRequestKey: GenreDistribution] = [:]
        for (track, family) in families {
            evidence[LyricsRequestKey(track)] = GenreDistribution(shares: [GenreShare(family: family, share: 1)], source: .recording)
        }
        let summary = ListeningAnalytics.genreSummary(events: events, for: .month, now: Fixtures.now,
                                                      calendar: Fixtures.calendar, evidence: evidence)
        return ListeningGenreProfile(summary: summary, evidence: evidence)
    }

    private func twoTasteFixture(disliked: [DislikedSong] = []) -> (TasteProfile, ListeningGenreProfile) {
        let events = events([hindi, english])
        let profile = TasteProfile.build(events: events, favorites: [], playlists: [], recents: [], disliked: disliked, now: Fixtures.now)
        let genres = genreProfile(hindi.map { ($0, .bollywood) } + english.map { ($0, .hipHop) }, events: events)
        return (profile, genres)
    }

    private func fresh(_ prefix: String, count: Int, language: MusicLanguage?) -> [Track] {
        (0..<count).map { Fixtures.track("\(prefix)-new-\($0)", artist: "\(prefix) newcomer \($0)", language: language) }
    }

    private func catalog(profile: TasteProfile, hindiFresh: [Track], englishFresh: [Track],
                         crossover: [Track] = []) async -> RecommendationCatalogMock {
        let catalog = RecommendationCatalogMock()
        for track in profile.topTracks(limit: profile.trackAffinity.count) {
            let isHindi = track.language == .hindi
            await catalog.setRadio((isHindi ? hindiFresh : englishFresh) + crossover, for: track.id)
        }
        for (name, id) in Self.hindiArtists {
            await catalog.setArtist(Fixtures.page(id, name: name, topSongs: Array(hindiFresh.suffix(4))))
        }
        for (name, id) in Self.englishArtists {
            await catalog.setArtist(Fixtures.page(id, name: name, topSongs: Array(englishFresh.suffix(4))))
        }
        return catalog
    }

    private func engine(_ catalog: RecommendationCatalogMock) -> RecommendationEngine {
        RecommendationEngine(catalog: catalog, now: { Fixtures.now })
    }

    // MARK: Clustering

    func testTwoGenresAndTwoLanguagesFormTwoDistinctNamedClusters() {
        let (profile, genres) = twoTasteFixture()
        let clusters = TasteClustering.clusters(.init(profile: profile, languageProfile: nil, genreProfile: genres))
        XCTAssertEqual(clusters.count, 2)
        let sets = clusters.map { Set($0.artistKeys) }
        XCTAssertTrue(sets.contains(["arijit singh", "pritam"]))
        XCTAssertTrue(sets.contains(["drake", "kendrick lamar"]))
        XCTAssertTrue(Set(clusters[0].trackIDs).isDisjoint(with: clusters[1].trackIDs))
        XCTAssertEqual(clusters.map(\.trackIDs.count), [6, 6])
        XCTAssertEqual(Set(clusters.map(\.focus)), ["Bollywood", "Hip hop"], "A cluster dominated by one family names it")
        XCTAssertEqual(Set(clusters.compactMap(\.dominantLanguage)), ["hi", "en"])
    }

    func testLanguageAndSessionsAloneSeparateTastesAndNameTheirArtists() {
        let events = events([hindi, english])
        let profile = TasteProfile.build(events: events, favorites: [], playlists: [], recents: [], now: Fixtures.now)
        let clusters = TasteClustering.clusters(.init(profile: profile, languageProfile: nil, genreProfile: nil))
        XCTAssertEqual(clusters.count, 2)
        for cluster in clusters {
            XCTAssertTrue(cluster.focus.hasSuffix(" and Pritam") || cluster.focus.hasSuffix(" and Arijit Singh")
                          || cluster.focus.contains("Drake"), "Without genre evidence the focus names artists: \(cluster.focus)")
            XCTAssertNil(cluster.dominantFamily)
        }
    }

    func testArtistsPlayedTogetherInOneLanguageStayOneCluster() {
        // Every song shares one session each day, so co-occurrence and language agree.
        let together = hindi + heard([("Shreya Ghoshal", "UCshreya")], prefix: "hi2", language: .hindi)
        let profile = TasteProfile.build(events: events([together]), favorites: [], playlists: [], recents: [], now: Fixtures.now)
        let clusters = TasteClustering.clusters(.init(profile: profile, languageProfile: nil, genreProfile: nil))
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].artistKeys), ["arijit singh", "pritam", "shreya ghoshal"])
    }

    func testThinSecondTasteDoesNotBecomeANearDuplicateMix() {
        // Two English recordings are below the four-recording minimum for a separate mix.
        let thinEnglish = Array(english.prefix(2))
        let profile = TasteProfile.build(events: events([hindi, thinEnglish]), favorites: [], playlists: [], recents: [], now: Fixtures.now)
        let clusters = TasteClustering.clusters(.init(profile: profile, languageProfile: nil, genreProfile: nil))
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(TasteClustering.clusters(.init(profile: Fixtures.profile(), languageProfile: nil, genreProfile: nil)).count, 1)
    }

    func testCollaborationsKeepEveryRecordingInOneCluster() {
        // Every collaboration credits Pritam and Drake; its weight counts for both artists but it belongs to one cluster.
        let collaborations = (1...4).map { index in
            Track(id: "collab-\(index)", title: "Collab \(index)", artists: ["Pritam", "Drake"], duration: 240, language: .english,
                  isAudioRecording: true)
        }
        let profile = TasteProfile.build(events: events([Array(hindi.prefix(3)), collaborations]), favorites: [], playlists: [],
                                         recents: [], now: Fixtures.now)
        let clusters = TasteClustering.clusters(.init(profile: profile, languageProfile: nil, genreProfile: nil))
        XCTAssertLessThanOrEqual(clusters.count, 2)
        let all = clusters.flatMap(\.trackIDs)
        XCTAssertEqual(all.count, Set(all).count, "A recording belongs to one cluster")
    }

    func testContextWeightingHookReshapesClustersWithoutChangingTheProfile() {
        let (profile, genres) = twoTasteFixture()
        let englishOnly = TasteClustering.clusters(.init(profile: profile, languageProfile: nil, genreProfile: genres,
                                                         trackWeight: { $0.language == .english ? 1 : 0 }))
        XCTAssertEqual(englishOnly.count, 1)
        XCTAssertEqual(Set(englishOnly[0].artistKeys), ["drake", "kendrick lamar"])
    }

    // MARK: Mixes

    func testThreeMixBuilderProducesDisjointClusterMixesWithinTheSingleMixBudget() async throws {
        let (profile, genres) = twoTasteFixture()
        let hindiFresh = fresh("hindi", count: 16, language: .hindi)
        let englishFresh = fresh("english", count: 16, language: .english)
        let crossover = fresh("crossover", count: 6, language: nil)
        let catalog = await catalog(profile: profile, hindiFresh: hindiFresh, englishFresh: englishFresh, crossover: crossover)
        let mixes = try await engine(catalog).dailyMixes(profile: profile, periodKey: day, genreProfile: genres)

        XCTAssertEqual(mixes.map(\.kind), [.dailyMix, .dailyMix2])
        let ids = mixes.flatMap { $0.tracks.map(\.id) }
        XCTAssertEqual(ids.count, Set(ids).count, "A recording appears in at most one Daily Mix")
        let hindiIDs = Set((hindi + hindiFresh).map(\.id))
        let englishIDs = Set((english + englishFresh).map(\.id))
        let crossoverIDs = Set(crossover.map(\.id))
        for mix in mixes {
            XCTAssertGreaterThanOrEqual(mix.tracks.count, RecommendationEngine.minimumPlaylistSize)
            XCTAssertLessThanOrEqual(mix.tracks.count, RecommendationEngine.dailyMixTarget)
            let mixIDs = Set(mix.tracks.map(\.id))
            let isHindi = mixIDs.isSubset(of: hindiIDs.union(crossoverIDs))
            let isEnglish = mixIDs.isSubset(of: englishIDs.union(crossoverIDs))
            XCTAssertTrue(isHindi != isEnglish, "\(mix.kind) must stay inside one taste")
            XCTAssertEqual(mix.focus, isHindi ? "Bollywood" : "Hip hop")
            XCTAssertEqual(mix.caption, mix.focus)
            XCTAssertEqual(mix.periodKey, day)
            XCTAssertFalse(mix.seedArtists.isEmpty)
            for (_, count) in Dictionary(grouping: mix.tracks, by: RecommendationEngine.primaryArtistKey) {
                XCTAssertLessThanOrEqual(count.count, RecommendationEngine.dailyMixArtistCap)
            }
        }
        let calls = await catalog.callCount
        XCTAssertLessThanOrEqual(calls, RecommendationEngine.providerCallBudget)
        // Without a language profile the seeds use the targeted recommendations call, as the single mix does.
        let radios = await catalog.radioRequests.count
        let artists = await catalog.artistRequests.count
        XCTAssertEqual(radios, RecommendationEngine.seedTrackCount)
        XCTAssertEqual(artists, RecommendationEngine.seedArtistCount)
    }

    func testMixesAreStableWithinAPeriodKeyAndChangeWithIt() async throws {
        let (profile, genres) = twoTasteFixture()
        let catalog = await catalog(profile: profile, hindiFresh: fresh("hindi", count: 16, language: .hindi),
                                    englishFresh: fresh("english", count: 16, language: .english))
        let engine = engine(catalog)
        let first = try await engine.dailyMixes(profile: profile, periodKey: day, genreProfile: genres)
        let repeated = try await engine.dailyMixes(profile: profile, periodKey: day, genreProfile: genres)
        XCTAssertEqual(first, repeated, "The same period and evidence give the same mixes, order included")
        let tomorrow = try await engine.dailyMixes(profile: profile, periodKey: "2026-05-29", genreProfile: genres)
        XCTAssertEqual(tomorrow.map(\.kind), first.map(\.kind))
        XCTAssertNotEqual(tomorrow.map { $0.tracks.map(\.id) }, first.map { $0.tracks.map(\.id) },
                          "A new period reshuffles within the same clusters")
    }

    func testDislikesAreExcludedFromEveryDailyMix() async throws {
        let hindiFresh = fresh("hindi", count: 16, language: .hindi)
        let englishFresh = fresh("english", count: 16, language: .english)
        let dislikedHeard = hindi[0]
        let disliked = [dislikedHeard, englishFresh[0], hindiFresh[1]].map {
            DislikedSong(id: $0.id, title: $0.title, artists: $0.artists, dislikedAt: Fixtures.now)
        }
        let (profile, genres) = twoTasteFixture(disliked: disliked)
        let catalog = await catalog(profile: profile, hindiFresh: hindiFresh, englishFresh: englishFresh)
        let mixes = try await engine(catalog).dailyMixes(profile: profile, periodKey: day, genreProfile: genres)
        XCTAssertEqual(mixes.count, 2)
        let ids = Set(mixes.flatMap { $0.tracks.map(\.id) })
        XCTAssertTrue(ids.isDisjoint(with: disliked.map(\.id)))
    }

    func testThinHistoryFallsBackToTheSingleDailyMixAsDailyMixOne() async throws {
        let profile = Fixtures.profile()
        let freshTracks = fresh("single", count: 30, language: .hindi)
        func configured() async -> RecommendationCatalogMock {
            let catalog = RecommendationCatalogMock()
            for seed in profile.topTracks(limit: 4) { await catalog.setRadio(freshTracks, for: seed.id) }
            for (id, name) in [("UCarijit", "Arijit Singh"), ("UCweeknd", "The Weeknd"), ("UCpritam", "Pritam")] {
                await catalog.setArtist(Fixtures.page(id, name: name, topSongs: Array(freshTracks.prefix(5))))
            }
            return catalog
        }
        let catalog = await configured()
        let mixes = try await engine(catalog).dailyMixes(profile: profile, periodKey: day)
        let single = try await engine(await configured()).dailyMix(profile: profile, languages: [], periodKey: day)
        XCTAssertEqual(mixes.map(\.kind), [.dailyMix])
        XCTAssertEqual(mixes.first?.tracks, single?.tracks, "One cluster keeps today's single Daily Mix exactly")
        XCTAssertEqual(mixes.first?.seedArtists, single?.seedArtists)
        XCTAssertNil(mixes.first?.focus)
        let cold = TasteProfile.build(events: [], favorites: [], playlists: [], recents: [], now: Fixtures.now)
        let coldMixes = try await engine(await configured()).dailyMixes(profile: cold, periodKey: day)
        XCTAssertTrue(coldMixes.isEmpty)
    }

    func testOpenScopeWithAContextFilterReusesTheMixPipelineForMomentMixes() async throws {
        let (profile, genres) = twoTasteFixture()
        let catalog = await catalog(profile: profile, hindiFresh: fresh("hindi", count: 16, language: .hindi),
                                    englishFresh: fresh("english", count: 16, language: .english))
        let scope = MixScope(kind: .dailyMix, focus: "English evenings", includes: { $0.language == .english })
        let mixes = try await engine(catalog).scopedMixes(profile: profile, scopes: [scope], periodKey: day, genreProfile: genres)
        XCTAssertEqual(mixes.count, 1)
        XCTAssertTrue(mixes[0].tracks.allSatisfy { $0.language == .english })
        XCTAssertEqual(mixes[0].focus, "English evenings")
        let calls = await catalog.callCount
        XCTAssertLessThanOrEqual(calls, RecommendationEngine.providerCallBudget)
    }

    // MARK: Identity

    func testLegacyDailyMixIdentifierResolvesToDailyMixOneEverywhere() throws {
        XCTAssertEqual(GeneratedPlaylistKind.dailyMix1, .dailyMix)
        XCTAssertEqual(GeneratedPlaylistKind.dailyMix.rawValue, "dailyMix", "Saved libraries and widgets keep the original value")
        XCTAssertEqual(GeneratedPlaylistKind(identifier: "dailyMix"), .dailyMix)
        XCTAssertEqual(GeneratedPlaylistKind(identifier: "dailyMix1"), .dailyMix)
        XCTAssertEqual(GeneratedPlaylistKind(identifier: "dailyMix2"), .dailyMix2)
        XCTAssertNil(GeneratedPlaylistKind(identifier: "dailyMix4"))
        XCTAssertEqual(GeneratedPlaylistKind.dailyMixes.map(\.title), ["Daily Mix 1", "Daily Mix 2", "Daily Mix 3"])
        XCTAssertEqual(GeneratedPlaylistKind.dailyMixes.map(\.dailyMixNumber), [1, 2, 3])
        XCTAssertNil(GeneratedPlaylistKind.discoverWeekly.dailyMixNumber)

        for selection in ["dailyMix", "dailyMix1", nil, "unknown"] as [String?] {
            XCTAssertEqual(MixWidgetOptions.kind(for: selection), .dailyMix)
        }
        XCTAssertEqual(MixWidgetOptions.kind(for: "dailyMix3"), .dailyMix3)
        XCTAssertEqual(MixWidgetOptions.kinds, [.dailyMix, .dailyMix2, .dailyMix3, .discoverWeekly])
        XCTAssertEqual(MixWidgetOptions.kinds.map(\.widgetTitle), ["Daily Mix 1", "Daily Mix 2", "Daily Mix 3", "Discover Weekly"])

        for raw in ["dailyMix", "dailyMix1"] {
            let url = try XCTUnwrap(URL(string: "ganabajana://widget/mix?kind=\(raw)&period=2026-05-28&play=1"))
            XCTAssertEqual(MusicWidgetRoute(url: url), .mix(kind: .dailyMix, periodKey: "2026-05-28", play: true))
        }
        XCTAssertEqual(MusicWidgetRoute.mix(kind: .dailyMix, periodKey: "p", play: false).url.absoluteString,
                       "ganabajana://widget/mix?kind=dailyMix&period=p&play=0")

        let legacy = Data(#"{"kind":"dailyMix","tracks":[],"generatedAt":0,"periodKey":"2026-05-28","seedArtists":["Arijit Singh"]}"#.utf8)
        let decoded = try JSONDecoder().decode(GeneratedPlaylist.self, from: legacy)
        XCTAssertEqual(decoded.kind, .dailyMix)
        XCTAssertNil(decoded.focus)
        XCTAssertEqual(decoded.collection.id, "mix.dailyMix")
        XCTAssertEqual(decoded.collection.title, "Daily Mix 1")
        XCTAssertEqual(decoded.caption, "Arijit Singh")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        XCTAssertEqual(Set(encoded?.keys.map { $0 } ?? []), ["kind", "tracks", "generatedAt", "periodKey", "seedArtists"],
                       "A mix without a focus keeps the exact legacy shape")
    }

    func testDailyMixesSaveTogetherAndRetireStaleLaterMixes() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let song = { (id: String) in Fixtures.track(id) }
            library.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [song("old-1")], generatedAt: Fixtures.now,
                                              periodKey: "2026-05-27", seedArtists: []))
            library.saveMix(GeneratedPlaylist(kind: .dailyMix3, tracks: [song("old-3")], generatedAt: Fixtures.now,
                                              periodKey: "2026-05-27", seedArtists: []))
            library.saveMix(GeneratedPlaylist(kind: .discoverWeekly, tracks: [song("weekly")], generatedAt: Fixtures.now,
                                              periodKey: "2026-W22", seedArtists: []))
            library.saveDailyMixes([
                GeneratedPlaylist(kind: .dailyMix, tracks: [song("new-1")], generatedAt: Fixtures.now, periodKey: day,
                                  seedArtists: [], focus: "Bollywood"),
                GeneratedPlaylist(kind: .dailyMix2, tracks: [song("new-2")], generatedAt: Fixtures.now, periodKey: day,
                                  seedArtists: [], focus: "Hip hop"),
            ])
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(library.mix(.dailyMix)?.tracks.map(\.id), ["new-1"])
            XCTAssertEqual(library.mix(.dailyMix2)?.focus, "Hip hop")
            XCTAssertNil(library.mix(.dailyMix3), "Yesterday's Daily Mix 3 must not sit beside today's mixes")
            XCTAssertEqual(library.mix(.discoverWeekly)?.tracks.map(\.id), ["weekly"])

            library.saveDailyMixes([GeneratedPlaylist(kind: .dailyMix, tracks: [song("late")], generatedAt: Fixtures.now,
                                                      periodKey: day, seedArtists: [])])
            XCTAssertEqual(library.mix(.dailyMix)?.tracks.map(\.id), ["new-1"], "A saved current period is never replaced")
            XCTAssertNotNil(library.mix(.dailyMix2))

            let reloaded = LibraryStore(directory: directory)
            XCTAssertEqual(reloaded.mix(.dailyMix2)?.focus, "Hip hop")
            XCTAssertEqual(reloaded.mixes.count, 3)
        }
    }

    func testWidgetSnapshotCarriesDiscoverWeeklyAndThreeDailyMixes() throws {
        let kinds: [GeneratedPlaylistKind] = [.discoverWeekly, .dailyMix, .dailyMix2, .dailyMix3]
        let mixes = kinds.map { kind in
            GeneratedPlaylist(kind: kind, tracks: [libraryTestTrack("widget-\(kind.rawValue)")], generatedAt: Fixtures.now,
                              periodKey: day, seedArtists: ["Seed"], focus: kind.isDailyMix ? "Focus" : nil)
        }
        // A fixed stamp keeps the millisecond round trip exact; a live Date can lose sub-millisecond bits.
        let snapshot = WidgetLibrarySnapshot.projection(recentlyPlayed: [], likedSongs: [], mixes: mixes, updatedAt: Fixtures.now)
        XCTAssertEqual(snapshot.mixes.map(\.kind), kinds)
        XCTAssertTrue(snapshot.mixes.allSatisfy { $0.focus == nil && $0.seedArtists.isEmpty }, "Widgets carry no taste description")
        XCTAssertNoThrow(try snapshot.validate())
        try withLibraryTestDirectory { directory in
            let store = WidgetSnapshotStore(directory: directory)
            XCTAssertTrue(try store.write(snapshot))
            XCTAssertEqual(store.read(), snapshot)
        }
        let presentation = MusicWidgetPresentation(snapshot: snapshot, kind: .mixes, mixKind: .dailyMix2)
        XCTAssertEqual(presentation.heading, "Daily Mix 2")
        XCTAssertEqual(presentation.selectedMix?.kind, .dailyMix2)
    }
}
