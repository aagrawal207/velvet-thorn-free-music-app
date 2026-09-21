import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class ExperienceRadioClassicsTests: XCTestCase {
    func testClassicsUseRecognizableRecordingsWithDistinctCreditedArtistsAndLanguageTags() throws {
        let hindi = try station("hindi-classics")
        XCTAssertEqual(hindi.discoveryLanguages, [.hindi])
        XCTAssertEqual(hindi.selection(for: [.hindi])?.contentLabel, "Hindi")
        XCTAssertEqual(hindi.seeds.map(\.title), ["Lag Ja Gale Se Phir", "Yeh Sham Mastani", "Kabhi Kabhie Mere Dil Mein", "Chaudhvin Ka Chand Ho"])
        XCTAssertEqual(hindi.seeds.map(\.artist.name), ["Lata Mangeshkar", "Kishore Kumar", "Mukesh", "Mohammed Rafi"])

        let english = try station("english-golden-oldies")
        XCTAssertEqual(english.discoveryLanguages, [.english])
        XCTAssertEqual(english.selection(for: [.english])?.contentLabel, "English")
        XCTAssertEqual(english.seeds.map(\.title), ["Here Comes The Sun", "Can't Help Falling in Love", "Fly Me To The Moon (In Other Words)", "Stand By Me"])
        XCTAssertEqual(english.seeds.map(\.artist.name), ["The Beatles", "Elvis Presley", "Frank Sinatra", "Ben E. King"])
        for experience in [hindi, english] {
            XCTAssertGreaterThanOrEqual(Set(experience.seeds.map(\.artist.name)).count, 2)
            XCTAssertTrue(experience.seeds.allSatisfy { $0.artist.id == nil })
            XCTAssertNotNil(experience.selection(for: [.hindi, .english]))
        }
    }

    func testStandardClassicRecordingMetadataMatchesWhileCoversAndVideoDoNot() throws {
        for id in ["hindi-classics", "english-golden-oldies"] {
            let experience = try station(id)
            for (query, recording) in try recordingSearches(id) {
                let seed = try XCTUnwrap(experience.seeds.first { $0.query == query })
                var cover = recording
                cover.id += "-cover"
                cover.credits = [ArtistCredit(name: "A tribute band")]
                var video = recording
                video.id += "-video"
                video.isAudioRecording = false
                XCTAssertNil(ExperienceRadioEngine.matchedSeed(seed, in: [cover, video], disliked: [], languages: experience.discoveryLanguages))
                XCTAssertEqual(ExperienceRadioEngine.matchedSeed(seed, in: [cover, video, recording], disliked: [],
                                                                languages: experience.discoveryLanguages), recording)
            }
        }
    }

    func testClassicStationsResolveSongSeedsAndContinueThroughFreshProviderRadio() async throws {
        for id in ["hindi-classics", "english-golden-oldies"] {
            let experience = try station(id)
            let searches = try recordingSearches(id)
            var radios: [String: Result<[Track], any Error>] = [:]
            for recording in searches.values {
                let neighbor = RecommendationFixtures.track("neighbor-\(recording.id)", title: "Radio fixture \(recording.id)",
                    artist: recording.artistName, language: recording.language)
                let next = RecommendationFixtures.track("next-\(recording.id)", title: "Continuation fixture \(recording.id)",
                    artist: recording.artistName, language: recording.language)
                radios[recording.id] = .success([neighbor])
                radios[neighbor.id] = .success([next])
            }
            let catalog = ExperienceRadioCatalogFixture(searches: searches.mapValues { .success([$0]) }, radios: radios)
            let engine = ExperienceRadioEngine(catalog: catalog)
            let initial = try await engine.start(experience, disliked: [], languages: experience.discoveryLanguages)
            let searchRequests = await catalog.searchRequests
            let firstRadios = await catalog.radioRequests
            XCTAssertEqual(Set(searchRequests.map(\.query)), Set(searches.keys))
            XCTAssertTrue(searchRequests.allSatisfy { $0.filter == .songs && $0.continuation == nil })
            XCTAssertEqual(Set(firstRadios.map(\.id)), Set(searches.values.map(\.id)))
            XCTAssertEqual(initial.buckets.count, 4)
            XCTAssertTrue(initial.tracks.contains { $0.id.hasPrefix("neighbor-") })
            XCTAssertTrue(initial.tracks.allSatisfy { $0.isAudioRecording == true })

            let next = try await engine.continueRadio(buckets: initial.buckets, round: 0, queue: initial.tracks,
                                                      disliked: [], languages: experience.discoveryLanguages)
            XCTAssertFalse(next.tracks.isEmpty)
            XCTAssertTrue(next.tracks.allSatisfy { $0.id.hasPrefix("next-") })
            XCTAssertTrue(Set(next.tracks.map(\.id)).isDisjoint(with: initial.tracks.map(\.id)))
            let targeted = await catalog.targetedRadioRequests
            XCTAssertEqual(targeted, 0)
        }
    }

    func testClassicsArePromotedWithoutChangingExistingDebugSeedIndices() throws {
        XCTAssertEqual(Array(RadioExperience.discoveryStations.prefix(4)).map(\.id),
                       ["melancholy", "hindi-gym", "hindi-classics", "english-golden-oldies"])
        XCTAssertEqual(Array(RadioExperience.stations.suffix(2)).map(\.id), ["hindi-classics", "english-golden-oldies"])
        let fixtures = DebugMusicFixtures.experienceTracks
        for (index, title) in [(0, "Apocalypse"), (4, "Zinda"), (28, "Flashing Lights"), (29, "Jhaag"),
                               (30, "EARFQUAKE"), (31, "Nanchaku"), (32, "Lag Ja Gale Se Phir"), (36, "Here Comes The Sun")] {
            XCTAssertEqual(fixtures.first { $0.id == "fixture.experience.seed.\(index)" }?.title, title)
        }
    }

    func testClassicStationsOutsideTheSelectedAudienceMakeNoCatalogRequests() async throws {
        let cases: [(String, Set<MusicLanguage>)] = [("hindi-classics", [.english]), ("english-golden-oldies", [.hindi])]
        for (id, languages) in cases {
            let catalog = ExperienceRadioCatalogFixture()
            let experience = try station(id)
            do {
                _ = try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [], languages: languages)
                XCTFail("A classic station must honor the listener's discovery languages")
            } catch { XCTAssertEqual(error as? ExperienceRadioError, .noMatchingLanguages) }
            let searches = await catalog.searchRequests
            let radios = await catalog.radioRequests
            XCTAssertTrue(searches.isEmpty && radios.isEmpty)
        }
    }

    private func station(_ id: String) throws -> RadioExperience {
        try XCTUnwrap(RadioExperience.stations.first { $0.id == id })
    }

    private func recordingSearches(_ id: String) throws -> [String: Track] {
        let examples: [String: [String: Track]] = [
            "hindi-classics": [
                "Lag Ja Gale Se Phir Lata Mangeshkar": RecommendationFixtures.track("classic-lata", title: "Lag Ja Gale Se Phir (From \"Woh Kaun Thi?\")", artist: "Lata Mangeshkar", language: .hindi),
                "Yeh Sham Mastani Kishore Kumar": RecommendationFixtures.track("classic-kishore", title: "Yeh Sham Mastani", artist: "Kishore Kumar", language: .hindi),
                "Kabhi Kabhie Mere Dil Mein Mukesh": RecommendationFixtures.track("classic-mukesh", title: "Kabhi Kabhie Mere Dil Mein (Solo)", artist: "Mukesh", language: .hindi),
                "Chaudhvin Ka Chand Ho Mohammed Rafi": RecommendationFixtures.track("classic-rafi", title: "Chaudhvin Ka Chand Ho", artist: "Mohammed Rafi", language: .hindi),
            ],
            "english-golden-oldies": [
                "Here Comes The Sun The Beatles": RecommendationFixtures.track("classic-beatles", title: "Here Comes The Sun (Remastered 2009)", artist: "The Beatles", language: .english),
                "Can't Help Falling in Love Elvis Presley": RecommendationFixtures.track("classic-elvis", title: "Can’t Help Falling in Love", artist: "Elvis Presley", language: .english),
                "Fly Me To The Moon (In Other Words) Frank Sinatra": RecommendationFixtures.track("classic-sinatra", title: "Fly Me To The Moon (In Other Words) (2008 Remaster)", artist: "Frank Sinatra", language: .english),
                "Stand By Me Ben E. King": RecommendationFixtures.track("classic-ben", title: "Stand By Me (Remastered)", artist: "Ben E. King", language: .english),
            ],
        ]
        return try XCTUnwrap(examples[id])
    }
}
