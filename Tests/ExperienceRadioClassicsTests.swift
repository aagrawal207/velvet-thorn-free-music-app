import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class ExperienceRadioClassicsTests: XCTestCase {
    func testClassicsUseRecognizableRecordingsWithDistinctCreditedArtistsAndLanguageTags() throws {
        let hindi = try station("hindi-classics")
        XCTAssertEqual(hindi.title, "Bollywood classics")
        XCTAssertEqual(hindi.cueLanguages, [.hindi])
        XCTAssertEqual(hindi.selection(for: [.hindi])?.contentLabel, "Hindi")
        XCTAssertEqual(hindi.seeds.map(\.title), ["Lag Ja Gale Se Phir", "Yeh Sham Mastani", "Kabhi Kabhie Mere Dil Mein", "Chaudhvin Ka Chand Ho"])
        XCTAssertEqual(hindi.seeds.map(\.artist.name), ["Lata Mangeshkar", "Kishore Kumar", "Mukesh", "Mohammed Rafi"])

        let english = try station("english-golden-oldies")
        XCTAssertEqual(english.title, "Golden oldies")
        XCTAssertEqual(english.cueLanguages, [.english])
        XCTAssertEqual(english.selection(for: [.english])?.contentLabel, "English")
        XCTAssertEqual(english.seeds.map(\.title), ["Here Comes The Sun", "Can't Help Falling in Love", "Fly Me To The Moon (In Other Words)", "Stand By Me"])
        XCTAssertEqual(english.seeds.map(\.artist.name), ["The Beatles", "Elvis Presley", "Frank Sinatra", "Ben E. King"])
        for experience in [hindi, english] {
            XCTAssertEqual(experience.group, .genres)
            XCTAssertEqual(experience.defaultEra, .older)
            XCTAssertGreaterThanOrEqual(Set(experience.seeds.map(\.artist.name)).count, 2)
            XCTAssertTrue(experience.seeds.allSatisfy { $0.artist.id == nil })
            XCTAssertNotNil(experience.selection(for: [.hindi, .english]))
            for language in MusicLanguage.allCases {
                XCTAssertGreaterThanOrEqual(experience.styleQueries(for: language).count, 2, "\(experience.id) \(language)")
            }
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
                XCTAssertNil(ExperienceRadioEngine.matchedSeed(seed, in: [cover, video], disliked: [], languages: experience.cueLanguages))
                XCTAssertEqual(ExperienceRadioEngine.matchedSeed(seed, in: [cover, video, recording], disliked: [],
                                                                languages: experience.cueLanguages), recording)
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
            let initial = try await engine.start(experience, disliked: [], languages: experience.cueLanguages)
            let searchRequests = await catalog.searchRequests
            let firstRadios = await catalog.radioRequests
            XCTAssertEqual(Set(searchRequests.map(\.query)), Set(searches.keys))
            XCTAssertTrue(searchRequests.allSatisfy { $0.filter == .songs && $0.continuation == nil })
            XCTAssertEqual(Set(firstRadios.map(\.id)), Set(searches.values.map(\.id)))
            XCTAssertEqual(initial.buckets.count, 4)
            XCTAssertTrue(initial.tracks.contains { $0.id.hasPrefix("neighbor-") })
            XCTAssertTrue(initial.tracks.allSatisfy { $0.isAudioRecording == true })

            let next = try await engine.continueRadio(buckets: initial.buckets, round: 0, queue: initial.tracks,
                                                      disliked: [], languages: experience.cueLanguages)
            XCTAssertFalse(next.tracks.isEmpty)
            XCTAssertTrue(next.tracks.allSatisfy { $0.id.hasPrefix("next-") })
            XCTAssertTrue(Set(next.tracks.map(\.id)).isDisjoint(with: initial.tracks.map(\.id)))
            let targeted = await catalog.targetedRadioRequests
            XCTAssertEqual(targeted, 0)
        }
    }

    func testClassicsSitInGenresAndDebugSeedFixturesAreKeyedByQueryNotPosition() throws {
        let discovery = RadioExperience.discoveryStations
        XCTAssertEqual(Array(discovery.prefix(2)).map(\.id), ["melancholy", "hindi-gym"])
        let genres = discovery.filter { $0.group == .genres }.map(\.id)
        XCTAssertTrue(genres.contains("hindi-classics") && genres.contains("english-golden-oldies"))
        let classics = try XCTUnwrap(discovery.firstIndex { $0.id == "hindi-classics" })
        let lastMood = try XCTUnwrap(discovery.lastIndex { $0.group == .moods })
        XCTAssertGreaterThan(classics, lastMood, "Genres follow every mood tile")

        let fixtures = DebugMusicFixtures.experienceTracks
        XCTAssertEqual(fixtures.count, RadioExperience.stations.flatMap(\.seeds).count)
        XCTAssertEqual(Set(fixtures.map(\.id)).count, fixtures.count, "Seed queries slug to distinct fixture ids")
        for (slug, title) in [("apocalypse-cigarettes-after-sex", "Apocalypse"), ("zinda-siddharth-mahadevan-bhaag-milkha-bhaag", "Zinda"),
                              ("flashing-lights-kanye-west", "Flashing Lights"), ("jhaag-char-diwaari", "Jhaag"),
                              ("earfquake-tyler-the-creator", "EARFQUAKE"), ("nanchaku-seedhe-maut", "Nanchaku"),
                              ("lag-ja-gale-se-phir-lata-mangeshkar", "Lag Ja Gale Se Phir"), ("here-comes-the-sun-the-beatles", "Here Comes The Sun"),
                              ("g-o-a-t-diljit-dosanjh", "G.O.A.T."), ("where-is-my-mind-pixies", "Where Is My Mind?")] {
            XCTAssertEqual(fixtures.first { $0.id == "fixture.experience.seed.\(slug)" }?.title, title, slug)
            XCTAssertEqual(DebugMusicFixtures.experienceSeed(slug: slug)?.title, title, slug)
        }
        XCTAssertEqual(DebugMusicFixtures.slug("Can't Help Falling in Love Elvis Presley"), "can-t-help-falling-in-love-elvis-presley")
        XCTAssertEqual(DebugMusicFixtures.slug("  R&B  and soul  "), "r-b-and-soul")
    }

    func testDebugFixturesAnswerStationWordingWithDistinctUsableSongsAndRadio() async throws {
        let fixtures = DebugMusicFixtures()
        let melancholy = try station("melancholy")
        let query = try XCTUnwrap(melancholy.styleQueries(in: [.hindi]).first)
        for suffix in RadioEra.allCases.map(\.styleQuerySuffix) {
            let page = try await fixtures.search(query: query + suffix, filter: .songs, continuation: nil)
            XCTAssertEqual(page.tracks.count, 6, suffix)
            XCTAssertEqual(page.tracks.map(\.id), (0..<6).map { "fixture.style.\(DebugMusicFixtures.slug(query)).\($0)" })
            XCTAssertEqual(Set(page.tracks.map(\.artistName)).count, 6)
            XCTAssertTrue(page.tracks.allSatisfy { ExperienceRadioEngine.isUsable($0, languages: [.hindi]) })
            XCTAssertTrue(page.tracks.allSatisfy { $0.language == nil }, "Fixture style songs carry no language label, like live results")
        }
        let songs = try await fixtures.search(query: query, filter: .songs, continuation: nil).tracks
        let radio = try await fixtures.radio(seed: songs[2])
        XCTAssertEqual(radio.map(\.id), (0..<6).map { "fixture.style.\(DebugMusicFixtures.slug(query)).radio.2.\($0)" })
        let more = try await fixtures.radio(seed: radio[1])
        XCTAssertEqual(more.first?.id, "fixture.style.\(DebugMusicFixtures.slug(query)).radio.2.2")
        XCTAssertTrue((radio + more).allSatisfy { ExperienceRadioEngine.isUsable($0) })
        let unknown = try await fixtures.search(query: "no-such-ganabajana-recording-72819", filter: .songs, continuation: nil)
        XCTAssertTrue(unknown.tracks.isEmpty, "Only station wording resolves to synthetic songs")
        let seeded = try await fixtures.radio(seed: DebugMusicFixtures.experienceTrack(for: melancholy.seeds[0]))
        XCTAssertEqual(seeded.first?.id, "fixture.experience.radio.apocalypse-cigarettes-after-sex.0")
    }

    func testClassicStationsInTheOtherLanguageSearchWordingWithTheEraNotCues() async throws {
        let cases: [(String, Set<MusicLanguage>)] = [("hindi-classics", [.english]), ("english-golden-oldies", [.hindi])]
        for (id, languages) in cases {
            let catalog = ExperienceRadioCatalogFixture()
            let experience = try station(id)
            do {
                _ = try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [], languages: languages)
                XCTFail("An unanswered wording search has nothing to anchor")
            } catch { XCTAssertEqual(error as? ExperienceRadioError, .noSeeds) }
            let searches = await catalog.searchRequests
            let radios = await catalog.radioRequests
            let expected = Set(experience.styleQueries(in: languages).prefix(3).map { $0 + " before 2000" })
            XCTAssertEqual(Set(searches.map(\.query)), expected, id)
            XCTAssertFalse(searches.contains { request in experience.seeds.contains { $0.query == request.query } }, id)
            XCTAssertTrue(radios.isEmpty)
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
