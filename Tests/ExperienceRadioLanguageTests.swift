import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class ExperienceRadioLanguageTests: XCTestCase {
    func testDiscoveryListsFollowEnglishHindiAndCombinedPreferences() throws {
        let cases: [(Set<MusicLanguage>, [String])] = [
            ([.english], ["melancholy", "english-golden-oldies", "alt-rock", "easy-morning", "left-field-rap"]),
            ([.hindi], ["hindi-gym", "hindi-classics", "late-night-hindi", "punjabi-drive", "indian-indie", "left-field-rap"]),
            ([.hindi, .english], ["melancholy", "hindi-gym", "hindi-classics", "english-golden-oldies", "late-night-hindi", "punjabi-drive", "indian-indie", "alt-rock", "easy-morning", "left-field-rap"]),
        ]
        for (languages, expected) in cases {
            let context = try AppModelTestContext(languages: languages)
            addTeardownBlock { @MainActor in try await context.close() }
            XCTAssertEqual(context.model.radioExperiences.map(\.id), expected)
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
        XCTAssertEqual(combined.contentLabel, "English + Hindi")
        XCTAssertFalse(english.description.contains("Char Diwaari"))
        XCTAssertFalse(hindi.description.contains("Kanye West"))
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

    func testEnglishOnlyModelRejectsAHiddenHindiStationBeforeAnySeedQuery() async throws {
        let old = libraryTestTrack("already-playing")
        let context = try AppModelTestContext(languages: [.english], snapshot: PlaybackSnapshot(queue: [old], position: 25))
        addTeardownBlock { @MainActor in context.model.cancelPendingRadio(); try await context.close() }
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "hindi-gym" })
        await context.model.startRadio(station).value
        let searches = await context.catalog.searches.requests
        let radios = await context.catalog.autoplayRadios.requests
        XCTAssertTrue(searches.isEmpty && radios.isEmpty)
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 25)
        XCTAssertFalse(context.model.isLoadingRadio)
        XCTAssertNotNil(context.model.radioError)
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
        XCTAssertEqual(drive.selection(for: [.hindi])?.contentLabel, "Punjabi")
    }

    func testDisjointSetupCannotVendUnclassifiedHindiGymRecordingsAsEnglish() async throws {
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
        let unsupported = RadioConfiguration(station: station, languages: [.english]).experience()
        do {
            _ = try await engine.start(unsupported, disliked: [], languages: [.english])
            XCTFail("Unclassified recording metadata must not let a station change its supported audience")
        } catch { XCTAssertEqual(error as? ExperienceRadioError, .noMatchingLanguages) }
        let rejectedSearches = await catalog.searchRequests
        let rejectedRadios = await catalog.radioRequests
        XCTAssertTrue(rejectedSearches.isEmpty && rejectedRadios.isEmpty)

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
}
