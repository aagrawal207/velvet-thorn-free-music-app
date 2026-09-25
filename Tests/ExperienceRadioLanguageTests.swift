import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class ExperienceRadioLanguageTests: XCTestCase {
    func testDiscoveryListsEveryStationForEveryLanguagePreference() throws {
        let expected = RadioExperience.discoveryStations.map(\.id)
        XCTAssertEqual(expected.count, RadioExperience.stations.count)
        let moods = RadioExperience.stations.filter { $0.group == .moods }.count
        XCTAssertTrue(RadioExperience.discoveryStations.prefix(moods).allSatisfy { $0.group == .moods })
        XCTAssertTrue(RadioExperience.discoveryStations.dropFirst(moods).allSatisfy { $0.group == .genres })
        XCTAssertEqual(Array(expected.prefix(2)), ["melancholy", "hindi-gym"])
        for languages in [[.english], [.hindi], [.hindi, .english]] as [Set<MusicLanguage>] {
            let context = try AppModelTestContext(languages: languages)
            addTeardownBlock { @MainActor in try await context.close() }
            XCTAssertEqual(context.model.radioExperiences.map(\.id), expected, "\(languages)")
            for station in context.model.radioExperiences {
                XCTAssertNotNil(station.selection(for: languages), "\(station.id) must have a selection for \(languages)")
            }
        }
    }

    func testMixedStationChoosesSeedGroupsAndCopyForTheSelectedLanguages() throws {
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "left-field-rap" })
        let english = try XCTUnwrap(station.selection(for: [.english]))
        let hindi = try XCTUnwrap(station.selection(for: [.hindi]))
        let combined = try XCTUnwrap(station.selection(for: [.english, .hindi]))
        XCTAssertEqual(english.seeds.map(\.artist.name), ["Kanye West", "Tyler, The Creator"])
        XCTAssertEqual(hindi.seeds.map(\.artist.name), ["Char Diwaari", "Seedhe Maut"])
        XCTAssertEqual(combined.seeds.map(\.artist.name), ["Kanye West", "Char Diwaari", "Tyler, The Creator", "Seedhe Maut"])
        XCTAssertEqual(english.contentLabel, "English")
        XCTAssertEqual(hindi.contentLabel, "Hindi")
        XCTAssertEqual(combined.contentLabel, "Hindi + English")
        XCTAssertFalse(english.description.contains("Char Diwaari"))
        XCTAssertFalse(hindi.description.contains("Kanye West"))
        XCTAssertEqual(combined.description, station.description)
        XCTAssertEqual(english.styleQueries, station.styleQueries(for: .english))
        XCTAssertEqual(hindi.styleQueries, station.styleQueries(for: .hindi))
        XCTAssertEqual(Array(combined.styleQueries.prefix(3)),
                       [station.styleQueries(for: .hindi)[0], station.styleQueries(for: .english)[0], station.styleQueries(for: .hindi)[1]])
        XCTAssertNil(station.selection(for: []))
    }

    func testEnglishAndHindiStartsNeverSearchSeedsFromTheOtherVariant() async throws {
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "left-field-rap" })
        let songs = [
            RecommendationFixtures.track("kanye", title: "Flashing Lights", artist: "Kanye West", language: .english),
            RecommendationFixtures.track("tyler", title: "EARFQUAKE", artist: "Tyler, The Creator", language: .english),
            RecommendationFixtures.track("char", title: "Jhaag", artist: "Char Diwaari", language: .hindi),
            RecommendationFixtures.track("seedhe", title: "Nanchaku", artist: "Seedhe Maut", language: .hindi),
        ]
        let searches: [String: Result<[Track], any Error>] = [
            "Flashing Lights Kanye West": .success([songs[0]]), "EARFQUAKE Tyler, The Creator": .success([songs[1]]),
            "Jhaag Char Diwaari": .success([songs[2]]), "Nanchaku Seedhe Maut": .success([songs[3]]),
        ]
        let radios: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: songs.map { song in
            (song.id, .success([RecommendationFixtures.track("neighbor-\(song.id)", artist: "Neighbor \(song.id)", language: song.language)]))
        })
        let cases: [(Set<MusicLanguage>, Set<String>)] = [
            ([.english], ["Flashing Lights Kanye West", "EARFQUAKE Tyler, The Creator"]),
            ([.hindi], ["Jhaag Char Diwaari", "Nanchaku Seedhe Maut"]),
            ([.english, .hindi], Set(searches.keys)),
        ]
        for (languages, expectedQueries) in cases {
            let catalog = ExperienceRadioCatalogFixture(searches: searches, radios: radios)
            let batch = try await ExperienceRadioEngine(catalog: catalog).start(station, disliked: [], languages: languages)
            let requests = await catalog.searchRequests
            XCTAssertEqual(Set(requests.map(\.query)), expectedQueries)
            XCTAssertTrue(requests.allSatisfy { $0.filter == .songs && $0.continuation == nil })
            XCTAssertGreaterThanOrEqual(batch.tracks.count, 4)
            XCTAssertTrue(batch.tracks.allSatisfy { $0.language.map(languages.contains) ?? true })
        }
    }

    func testEnglishOnlyListenerStartsAHindiCuedStationThroughStyleSearchesAlone() async throws {
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "hindi-gym" })
        let wording: Set<String> = ["workout motivation songs", "gym hip hop english songs", "high energy running songs"]
        for learned in [false, true] {
            let old = libraryTestTrack("already-playing")
            let context = try AppModelTestContext(languages: [.english], snapshot: PlaybackSnapshot(queue: [old], position: 25))
            addTeardownBlock { @MainActor in context.model.cancelPendingRadio(); try await context.close() }
            if learned { context.seedHistory(RecommendationFixtures.track("heard-english", language: .english)) }
            XCTAssertEqual(context.model.listeningLanguageProfile.isLearned, learned)
            let songs = ExperienceRadioFixtures.styleSongs("workout", language: .english)
            let task = context.model.startRadio(station)
            let answered = try await ExperienceRadioFixtures.answerStyleSearches(context, from: 0, count: 6, songs: songs, expecting: wording)
            XCTAssertEqual(Set(answered.map(\.query)), wording, "Only station wording is searched; Hindi cues stay out")
            XCTAssertEqual(answered.filter { $0.filter == .songs }.count, 3)
            XCTAssertEqual(answered.filter { $0.filter == .playlists }.count, 3)
            XCTAssertEqual(context.player.queue, [old])
            XCTAssertEqual(context.player.position, 25)
            let neighbors = Dictionary(uniqueKeysWithValues: songs.map { song in
                (song.id, [RecommendationFixtures.track("near-\(song.id)", artist: "Near \(song.id)", language: .english)])
            })
            for index in 0..<4 {
                let request = try await context.catalog.autoplayRadios.request(at: index)
                let tracks = try XCTUnwrap(neighbors[request.input.id], "Style songs anchor the radio lanes")
                try await context.catalog.autoplayRadios.complete(request, with: .success(tracks))
            }
            await task.value
            XCTAssertNil(context.model.radioError)
            XCTAssertEqual(context.model.activeRadioExperience, station)
            XCTAssertEqual(context.model.activeRadioContentLabel, learned ? "Follows your listening" : "Automatic discovery")
            XCTAssertTrue(context.player.isRadioSession)
            XCTAssertGreaterThanOrEqual(context.player.queue.count, ExperienceRadioEngine.minimumQueueSize)
            XCTAssertTrue(Set(songs).isSubset(of: Set(context.player.queue)))
            XCTAssertFalse(context.player.queue.contains(old))
            let searches = await context.catalog.searches.requests
            let radios = await context.catalog.autoplayRadios.requests
            XCTAssertEqual(searches.count, 6)
            XCTAssertEqual(radios.count, 4)
            XCTAssertFalse(searches.contains { request in station.seeds.contains { $0.query == request.input.query } })
        }
    }

    func testColdCueOnlyStationUsesAnotherActiveLanguagesCuesAfterEmptyStyleDiscovery() async throws {
        let f = ExperienceRadioFixtures.self
        let profile = ListeningLanguageProfile()
        let wording = ["English fixture gym songs", "Hindi fixture gym songs", "fixture gym English music"]
        XCTAssertFalse(profile.isLearned)
        XCTAssertEqual(profile.orderedLanguages.first, .english)
        XCTAssertTrue(f.gym.styleQueries.isEmpty)
        XCTAssertTrue(f.gym.selection(for: profile).seeds.isEmpty)
        var searches = f.gymSearches.mapValues { Result<[Track], any Error>.success([$0]) }
        for query in wording { searches[query] = .success([]) }
        let catalog = ExperienceRadioCatalogFixture(searches: searches, radios: f.gymRadios.mapValues { .success($0) },
            playlistSearches: Dictionary(uniqueKeysWithValues: wording.map { ($0, .success([])) }))

        let batch = try await ExperienceRadioEngine(catalog: catalog).start(f.gym, disliked: [], languages: [], languageProfile: profile)
        let requested = await catalog.searchRequests
        let radios = await catalog.radioRequests
        let peak = await catalog.maximumActiveRequests
        XCTAssertEqual(requested.count, 8)
        XCTAssertEqual(Set(requested.prefix(6).map(\.query)), Set(wording))
        XCTAssertEqual(requested.prefix(6).filter { $0.filter == .songs }.count, 3)
        XCTAssertEqual(requested.prefix(6).filter { $0.filter == .playlists }.count, 3)
        XCTAssertEqual(Set(requested.suffix(2).map(\.query)), Set(f.gymSearches.keys))
        XCTAssertEqual(Set(radios.map(\.id)), [f.zinda.id, f.goat.id])
        XCTAssertEqual(batch.tracks, [f.zinda, f.goat, f.sultan, f.punjabi])
        XCTAssertEqual(batch.buckets.map(\.frontier), [f.sultan, f.punjabi])
        XCTAssertEqual(batch.discoveryTrackIDs, [f.sultan.id, f.punjabi.id])
        XCTAssertEqual(f.gym.selection(for: profile).contentLabel, "Automatic discovery")
        XCTAssertNil(batch.tracks.first { $0.id == f.punjabi.id }?.language)
        XCTAssertLessThanOrEqual(peak, 3)
    }

    func testColdCueBackupCannotBorrowAnInactiveLanguage() async throws {
        let f = ExperienceRadioFixtures.self
        let wording = ["English fixture gym songs", "fixture gym English music", "fixture gym songs in English"]
        var searches = f.gymSearches.mapValues { Result<[Track], any Error>.success([$0]) }
        for query in wording { searches[query] = .success([]) }
        let catalog = ExperienceRadioCatalogFixture(searches: searches, radios: f.gymRadios.mapValues { .success($0) },
            playlistSearches: Dictionary(uniqueKeysWithValues: wording.map { ($0, .success([])) }))
        do {
            _ = try await ExperienceRadioEngine(catalog: catalog).start(f.gym, disliked: [], languages: [],
                languageProfile: ListeningLanguageProfile(fallback: [.english]))
            XCTFail("Hindi is not an active fallback target")
        } catch { XCTAssertEqual(error as? ExperienceRadioError, .noSeeds) }
        let requested = await catalog.searchRequests
        let radios = await catalog.radioRequests
        XCTAssertEqual(requested.count, 6)
        XCTAssertEqual(Set(requested.map(\.query)), Set(wording))
        XCTAssertTrue(radios.isEmpty)
    }

    func testColdBackupCuesShareTheSixSearchBudgetWithUnresolvedDominantCues() async throws {
        let english = (0..<2).map { RadioExperience.Seed("English cue \($0)", by: "English artist \($0)") }
        let hindi = (0..<8).map { RadioExperience.Seed("Hindi cue \($0)", by: "Hindi artist \($0)") }
        let tracks = hindi.enumerated().map {
            RecommendationFixtures.track("hindi-\($0.offset)", title: $0.element.title, artist: $0.element.artist.name, language: .hindi)
        }
        let station = RadioExperience(id: "cold-cue-budget", title: "Cold cue budget", description: "Fixture", symbol: "radio", group: .moods,
            variants: [.init(id: "english", discoveryLanguages: [.english], contentLabel: "English", seeds: english),
                       .init(id: "hindi", discoveryLanguages: [.hindi], contentLabel: "Hindi", seeds: hindi)])
        let wording = ["English cold cue budget songs", "Hindi cold cue budget songs", "cold cue budget English music"]
        var searches: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: zip(hindi, tracks).map { ($0.query, .success([$1])) })
        for query in english.map(\.query) + wording { searches[query] = .success([]) }
        let radios: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: tracks.map { track in
            (track.id, .success([RecommendationFixtures.track("near-\(track.id)", artist: "Neighbor \(track.id)")]))
        })
        let catalog = ExperienceRadioCatalogFixture(searches: searches, radios: radios,
            playlistSearches: Dictionary(uniqueKeysWithValues: wording.map { ($0, .success([])) }))
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(
            station, disliked: [], languages: [], languageProfile: ListeningLanguageProfile())

        let requested = await catalog.searchRequests
        let radioRequests = await catalog.radioRequests
        XCTAssertEqual(requested.count, 12, "Six cue searches and six style requests share one startup budget")
        XCTAssertEqual(Set(requested.prefix(2).map(\.query)), Set(english.map(\.query)))
        XCTAssertEqual(Set(requested.dropFirst(2).prefix(6).map(\.query)), Set(wording))
        XCTAssertEqual(Set(requested.suffix(4).map(\.query)), Set(hindi.prefix(4).map(\.query)))
        XCTAssertEqual(Set(radioRequests.map(\.id)), Set(tracks.prefix(4).map(\.id)))
        XCTAssertEqual(batch.buckets.count, 4)
        XCTAssertEqual(batch.tracks.count, 8)
        XCTAssertFalse(batch.discoveryTrackIDs.isEmpty)
    }

    func testKnownIncompatibleTracksAreFilteredButUnknownLanguageStaysEligible() throws {
        let english = RecommendationFixtures.track("english", title: "English neighbor", language: .english)
        let hindi = RecommendationFixtures.track("hindi", title: "Hindi neighbor", language: .hindi)
        let punjabi = ExperienceRadioFixtures.punjabi
        let tracks = [[english, hindi, punjabi]]
        XCTAssertEqual(ExperienceRadioEngine.selection(buckets: tracks, disliked: [], languages: [.english]).tracks, [english, punjabi])
        XCTAssertEqual(ExperienceRadioEngine.selection(buckets: tracks, disliked: [], languages: [.hindi]).tracks, [hindi, punjabi])
        XCTAssertEqual(ExperienceRadioEngine.selection(buckets: tracks, disliked: [], languages: [.english, .hindi]).tracks, [english, hindi, punjabi])
        XCTAssertNil(punjabi.language)
        let gym = try XCTUnwrap(RadioExperience.stations.first { $0.id == "hindi-gym" })
        let drive = try XCTUnwrap(RadioExperience.stations.first { $0.id == "punjabi-drive" })
        XCTAssertEqual(gym.selection(for: [.hindi])?.contentLabel, "Hindi + Punjabi")
        XCTAssertEqual(gym.selection(for: [.hindi, .english])?.contentLabel, "Hindi + Punjabi + English")
        XCTAssertEqual(drive.selection(for: [.hindi])?.contentLabel, "Punjabi")
        XCTAssertEqual(drive.selection(for: [.english])?.contentLabel, "English")
    }

    func testOtherLanguageSetupSearchesWordingOnlyAndNeverRetagsHindiCues() async throws {
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "hindi-gym" })
        let cues = station.seeds.enumerated().map {
            RecommendationFixtures.track("unclassified-cue-\($0.offset)", title: $0.element.title, artist: $0.element.artist.name)
        }
        let neighbors = (0..<4).map { RecommendationFixtures.track("unclassified-neighbor-\($0)", artist: "Neighbor \($0)") }
        let searches: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: zip(station.seeds, cues).map {
            ($0.query, .success([$1]))
        })
        let radios: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: zip(cues, neighbors).map {
            ($0.id, .success([$1]))
        })
        let catalog = ExperienceRadioCatalogFixture(searches: searches, radios: radios)
        let engine = ExperienceRadioEngine(catalog: catalog)
        let english = RadioConfiguration(station: station, languages: [.english]).experience()
        do {
            _ = try await engine.start(english, disliked: [], languages: [.english])
            XCTFail("The fixture answers no English wording, so this start has nothing to anchor")
        } catch { XCTAssertEqual(error as? ExperienceRadioError, .noSeeds) }
        let englishSearches = await catalog.searchRequests
        let englishRadios = await catalog.radioRequests
        XCTAssertEqual(Set(englishSearches.map(\.query)), Set(station.styleQueries(in: [.english]).prefix(3)),
                       "Hindi cue recordings are never searched for an English-only session")
        XCTAssertTrue(englishRadios.isEmpty)

        let supported = RadioConfiguration(station: station, languages: [.hindi]).experience()
        let batch = try await engine.start(supported, disliked: [], languages: [.hindi])
        XCTAssertTrue(supported.artistHints.isEmpty)
        XCTAssertEqual(batch.buckets.map(\.anchor.id), cues.map(\.id))
        XCTAssertEqual(batch.tracks.count, 8)
        XCTAssertTrue(batch.tracks.allSatisfy { $0.language == nil }, "Audience tags must not label the actual recordings")
    }

    func testContinuationDoesNotUseAKnownIncompatibleFrontierAsASeed() async throws {
        let a = RecommendationFixtures.track("anchor-a", title: "Anchor A", language: .english)
        let b = RecommendationFixtures.track("anchor-b", title: "Anchor B", language: .english)
        let incompatible = RecommendationFixtures.track("wrong-frontier", title: "Hindi frontier", language: .hindi)
        let nextA = RecommendationFixtures.track("next-a", title: "Next A", language: .english)
        let nextB = RecommendationFixtures.track("next-b", title: "Next B")
        let catalog = ExperienceRadioCatalogFixture(radios: [a.id: .success([nextA, incompatible]), b.id: .success([nextB])])
        let batch = try await ExperienceRadioEngine(catalog: catalog).continueRadio(
            buckets: [.init(anchor: a, frontier: a), .init(anchor: b, frontier: incompatible)], round: 0,
            queue: [a, b, incompatible], disliked: [], languages: [.english])
        XCTAssertEqual(batch.tracks, [nextA, nextB])
        let requests = await catalog.radioRequests
        XCTAssertEqual(Set(requests.map(\.id)), [a.id, b.id])
    }

    func testEmptyLanguageSetIsTheOnlyRejectedStart() async throws {
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "melancholy" })
        let catalog = ExperienceRadioCatalogFixture()
        do {
            _ = try await ExperienceRadioEngine(catalog: catalog).start(station, disliked: [], languages: [])
            XCTFail("An empty language set has no wording to search")
        } catch { XCTAssertEqual(error as? ExperienceRadioError, .noLanguages) }
        let searches = await catalog.searchRequests
        let radios = await catalog.radioRequests
        XCTAssertTrue(searches.isEmpty && radios.isEmpty)
        XCTAssertEqual(ExperienceRadioError.noLanguages.errorDescription, "Choose at least one language to start this radio.")
    }
}
