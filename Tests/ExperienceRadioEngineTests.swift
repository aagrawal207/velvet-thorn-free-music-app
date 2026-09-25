import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class ExperienceRadioEngineTests: XCTestCase {
    func testStationDefinitionsHaveDistinctIntentsAndTheRequestedMusicalAnchors() throws {
        let stations = RadioExperience.stations
        XCTAssertEqual(stations.filter { $0.group == .moods }.map(\.id), [
            "melancholy", "hindi-gym", "late-night-hindi", "easy-morning", "feel-good", "focus", "party", "romance",
            "heartbreak", "punjabi-drive", "rainy-day", "devotional",
        ])
        XCTAssertEqual(stations.filter { $0.group == .genres }.map(\.id), [
            "left-field-rap", "rock", "alt-rock", "indian-indie", "pop", "rnb-soul", "dance-edm", "lofi", "acoustic", "jazz",
            "classical", "folk", "sufi", "ghazal", "qawwali", "punjabi-hits", "hindi-classics", "english-golden-oldies",
            "metal", "country", "reggae", "nineties",
        ])
        XCTAssertEqual(stations.count, 34)
        XCTAssertEqual(Set(stations.map(\.id)).count, stations.count, "Ids are stable keys")
        XCTAssertEqual(Set(stations.map(\.title)).count, stations.count, "Titles are distinct tiles")
        XCTAssertEqual(Set(stations.map(\.symbol)).count, stations.count, "Symbols are distinct tiles")
        XCTAssertTrue(stations.allSatisfy { !$0.description.isEmpty && !$0.description.contains("—") })
        XCTAssertTrue(stations.allSatisfy { $0.id == $0.id.lowercased() && !$0.id.contains(" ") })
        let renamed = ["hindi-gym": "Workout", "late-night-hindi": "Late night", "punjabi-drive": "Road trip", "indian-indie": "Indie",
                       "left-field-rap": "Rap and hip hop", "hindi-classics": "Bollywood classics", "english-golden-oldies": "Golden oldies"]
        for (id, title) in renamed {
            XCTAssertEqual(stations.first { $0.id == id }?.title, title)
        }
        XCTAssertEqual(stations.filter { $0.defaultEra == .older }.map(\.id), ["hindi-classics", "english-golden-oldies"])
        let melancholy = try XCTUnwrap(stations.first { $0.id == "melancholy" })
        XCTAssertEqual(Array(melancholy.seeds.prefix(2)).map(\.artist.name), ["Cigarettes After Sex", "Pixies"])
        XCTAssertEqual(melancholy.cueLanguages, [.english])
        let gym = try XCTUnwrap(stations.first { $0.id == "hindi-gym" })
        XCTAssertTrue(gym.seeds.contains { $0.title == "Zinda" && $0.album == "Bhaag Milkha Bhaag" })
        XCTAssertTrue(gym.seeds.contains { $0.artist.name == "Diljit Dosanjh" })
        XCTAssertTrue(gym.seeds.contains { $0.artist.name == "AP Dhillon" })
        XCTAssertEqual(gym.cueLanguages, [.hindi])
        XCTAssertTrue(stations.flatMap(\.seeds).allSatisfy { $0.artist.id == nil }, "Seed intents carry no invented catalog identifiers")
        let discovery = RadioExperience.discoveryStations
        XCTAssertEqual(Array(discovery.prefix(2)).map(\.id), ["melancholy", "hindi-gym"])
        XCTAssertEqual(discovery.map(\.id), stations.filter { $0.group == .moods }.map(\.id) + stations.filter { $0.group == .genres }.map(\.id))
    }

    func testSeedMatchingRequiresBothArtistAndTitleAndVerifiedAudio() throws {
        let intent = RadioExperience.Seed("Jai Ho", by: "A. R. Rahman")
        let valid = Track(id: "matching-audio", title: "Jai Ho", credits: [ArtistCredit(name: "Sukhwinder Singh"),
            ArtistCredit(name: "AR Rahman")], isAudioRecording: true)
        let wrongArtist = RecommendationFixtures.track("tribute", title: "Jai Ho", artist: "Tribute singers")
        let wrongTitle = RecommendationFixtures.track("wrong-song", title: "Jai Jai", artist: "A. R. Rahman")
        var video = valid
        video.id = "video"
        video.isAudioRecording = false
        var unverified = valid
        unverified.id = "unverified"
        unverified.isAudioRecording = nil
        var slowed = valid
        slowed.id = "slowed"
        slowed.title = "Jai Ho (Slowed + Reverb)"
        let candidates = [wrongArtist, wrongTitle, video, unverified, slowed]
        XCTAssertNil(ExperienceRadioEngine.matchedSeed(intent, in: candidates, disliked: []))
        XCTAssertEqual(ExperienceRadioEngine.matchedSeed(intent, in: candidates + [valid], disliked: []), valid)
        let dislike = DislikedSong(id: "another-release", title: "Jai Ho (Remastered)", artists: ["AR Rahman"])
        XCTAssertNil(ExperienceRadioEngine.matchedSeed(intent, in: [valid], disliked: [dislike]))
    }

    func testInterleavingFiltersIDsSongCoresDislikesUnverifiedAudioAndUnwantedVersions() {
        let a = RecommendationFixtures.track("a", title: "First Light", artist: "Artist A")
        let b = RecommendationFixtures.track("b", title: "Quiet Streets", artist: "Artist B")
        let c = RecommendationFixtures.track("c", title: "Blue Window", artist: "Artist C")
        let d = RecommendationFixtures.track("d", title: "Morning Train", artist: "Artist A")
        let e = RecommendationFixtures.track("e", title: "Half Awake", artist: "Artist B")
        var duplicateID = a
        duplicateID.title = "Different metadata for the same id"
        let duplicateTitle = RecommendationFixtures.track("a-remaster", title: "First Light (Remastered)", artist: "Artist A")
        let queuedVersion = RecommendationFixtures.track("queued-version", title: "Apocalypse (Live)")
        let disliked = DislikedSong(id: "banned", title: "No Surprises", artists: ["Radiohead"])
        let blockedID = RecommendationFixtures.track("banned", title: "Changed metadata")
        let blockedTitle = RecommendationFixtures.track("banned-version", title: "No Surprises (Remastered)")
        let video = RecommendationFixtures.track("video", audio: false)
        let unknown = RecommendationFixtures.track("unknown", audio: nil)
        let slowed = RecommendationFixtures.track("slowed", title: "Slow song (Slowed + Reverb)")
        let short = RecommendationFixtures.track("short", duration: 5)
        let empty = RecommendationFixtures.track(" ", title: "No identifier")
        let selected = ExperienceRadioEngine.selection(buckets: [
            [queuedVersion, video, a, duplicateID, slowed, short, empty, d],
            [duplicateTitle, b, blockedID, e],
            [unknown, blockedTitle, c],
        ], excluding: [ExperienceRadioFixtures.cas], disliked: [disliked]).tracks
        XCTAssertEqual(selected.map(\.id), ["a", "b", "c", "d", "e"])
    }

    func testInterleavingCapsProlificArtistsAndHonorsTheQueueLimit() {
        let prolific = (0..<10).map { RecommendationFixtures.track("a\($0)", artist: "Prolific artist") }
        let others = (0..<10).map { RecommendationFixtures.track("b\($0)", artist: "Artist \($0)") }
        let all = ExperienceRadioEngine.selection(buckets: [prolific, others], disliked: []).tracks
        XCTAssertEqual(all.filter { $0.artists == ["Prolific artist"] }.count, 4)
        XCTAssertEqual(Array(all.prefix(6)).map(\.id), ["a0", "b0", "a1", "b1", "a2", "b2"])
        XCTAssertEqual(ExperienceRadioEngine.selection(buckets: [prolific, others], disliked: [], limit: 3).tracks.map(\.id), ["a0", "b0", "a1"])
        XCTAssertTrue(ExperienceRadioEngine.selection(buckets: [prolific], disliked: [], limit: 0).tracks.isEmpty)
        XCTAssertTrue(ExperienceRadioEngine.selection(buckets: [prolific], disliked: [], limit: -1).tracks.isEmpty)
    }

    func testStartUsesSongSearchAndProviderRadioInSeedOrderDespiteOutOfOrderCompletion() async throws {
        let catalog = AppModelCatalogProvider()
        addTeardownBlock { await catalog.close() }
        let engine = ExperienceRadioEngine(catalog: catalog)
        let task = Task { try await engine.start(ExperienceRadioFixtures.melancholy, disliked: []) }
        defer { task.cancel() }
        let first = try await catalog.searches.request(at: 0)
        let second = try await catalog.searches.request(at: 1)
        for request in [second, first] {
            XCTAssertEqual(request.input.filter, .songs)
            XCTAssertNil(request.input.continuation)
            let song = try XCTUnwrap(ExperienceRadioFixtures.melancholySearches[request.input.query])
            try await catalog.searches.complete(request, with: .success(CatalogPage(tracks: [song])))
        }
        let firstRadio = try await catalog.autoplayRadios.request(at: 0)
        let secondRadio = try await catalog.autoplayRadios.request(at: 1)
        for request in [secondRadio, firstRadio] {
            let songs = try XCTUnwrap(ExperienceRadioFixtures.melancholyRadios[request.input.id])
            try await catalog.autoplayRadios.complete(request, with: .success(songs))
        }
        let batch = try await task.value
        XCTAssertEqual(batch.tracks.map(\.id), ["catalog-cas", "catalog-pixies", "catalog-dream", "catalog-alt"])
        XCTAssertEqual(batch.buckets.map(\.anchor.id), ["catalog-cas", "catalog-pixies"])
        XCTAssertEqual(batch.buckets.map(\.frontier.id), ["catalog-dream", "catalog-alt"])
        let targeted = await catalog.radios.requests
        XCTAssertTrue(targeted.isEmpty)
    }

    func testSeedSearchAndRadioFanoutHaveBudgetsAndBoundedConcurrency() async throws {
        let intents = (0..<15).map { RadioExperience.Seed("Signal \($0)", by: "Artist \($0)") }
        let experience = RadioExperience(id: "large-fixture", title: "Large fixture", description: "Offline fixture", symbol: "radio",
                                         discoveryLanguages: [.english], contentLabel: "English", seeds: intents)
        let seeds = (0..<15).map { RecommendationFixtures.track("seed-\($0)", title: "Signal \($0)", artist: "Artist \($0)") }
        let searches: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: zip(intents, seeds).map { ($0.query, .success([$1])) })
        let radios: [String: Result<[Track], any Error>] = Dictionary(uniqueKeysWithValues: seeds.enumerated().map { index, seed in
            (seed.id, .success((0..<3).map { RecommendationFixtures.track("radio-\(index)-\($0)", artist: "Neighbor \(index)") }))
        })
        let catalog = ExperienceRadioCatalogFixture(searches: searches, radios: radios, delay: .milliseconds(40))
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(experience, disliked: [])
        let searched = await catalog.searchRequests
        let requestedRadio = await catalog.radioRequests
        let maximum = await catalog.maximumActiveRequests
        XCTAssertEqual(searched.count, 6)
        XCTAssertEqual(requestedRadio.count, 4)
        XCTAssertLessThanOrEqual(maximum, 3)
        XCTAssertGreaterThan(maximum, 1)
        XCTAssertTrue(searched.allSatisfy { $0.filter == .songs && $0.continuation == nil })
        XCTAssertEqual(batch.buckets.map(\.anchor.id), ["seed-0", "seed-1", "seed-2", "seed-3"])
        XCTAssertLessThanOrEqual(batch.tracks.count, 24)
    }

    func testAUsefulRadioSurvivesAnotherSeedsFailure() async throws {
        let catalog = ExperienceRadioCatalogFixture(
            searches: ExperienceRadioFixtures.melancholySearches.mapValues { .success([$0]) },
            radios: [ExperienceRadioFixtures.cas.id: .success([ExperienceRadioFixtures.dream, ExperienceRadioFixtures.alt]),
                     ExperienceRadioFixtures.pixies.id: .failure(MusicServiceError.network("One radio failed"))])
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(ExperienceRadioFixtures.melancholy, disliked: [])
        XCTAssertEqual(batch.tracks.map(\.id), ["catalog-cas", "catalog-pixies", "catalog-dream", "catalog-alt"])
    }

    func testRadioRefreshDefaultsToAnExistingProvidersRadioImplementation() async throws {
        let f = ExperienceRadioFixtures.self
        let catalog = ExperienceRadioCatalogFixture(radios: [f.cas.id: .success([f.dream, f.alt])])
        let provider: any MusicCatalogProviding = catalog
        let tracks = try await provider.radio(seed: f.cas, forceRefresh: true)
        XCTAssertEqual(tracks, [f.dream, f.alt])
        let requests = await catalog.radioRequests
        let targeted = await catalog.targetedRadioRequests
        XCTAssertEqual(requests, [f.cas])
        XCTAssertEqual(targeted, 0, "The compatibility default must use the provider's radio override, not language-targeted recommendations")
    }

    func testUnavailableRadiosNeverFallBackToAFixedSeedPlaylist() async throws {
        let failures: [Result<[Track], any Error>] = [.success([]), .failure(MusicServiceError.network("Offline")),
            .success([ExperienceRadioFixtures.cas, ExperienceRadioFixtures.pixies,
                      RecommendationFixtures.track("video-only", audio: false)])]
        for response in failures {
            let catalog = ExperienceRadioCatalogFixture(
                searches: ExperienceRadioFixtures.melancholySearches.mapValues { .success([$0]) },
                radios: [ExperienceRadioFixtures.cas.id: response, ExperienceRadioFixtures.pixies.id: response])
            do {
                _ = try await ExperienceRadioEngine(catalog: catalog).start(ExperienceRadioFixtures.melancholy, disliked: [])
                XCTFail("A station needs provider-radio neighbors, not just its seed songs")
            } catch { XCTAssertEqual(error as? ExperienceRadioError, .unavailable) }
        }
    }

    func testOneUsableMoodSeedCanStartWithoutSeedingTheDislikedSong() async throws {
        let f = ExperienceRadioFixtures.self
        let other = RecommendationFixtures.track("third-neighbor", title: "Night Shift", artist: "Lucy Dacus")
        let catalog = ExperienceRadioCatalogFixture(searches: f.melancholySearches.mapValues { .success([$0]) },
            radios: [f.pixies.id: .success([f.dream, f.alt, other])])
        let disliked = DislikedSong(id: "different-id", title: "Apocalypse (Remastered)", artists: ["Cigarettes After Sex"])
        let batch = try await ExperienceRadioEngine(catalog: catalog).start(f.melancholy, disliked: [disliked])
        XCTAssertEqual(batch.buckets.map(\.anchor.id), [f.pixies.id])
        XCTAssertEqual(batch.tracks, [f.pixies, f.dream, f.alt, other])
        let radio = await catalog.radioRequests
        XCTAssertEqual(radio, [f.pixies])
        XCTAssertFalse(batch.tracks.contains { $0.id == f.cas.id })
    }

    func testContinuationRotatesAnchorsAndKeepsUnclassifiedPunjabiForHindiDiscovery() async throws {
        let f = ExperienceRadioFixtures.self
        let hindiNext = RecommendationFixtures.track("next-hindi", title: "Dangal", artist: "Daler Mehndi", language: .hindi)
        let punjabiNext = RecommendationFixtures.track("next-punjabi", title: "We Rollin", artist: "Shubh")
        let catalog = ExperienceRadioCatalogFixture(radios: [f.sultan.id: .success([f.zinda, hindiNext]),
                                                            f.goat.id: .success([f.punjabi, punjabiNext])])
        let buckets = [ExperienceRadioEngine.Bucket(anchor: f.zinda, frontier: f.sultan),
                       ExperienceRadioEngine.Bucket(anchor: f.goat, frontier: f.punjabi)]
        let batch = try await ExperienceRadioEngine(catalog: catalog).continueRadio(buckets: buckets, round: 1,
            queue: [f.zinda, f.goat, f.sultan, f.punjabi], disliked: [], languages: [.hindi])
        XCTAssertEqual(batch.tracks, [hindiNext, punjabiNext])
        XCTAssertNil(batch.tracks.last?.language, "An unclassified Punjabi recording remains eligible")
        XCTAssertEqual(batch.buckets.map(\.frontier.id), ["next-hindi", "next-punjabi"])
        let calls = await catalog.radioRequests
        XCTAssertEqual(Set(calls.map(\.id)), ["catalog-sultan", "catalog-goat"])
        let targeted = await catalog.targetedRadioRequests
        XCTAssertEqual(targeted, 0)
    }
}
