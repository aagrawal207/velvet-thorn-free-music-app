import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class ListeningLanguageRadioTests: XCTestCase {
    func testAutomaticSelectionUsesDominantCuesAndThreeScheduledStyleSlots() throws {
        let station = try station("left-field-rap")
        let hindi = station.selection(for: profile([.hindi: 90, .english: 10]))
        let english = station.selection(for: profile([.hindi: 10, .english: 90]))

        XCTAssertEqual(hindi.seeds.map(\.artist.name), ["Char Diwaari", "Seedhe Maut"])
        XCTAssertEqual(english.seeds.map(\.artist.name), ["Kanye West", "Tyler, The Creator"])
        XCTAssertEqual(hindi.styleQueries, ["Hindi rap songs", "hip hop songs", "desi hip hop songs"])
        XCTAssertEqual(english.styleQueries, ["hip hop songs", "Hindi rap songs", "rap hits english"])
        XCTAssertEqual(hindi.contentLabel, "Follows your listening")
        XCTAssertEqual(english.contentLabel, "Follows your listening")
        XCTAssertEqual(hindi.description, station.description)
        XCTAssertEqual(english.description, station.description)
        XCTAssertEqual(station.selection(for: ListeningLanguageProfile()).contentLabel, "Automatic discovery")
    }

    func testEveryStationSupportsAllFiveAutomaticLanguageTargets() {
        for language in ArtistSongLanguage.allCases {
            for station in RadioExperience.stations {
                let selection = station.selection(for: profile([language: 100]))
                XCTAssertEqual(selection.styleQueries.count, 3, "\(station.id): \(language)")
                XCTAssertEqual(Set(selection.styleQueries).count, 3)
                XCTAssertEqual(selection.contentLabel, "Follows your listening")
                if [.bengali, .tamil, .telugu].contains(language) {
                    XCTAssertTrue(selection.seeds.isEmpty)
                    XCTAssertTrue(selection.styleQueries.allSatisfy { $0.contains(language.title) })
                }
            }
        }
    }

    func testDominantHindiSearchesPreferredStyleEvenWhenEnglishCueRadiosWouldSucceed() async throws {
        let station = try station()
        let cues = station.seeds.enumerated().map {
            RecommendationFixtures.track("cue-\($0.offset)", title: $0.element.title, artist: $0.element.artist.name, language: .english)
        }
        let hindiSongs = ExperienceRadioFixtures.styleSongs("hindi-style", language: .hindi)
        let englishSongs = ExperienceRadioFixtures.styleSongs("english-style", language: .english)
        let queries = ["Hindi sad songs", "melancholy indie sad songs", "Bollywood melancholy songs"]
        var searches: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: zip(station.seeds, cues).map {
            ($0.query, .success([$1]))
        })
        searches[queries[0]] = .success(hindiSongs)
        searches[queries[1]] = .success(englishSongs)
        searches[queries[2]] = .success(hindiSongs)
        let radios: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: (cues + hindiSongs).map {
            ($0.id, .success(ExperienceRadioFixtures.styleSongs("near-\($0.id)", language: $0.language)))
        })
        let playlists: [String: Result<[MusicCollection], any Error>] = Dictionary(uniqueKeysWithValues: queries.map { ($0, .success([])) })

        let hindiCatalog = ExperienceRadioCatalogFixture(searches: searches, radios: radios, playlistSearches: playlists)
        let hindiBatch = try await ExperienceRadioEngine(catalog: hindiCatalog).start(
            station, disliked: [], languages: [.english], languageProfile: profile([.hindi: 90, .english: 10]))
        let hindiSearches = await hindiCatalog.searchRequests
        let hindiRadios = await hindiCatalog.radioRequests
        XCTAssertEqual(Set(hindiSearches.map(\.query)), Set(queries))
        XCTAssertEqual(hindiSearches.filter { $0.filter == .songs }.count, 3)
        XCTAssertEqual(hindiSearches.filter { $0.filter == .playlists }.count, 3)
        XCTAssertEqual(hindiRadios.count, 4)
        XCTAssertTrue(hindiRadios.allSatisfy { $0.language == .hindi })
        XCTAssertTrue(hindiBatch.tracks.prefix(4).allSatisfy { $0.language == .hindi })
        XCTAssertGreaterThan(hindiBatch.tracks.filter { $0.language == .hindi }.count,
                             hindiBatch.tracks.filter { $0.language == .english }.count)
        XCTAssertTrue(Set(cues.map(\.id)).isDisjoint(with: hindiBatch.tracks.map(\.id)))

        let englishCatalog = ExperienceRadioCatalogFixture(searches: searches, radios: radios, playlistSearches: playlists)
        let englishBatch = try await ExperienceRadioEngine(catalog: englishCatalog).start(
            station, disliked: [], languages: [], languageProfile: profile([.hindi: 10, .english: 90]))
        let englishSearches = await englishCatalog.searchRequests
        XCTAssertEqual(Set(englishSearches.map(\.query)), Set(station.seeds.map(\.query)))
        XCTAssertEqual(englishBatch.tracks.count, 24)
        XCTAssertTrue(englishBatch.tracks.allSatisfy { $0.language == .english })
        XCTAssertFalse(englishBatch.discoveryTrackIDs.isEmpty)
    }

    func testThreeStyleQueriesAndTwoPlaylistsAreSharedAcrossFiveActiveLanguages() async throws {
        let station = try station()
        let profile = profile([.hindi: 50, .english: 25, .tamil: 15, .bengali: 6, .telugu: 4])
        let queries = ["Hindi sad songs", "melancholy indie sad songs", "Tamil melancholy songs"]
        XCTAssertEqual(station.selection(for: profile).styleQueries, queries)
        let songs = ExperienceRadioFixtures.styleSongs("shared-budget", language: .hindi)
        let playlists = (0..<5).map { MusicCollection(id: "playlist-\($0)", title: "Playlist \($0)", kind: .playlist) }
        let catalog = ExperienceRadioCatalogFixture(
            searches: [queries[0]: .success(songs), queries[1]: .success([]), queries[2]: .success([])],
            radios: Dictionary(uniqueKeysWithValues: songs.map { ($0.id, .success([])) }),
            albums: Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, .success(CatalogPage())) }),
            playlistSearches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success(playlists)) }))

        let batch = try await ExperienceRadioEngine(catalog: catalog).start(station, disliked: [], languages: [], languageProfile: profile)
        let searched = await catalog.searchRequests
        let browsed = await catalog.browseRequests
        let radios = await catalog.radioRequests
        let peak = await catalog.maximumActiveRequests
        XCTAssertEqual(searched.count, 6)
        XCTAssertEqual(Set(searched.map(\.query)), Set(queries))
        XCTAssertEqual(searched.filter { $0.filter == .songs }.count, 3)
        XCTAssertEqual(searched.filter { $0.filter == .playlists }.count, 3)
        XCTAssertTrue(searched.allSatisfy { $0.continuation == nil })
        XCTAssertEqual(Set(browsed), ["playlist-0", "playlist-1"])
        XCTAssertEqual(radios.count, 4)
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertEqual(Set(batch.tracks), Set(songs))
    }

    func testRecordingEvidenceContradictingCueTagsReachesPreferredStyleBeforeRadio() async throws {
        let cue = RecommendationFixtures.track("english-cue", artist: "Cue artist", language: .english)
        let queries = ["Hindi quiet songs", "Hindi slow songs", "Hindi acoustic songs"]
        let station = RadioExperience(id: "contradictory-cue", title: "Quiet", description: "Fixture", symbol: "radio",
            discoveryLanguages: [.hindi], contentLabel: "Hindi", seeds: [.init(recording: cue, artist: cue.credits[0])],
            styleQueries: queries)
        let songs = ExperienceRadioFixtures.styleSongs("preferred-style", language: .hindi)
        var radios: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, .success([])) })
        radios[cue.id] = .success(ExperienceRadioFixtures.styleSongs("irrelevant-neighbor", language: .english))
        let catalog = ExperienceRadioCatalogFixture(
            searches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success(songs)) }), radios: radios,
            playlistSearches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success([])) }))
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(
            station, disliked: [], languages: [], languageProfile: profile([.hindi: 100]))

        let requested = await catalog.radioRequests
        let searched = await catalog.searchRequests
        XCTAssertEqual(Set(searched.map(\.query)), Set(queries))
        XCTAssertEqual(requested.count, 4)
        XCTAssertFalse(requested.contains(cue))
        XCTAssertTrue(requested.allSatisfy { $0.language == .hindi })
        XCTAssertEqual(Set(batch.tracks), Set(songs))
        XCTAssertEqual(cue.language, .english)
    }

    func testLearnedBengaliTamilAndTeluguStartFromTargetedQueriesWithoutRelabelingRecordings() async throws {
        let station = try station()
        for language in [ArtistSongLanguage.bengali, .tamil, .telugu] {
            let songs = ExperienceRadioFixtures.styleSongs(language.rawValue)
            let evidence: [LyricsRequestKey: ArtistSongLanguageResult] = Dictionary(uniqueKeysWithValues: songs.map {
                (LyricsRequestKey($0), .identified(language, source: .matchedLyrics))
            })
            let profile = profile([language: 100], evidence: evidence)
            let queries = ["\(language.title) melancholy songs", "melancholy \(language.title) music", "melancholy songs in \(language.title)"]
            let catalog = ExperienceRadioCatalogFixture(
                searches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success(songs)) }),
                radios: Dictionary(uniqueKeysWithValues: songs.map { ($0.id, .success([])) }),
                playlistSearches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success([])) }))

            let batch = try await ExperienceRadioEngine(catalog: catalog).start(
                station, disliked: [], languages: [.hindi, .english], languageProfile: profile)
            let searched = await catalog.searchRequests
            let targeted = await catalog.targetedRadioRequests
            XCTAssertEqual(Set(searched.map(\.query)), Set(queries))
            XCTAssertEqual(searched.count, 6)
            XCTAssertEqual(station.selection(for: profile).contentLabel, "Follows your listening")
            XCTAssertEqual(Set(batch.tracks), Set(songs))
            XCTAssertTrue(batch.tracks.allSatisfy { $0.language == nil })
            XCTAssertTrue(batch.tracks.allSatisfy { profile.language(for: $0) == language })
            XCTAssertEqual(targeted, 0)
        }
    }

    func testExplicitNudgesTargetUnheardLanguagesWithoutClaimingLearnedFacts() async throws {
        let station = try station()
        for language in [ArtistSongLanguage.bengali, .tamil, .telugu] {
            var nudges = LanguageRecommendationNudges()
            nudges[.hindi] = .less
            nudges[.english] = .less
            nudges[language] = .more
            let profile = ListeningLanguageProfile(nudges: nudges)
            let queries = ["\(language.title) melancholy songs", "melancholy indie sad songs", "Hindi sad songs"]
            let songs = ExperienceRadioFixtures.styleSongs("nudged-\(language.rawValue)")
            let catalog = ExperienceRadioCatalogFixture(
                searches: [queries[0]: .success(songs), queries[1]: .success([]), queries[2]: .success([])],
                radios: Dictionary(uniqueKeysWithValues: songs.map { ($0.id, .success([])) }),
                playlistSearches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success([])) }))

            let batch = try await ExperienceRadioEngine(catalog: catalog).start(station, disliked: [], languages: [], languageProfile: profile)
            let searched = await catalog.searchRequests
            XCTAssertEqual(station.selection(for: profile).styleQueries, queries)
            XCTAssertEqual(Set(searched.map(\.query)), Set(queries))
            XCTAssertEqual(station.selection(for: profile).contentLabel, "Automatic discovery")
            XCTAssertFalse(profile.isLearned)
            XCTAssertTrue(profile.summary.rows.isEmpty)
            XCTAssertEqual(profile.summary.totalPlays, 0)
            XCTAssertTrue(batch.tracks.allSatisfy { $0.language == nil && profile.language(for: $0) == nil })
        }
    }

    func testMoreAndLessChangeQueueRankingWithoutExcludingOutsideOrUnknownLanguages() {
        let english = RecommendationFixtures.track("english", artist: "English artist", language: .english)
        let hindi = RecommendationFixtures.track("hindi", artist: "Hindi artist", language: .hindi)
        let tamil = RecommendationFixtures.track("tamil", artist: "Tamil artist")
        let unknown = RecommendationFixtures.track("unknown", artist: "Unknown artist")
        let evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [
            LyricsRequestKey(tamil): .identified(.tamil, source: .matchedLyrics),
            LyricsRequestKey(unknown): .likely(.hindi, source: .titleLabel),
        ]
        let pools = [[english], [hindi], [tamil], [unknown]]
        var nudges = LanguageRecommendationNudges()
        nudges[.hindi] = .more
        nudges[.english] = .less
        let moreHindi = profile([.hindi: 50, .english: 50], nudges: nudges, evidence: evidence)
        let hindiPicks = ExperienceRadioEngine.selection(buckets: pools, disliked: [], languages: [.english], languageProfile: moreHindi)
        XCTAssertEqual(hindiPicks.tracks, [hindi, unknown, english, tamil])

        nudges[.hindi] = .less
        nudges[.english] = .more
        let moreEnglish = profile([.hindi: 50, .english: 50], nudges: nudges, evidence: evidence)
        let englishPicks = ExperienceRadioEngine.selection(buckets: pools, disliked: [], languages: [.hindi], languageProfile: moreEnglish)
        XCTAssertEqual(englishPicks.tracks, [english, unknown, hindi, tamil])
        XCTAssertNil(tamil.language)
        XCTAssertNil(moreHindi.language(for: unknown))
        XCTAssertEqual(ExperienceRadioEngine.selection(buckets: pools, disliked: [], languages: [.english]).tracks, [english, tamil, unknown])
    }

    func testWeightedSelectionPreservesDislikesSongIdentityAudioAndPrimaryArtistCaps() {
        let prolific = (0..<8).map { RecommendationFixtures.track("prolific-\($0)", artist: "Prolific artist", language: .hindi) }
        let queued = RecommendationFixtures.track("queued", title: "Already played")
        var queuedID = queued
        queuedID.title = "Different title for queued recording"
        let queuedTitle = RecommendationFixtures.track("queued-version", title: "Already played (Remastered)", language: .hindi)
        let blocked = DislikedSong(id: "blocked", title: "Disliked song", artists: [])
        let blockedID = RecommendationFixtures.track("blocked", title: "Different blocked title", language: .hindi)
        let blockedTitle = RecommendationFixtures.track("blocked-version", title: "Disliked song (Remastered)", language: .hindi)
        let alternate = RecommendationFixtures.track("alternate", title: prolific[0].title + " (Remastered)", language: .hindi)
        let invalid = [RecommendationFixtures.track("video", audio: false), RecommendationFixtures.track("unverified", audio: nil),
                       RecommendationFixtures.track("brief", duration: 10), RecommendationFixtures.track("slowed", title: "A song (Slowed + Reverb)"),
                       RecommendationFixtures.track(" ", title: "No recording identifier")]
        let unknown = RecommendationFixtures.track("unknown", artist: "Unknown artist")
        let outside = RecommendationFixtures.track("outside", artist: "Outside artist", language: .english)
        let featured = (0..<2).map { index in
            Track(id: "featured-\(index)", title: "Featured song \(index)", credits: [ArtistCredit(name: "Primary \(index)"),
                ArtistCredit(name: "Prolific artist")], duration: 240, language: .hindi, isAudioRecording: true)
        }
        let picks = ExperienceRadioEngine.selection(
            buckets: [invalid + [queuedID, queuedTitle, blockedID, blockedTitle] + prolific,
                      [prolific[0], alternate, unknown, outside] + featured],
            excluding: [queued], disliked: [blocked], languages: [.hindi], languageProfile: profile([.hindi: 100]))

        let expected = Array(prolific.prefix(4)) + [unknown, outside] + featured
        XCTAssertEqual(Set(picks.tracks.map(\.id)), Set(expected.map(\.id)))
        XCTAssertEqual(picks.tracks.filter { $0.artists.first == "Prolific artist" }.count, 4)
        XCTAssertTrue(Set(featured).isSubset(of: Set(picks.tracks)))
        XCTAssertEqual(Set(picks.tracks.map(\.id)).count, picks.tracks.count)
        XCTAssertEqual(Set(picks.tracks.map { SongTitle.core($0.title) }).count, picks.tracks.count)
        for limit in [0, -1] {
            XCTAssertTrue(ExperienceRadioEngine.selection(buckets: [prolific], disliked: [], limit: limit,
                                                          languageProfile: profile([.hindi: 100])).tracks.isEmpty)
        }
    }

    func testWeightedSelectionKeepsOriginalBucketProvenanceAfterReordering() {
        let aEnglish = RecommendationFixtures.track("a-en", artist: "A English", language: .english)
        let aHindi = RecommendationFixtures.track("a-hi", artist: "A Hindi", language: .hindi)
        let bEnglish = RecommendationFixtures.track("b-en", artist: "B English", language: .english)
        let bHindi = RecommendationFixtures.track("b-hi", artist: "B Hindi", language: .hindi)
        let unknown = RecommendationFixtures.track("unknown", artist: "Unknown")
        let pools = [[aEnglish, aHindi], [], [bEnglish, bHindi, unknown]]
        let profile = profile([.hindi: 100])
        let full = ExperienceRadioEngine.selection(buckets: pools, disliked: [], languageProfile: profile)
        XCTAssertEqual(full.tracks, [aHindi, bHindi, aEnglish, bEnglish, unknown])
        XCTAssertEqual(full.lastByBucket, [0: aEnglish, 2: unknown])
        let limited = ExperienceRadioEngine.selection(buckets: pools, disliked: [], limit: 3, languageProfile: profile)
        XCTAssertEqual(limited.tracks, [aHindi, bHindi, aEnglish])
        XCTAssertEqual(limited.lastByBucket, [0: aEnglish, 2: bHindi])
    }

    func testLanguageWeightingChoosesSeedsBeforeThePrimaryArtistCapAndEarlySuccess() async throws {
        let english = RecommendationFixtures.track("shared-en", artist: "Shared artist", language: .english)
        let hindi = RecommendationFixtures.track("shared-hi", artist: "Shared artist", language: .hindi)
        let cues = [english, hindi, RecommendationFixtures.track("unknown-a", artist: "Unknown A"),
                    RecommendationFixtures.track("unknown-b", artist: "Unknown B"),
                    RecommendationFixtures.track("other-hi", artist: "Other Hindi", language: .hindi),
                    RecommendationFixtures.track("other-en", artist: "Other English", language: .english)]
        let station = RadioExperience(id: "weighted-seeds", title: "Weighted seeds", description: "Fixture", symbol: "radio",
            discoveryLanguages: [.hindi, .english], contentLabel: "Editorial audience", seeds: cues.map {
                .init(recording: $0, artist: $0.credits[0])
            })
        let radios: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: cues.map {
            ($0.id, .success([RecommendationFixtures.track("near-\($0.id)", artist: "Neighbor \($0.id)")]))
        })
        for (language, expected, excluded) in [(ArtistSongLanguage.hindi, hindi, english), (.english, english, hindi)] {
            let catalog = ExperienceRadioCatalogFixture(radios: radios)
            let batch = try await ExperienceRadioEngine(catalog: catalog).start(
                station, disliked: [], languages: [], languageProfile: profile([language: 100]))
            let requested = await catalog.radioRequests
            let searches = await catalog.searchRequests
            XCTAssertEqual(requested.count, 4)
            XCTAssertTrue(requested.contains(expected))
            XCTAssertFalse(requested.contains(excluded), "Language ranking must precede the one-seed-per-artist cap")
            XCTAssertEqual(batch.tracks.first, expected)
            XCTAssertTrue(searches.isEmpty, "This fixture succeeds in the initial weighted radio lanes")
        }
    }

    func testFullWeightedQueueRetainsEveryViableAnchorAndItsOwnFrontier() async throws {
        let cues = [RecommendationFixtures.track("hindi-anchor", artist: "Hindi anchor", language: .hindi),
                    RecommendationFixtures.track("english-anchor", artist: "English anchor", language: .english),
                    RecommendationFixtures.track("unknown-anchor", artist: "Unknown anchor"),
                    RecommendationFixtures.track("tamil-anchor", artist: "Tamil anchor")]
        let station = RadioExperience(id: "weighted-anchors", title: "Weighted anchors", description: "Fixture", symbol: "radio",
            discoveryLanguages: [.hindi], contentLabel: "Hindi", seeds: cues.map { .init(recording: $0, artist: $0.credits[0]) })
        let radios: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: cues.map { anchor in
            (anchor.id, .success((0..<30).map {
                RecommendationFixtures.track("\(anchor.id)-near-\($0)", artist: "\(anchor.id) neighbor \($0)", language: .hindi)
            }))
        })
        let catalog = ExperienceRadioCatalogFixture(radios: radios)
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(station, disliked: [], languages: [.english],
            languageProfile: profile([.hindi: 100], overrides: ["tamil-anchor": "ta"]))

        XCTAssertEqual(batch.tracks.count, 24)
        XCTAssertEqual(batch.buckets.count, 4)
        XCTAssertTrue(Set(cues).isSubset(of: Set(batch.tracks)))
        XCTAssertEqual(batch.tracks.first, cues[0])
        for bucket in batch.buckets {
            XCTAssertEqual(bucket.frontier.id, "\(bucket.anchor.id)-near-4")
            XCTAssertTrue(batch.discoveryTrackIDs.contains(bucket.frontier.id))
        }
    }

    func testArtistHintsUseSoftLanguageEligibilityAndWeightBeforeTheirCandidateCap() async throws {
        let artist = ArtistCredit(name: "Hint artist", id: "UChint")
        let english = RecommendationFixtures.track("hint-en", artist: artist.name, artistID: artist.id, language: .english)
        let hindi = RecommendationFixtures.track("hint-hi", artist: artist.name, artistID: artist.id, language: .hindi)
        let unknown = RecommendationFixtures.track("hint-unknown", artist: artist.name, artistID: artist.id)
        let extra = RecommendationFixtures.track("hint-extra", artist: artist.name, artistID: artist.id)
        let catalog = ExperienceRadioCatalogFixture(artists: ["UChint": .success(ArtistPage(
            id: "UChint", name: artist.name, topSongs: [english, hindi, unknown, extra]))])
        for languages in [Set<MusicLanguage>(), [.english]] {
            var configuration = RadioConfiguration(station: try station(), languages: languages)
            configuration.artists = [artist]
            let resolved = try await ExperienceRadioEngine(catalog: catalog).resolveArtists(
                configuration, disliked: [], languageProfile: profile([.hindi: 100]))
            XCTAssertEqual(resolved.count, 1)
            XCTAssertEqual(resolved.first?.seeds.compactMap(\.recording), [hindi, english, unknown])
        }
        let requests = await catalog.artistRequests
        XCTAssertEqual(requests, ["UChint", "UChint"])
    }

    func testProfileStartupStillRequiresFourSongsAndDiscoveryBeyondFixedCues() async throws {
        let queries = ["Hindi guard songs", "Hindi guard music", "Hindi guard favorites"]
        for cueCount in [1, 4] {
            let cues = (0..<cueCount).map { RecommendationFixtures.track("cue-\($0)", artist: "Cue artist \($0)", language: .hindi) }
            let station = RadioExperience(id: "startup-guards", title: "Startup guards", description: "Fixture", symbol: "radio",
                discoveryLanguages: [.hindi], contentLabel: "Hindi", seeds: cues.map { .init(recording: $0, artist: $0.credits[0]) },
                styleQueries: queries)
            let neighbors = cueCount == 4 ? cues : [RecommendationFixtures.track("near-a", artist: "A", language: .hindi),
                                                    RecommendationFixtures.track("near-b", artist: "B", language: .hindi)]
            let catalog = ExperienceRadioCatalogFixture(
                searches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success([])) }),
                radios: Dictionary(uniqueKeysWithValues: cues.map { ($0.id, .success(neighbors)) }),
                playlistSearches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success([])) }))
            do {
                _ = try await ExperienceRadioEngine(catalog: catalog).start(
                    station, disliked: [], languages: [], languageProfile: profile([.hindi: 100]))
                XCTFail(cueCount == 4 ? "Fixed cues are not discovery" : "An anchor and two neighbors are fewer than four songs")
            } catch { XCTAssertEqual(error as? ExperienceRadioError, .unavailable) }
            let calls = await catalog.radioRequests
            XCTAssertEqual(calls.count, cueCount == 4 ? 6 : 2)
        }
    }

    func testContinuationUsesTheSuppliedFrozenProfileAndPreservesLaneFrontiers() async throws {
        let a = RecommendationFixtures.track("anchor-en", artist: "Anchor English", language: .english)
        let b = RecommendationFixtures.track("anchor-hi", artist: "Anchor Hindi", language: .hindi)
        let aFrontier = RecommendationFixtures.track("frontier-en", artist: "Frontier English", language: .english)
        let bFrontier = RecommendationFixtures.track("frontier-hi", artist: "Frontier Hindi", language: .hindi)
        let english = RecommendationFixtures.track("new-en", artist: "New English", language: .english)
        let hindi = RecommendationFixtures.track("new-hi", artist: "New Hindi", language: .hindi)
        let unknown = RecommendationFixtures.track("new-unknown", artist: "New Unknown")
        let catalog = ExperienceRadioCatalogFixture(radios: [a.id: .success([english]), bFrontier.id: .success([hindi, unknown])])
        let engine = ExperienceRadioEngine(catalog: catalog)
        let buckets = [ExperienceRadioEngine.Bucket(anchor: a, frontier: aFrontier), .init(anchor: b, frontier: bFrontier)]
        let frozen = profile([.hindi: 100])
        let newerListening = profile([.english: 100])

        let batch = try await engine.continueRadio(buckets: buckets, round: 0, queue: [a, b, aFrontier, bFrontier],
            disliked: [], languages: [.english], languageProfile: frozen)
        XCTAssertEqual(batch.tracks, [hindi, english, unknown])
        XCTAssertEqual(batch.buckets.map(\.anchor), [a, b])
        XCTAssertEqual(batch.buckets.map(\.frontier), [english, unknown])

        let retargeted = try await engine.continueRadio(buckets: buckets, round: 0, queue: [a, b, aFrontier, bFrontier],
            disliked: [], languages: [.hindi], languageProfile: newerListening)
        XCTAssertEqual(retargeted.tracks, [english, hindi, unknown])
        XCTAssertEqual(retargeted.buckets.map(\.frontier), [english, unknown])
        let calls = await catalog.radioRequests
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.filter { $0.id == a.id }.count, 2)
        XCTAssertEqual(calls.filter { $0.id == bFrontier.id }.count, 2)
    }

    func testContinuationStyleFallbackUsesProfileWordingWithoutTheStartingEra() async throws {
        let anchor = RecommendationFixtures.track("anchor", artist: "Anchor", language: .english)
        let frontier = RecommendationFixtures.track("frontier", artist: "Frontier", language: .hindi)
        let station = RadioExperience(id: "older-melancholy", title: "Melancholy", description: "Fixture", symbol: "radio",
            discoveryLanguages: [.english], contentLabel: "English", seeds: [.init(recording: anchor, artist: anchor.credits[0])],
            defaultEra: .older)
        let queries = ["Tamil melancholy songs", "melancholy Tamil music", "melancholy songs in Tamil"]
        let songs = ExperienceRadioFixtures.styleSongs("continuation")
        let catalog = ExperienceRadioCatalogFixture(
            searches: [queries[0]: .success(songs), queries[1]: .success([]), queries[2]: .success([])],
            radios: [anchor.id: .success([]), frontier.id: .success([])],
            playlistSearches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success([])) }))
        let batch = try await ExperienceRadioEngine(catalog: catalog).continueRadio(
            buckets: [.init(anchor: anchor, frontier: frontier)], round: 4, queue: [anchor, frontier], disliked: [],
            languages: [.english], experience: station, languageProfile: profile([.tamil: 100]))

        let searches = await catalog.searchRequests
        let radios = await catalog.radioRequests
        XCTAssertEqual(Set(searches.map(\.query)), Set(queries))
        XCTAssertEqual(searches.count, 6)
        XCTAssertEqual(radios.map(\.id), [anchor.id, frontier.id])
        XCTAssertEqual(batch.tracks, songs)
        XCTAssertEqual(batch.buckets.first?.anchor, anchor)
        XCTAssertEqual(batch.buckets.first?.frontier, songs.last)
    }

    func testFreshContinuationPassesRefreshToBothAnchorAndFrontierWithProfileWeighting() async throws {
        let anchor = RecommendationFixtures.track("anchor", artist: "Anchor", language: .english)
        let frontier = RecommendationFixtures.track("frontier", artist: "Frontier", language: .hindi)
        let english = RecommendationFixtures.track("new-en", artist: "English", language: .english)
        let hindi = RecommendationFixtures.track("new-hi", artist: "Hindi", language: .hindi)
        let catalog = AppModelCatalogProvider()
        addTeardownBlock { await catalog.close() }
        let frozen = profile([.hindi: 100])
        let task = Task {
            try await ExperienceRadioEngine(catalog: catalog).continueRadio(
                buckets: [.init(anchor: anchor, frontier: frontier)], round: 4, queue: [anchor, frontier], disliked: [],
                languages: [.english], forceRefresh: true, languageProfile: frozen)
        }
        defer { task.cancel() }
        let first = try await catalog.autoplayRadios.request(at: 0)
        XCTAssertEqual(first.input, anchor)
        try await catalog.autoplayRadios.complete(first, with: .success([]))
        let second = try await catalog.autoplayRadios.request(at: 1)
        XCTAssertEqual(second.input, frontier)
        try await catalog.autoplayRadios.complete(second, with: .success([english, hindi]))
        let batch = try await task.value
        XCTAssertEqual(batch.tracks, [hindi, english])
        XCTAssertEqual(batch.buckets.first?.frontier, english)
        let refreshes = await catalog.radioRefreshRequests
        let targeted = await catalog.radios.requests
        XCTAssertEqual(refreshes.map(\.forceRefresh), [true, true])
        XCTAssertTrue(targeted.isEmpty)
    }

    func testExhaustedProfileStartupKeepsCueHintPlaylistRadioAndConcurrencyBudgets() async throws {
        let intents = (0..<10).map { RadioExperience.Seed("Cue \($0)", by: "Cue artist \($0)") }
        let cues = intents.enumerated().map { RecommendationFixtures.track("cue-\($0.offset)", title: $0.element.title, artist: $0.element.artist.name) }
        let hints = (0..<7).map { ArtistCredit(name: "Hint artist \($0)", id: "UChint\($0)") }
        let hintSongs = hints.prefix(4).enumerated().map { RecommendationFixtures.track("hint-\($0.offset)", artist: $0.element.name, artistID: $0.element.id) }
        let queries = ["Hindi budget songs", "English budget songs", "Tamil budget mood songs"]
        let station = RadioExperience(id: "budget-mood", title: "Budget mood", description: "Fixture", symbol: "radio",
            discoveryLanguages: [.hindi], contentLabel: "Hindi", seeds: intents, artistHints: hints,
            queryTemplates: [.hindi: [queries[0]], .english: [queries[1]]])
        let playlists = (0..<5).map { MusicCollection(id: "playlist-\($0)", title: "Playlist \($0)", kind: .playlist) }
        var searches: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: zip(intents, cues).map { ($0.query, .success([$1])) })
        for query in queries { searches[query] = .success([]) }
        let artists: [String: Result<ArtistPage, any Error>] = Dictionary(uniqueKeysWithValues: zip(hints.prefix(4), hintSongs).map { artist, song in
            (artist.id!, .success(ArtistPage(id: artist.id!, name: artist.name, topSongs: [song])))
        })
        let catalog = ExperienceRadioCatalogFixture(searches: searches,
            radios: Dictionary(uniqueKeysWithValues: (cues + hintSongs).map { ($0.id, .success([])) }), artists: artists,
            albums: Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, .success(CatalogPage())) }),
            playlistSearches: Dictionary(uniqueKeysWithValues: queries.map { ($0, .success(playlists)) }))
        do {
            _ = try await ExperienceRadioEngine(catalog: catalog).start(station, disliked: [], languages: [],
                languageProfile: profile([.hindi: 50, .english: 30, .tamil: 20]))
            XCTFail("Fixed cues and artist hints alone must not satisfy discovery")
        } catch { XCTAssertEqual(error as? ExperienceRadioError, .unavailable) }

        let searched = await catalog.searchRequests
        let browsed = await catalog.browseRequests
        let artistRequests = await catalog.artistRequests
        let radios = await catalog.radioRequests
        let peak = await catalog.maximumActiveRequests
        XCTAssertEqual(searched.count, 12)
        XCTAssertEqual(searched.filter { $0.filter == .playlists }.count, 3)
        XCTAssertEqual(Set(searched.map(\.query)), Set(intents.prefix(6).map(\.query) + queries))
        XCTAssertEqual(browsed.count, 2)
        XCTAssertEqual(artistRequests.count, 4)
        XCTAssertEqual(radios.count, 10)
        XCTAssertLessThanOrEqual(radios.prefix(4).filter { $0.id.hasPrefix("hint-") }.count, 2)
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 3)
    }

    func testFreshProfileContinuationHonorsTheRealProvidersCooldown() async throws {
        let anchor = CatalogDiscovery.starters(for: .hindi)[0]
        let healthy = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "NJAv_7lHUIU", title: "Kesariya", artist: "Arijit Singh"),
        ]))
        let counter = CatalogTestCounter()
        let clock = CatalogTestClock()
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            guard request.url?.path.hasSuffix("/next") == true else { throw URLError(.unsupportedURL) }
            if counter.increment() == 2 { return CatalogStub(status: 429, headers: ["Retry-After": "60"], data: Data("{}".utf8)) }
            return CatalogStub(data: healthy)
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session, now: { clock.now })
        _ = try await service.radio(seed: anchor)
        let engine = ExperienceRadioEngine(catalog: service)
        let frozen = profile([.hindi: 100])
        for _ in 0..<3 {
            do {
                _ = try await engine.continueRadio(buckets: [.init(anchor: anchor, frontier: anchor)], round: 4,
                    queue: [anchor], disliked: [], languages: [.english], forceRefresh: true, languageProfile: frozen)
                XCTFail("A fresh profile request must honor Retry-After")
            } catch { XCTAssertEqual(error as? ExperienceRadioError, .unavailable) }
        }
        XCTAssertEqual(mock.state.requests.filter { $0.url?.path.hasSuffix("/next") == true }.count, 2)
        clock.advance(61)
        let recovered = try await engine.continueRadio(buckets: [.init(anchor: anchor, frontier: anchor)], round: 4,
            queue: [anchor], disliked: [], languages: [.english], forceRefresh: true, languageProfile: frozen)
        XCTAssertEqual(recovered.tracks.map(\.id), ["NJAv_7lHUIU"])
        XCTAssertEqual(mock.state.requests.filter { $0.url?.path.hasSuffix("/next") == true }.count, 3)
    }

    private func station(_ id: String = "melancholy") throws -> RadioExperience {
        try XCTUnwrap(RadioExperience.stations.first { $0.id == id })
    }

    private func profile(_ plays: [ArtistSongLanguage: Int], nudges: LanguageRecommendationNudges = .init(),
                         evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [:],
                         overrides: [String: String] = [:]) -> ListeningLanguageProfile {
        let total = plays.values.reduce(0, +)
        let rows = ArtistSongLanguage.allCases.compactMap { language -> LanguageListeningStat? in
            guard let count = plays[language], count > 0 else { return nil }
            return LanguageListeningStat(language: language, plays: count, songs: 1, share: Double(count) / Double(total))
        }
        return ListeningLanguageProfile(summary: ListeningLanguageSummary(rows: rows, totalPlays: total, totalSongs: rows.count),
                                        nudges: nudges, evidence: evidence, overrides: overrides)
    }
}
