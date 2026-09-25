import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class ExperienceRadioModelTests: XCTestCase {
    func testOlderStationSuccessOrFailureCannotReplaceTheLatestSelection() async throws {
        for fails in [false, true] {
            let context = try makeContext()
            let f = ExperienceRadioFixtures.self
            let oldTask = context.model.startRadio(f.melancholy)
            try await f.answerSearches(context, from: 0, with: f.melancholySearches)
            let oldRequests = [try await context.catalog.autoplayRadios.request(at: 0),
                               try await context.catalog.autoplayRadios.request(at: 1)]
            let wording = Set(f.gym.selection(for: context.model.listeningLanguageProfile).styleQueries)
            let newTask = context.model.startRadio(f.gym)
            try await f.answerStyleSearches(context, from: 2, count: 6, songs: [], expecting: wording)
            try await f.answerSearches(context, from: 8, with: f.gymSearches)
            try await f.answerRadios(context, from: 2, with: f.gymRadios)
            await newTask.value
            XCTAssertEqual(context.player.queue.map(\.id), ["catalog-zinda", "catalog-goat", "catalog-sultan", "catalog-punjabi"])
            XCTAssertEqual(context.model.activeRadioExperience, f.gym)
            XCTAssertEqual(context.model.radioSessionLabel, "Fixture gym Radio")

            for request in oldRequests {
                let response: Result<[Track], any Error> = fails
                    ? .failure(MusicServiceError.network("Old station failed"))
                    : .success(try XCTUnwrap(f.melancholyRadios[request.input.id]))
                try await context.catalog.autoplayRadios.complete(request, with: response)
            }
            await oldTask.value
            XCTAssertEqual(context.player.queue.map(\.id), ["catalog-zinda", "catalog-goat", "catalog-sultan", "catalog-punjabi"])
            XCTAssertEqual(context.model.selectedRadioExperience, f.gym)
            XCTAssertEqual(context.model.activeRadioExperience, f.gym)
            XCTAssertFalse(context.model.isLoadingRadio)
            XCTAssertNil(context.model.radioError)
            try await AppModelFixtures.eventually {
                let cancellations = await context.catalog.autoplayRadios.cancellations
                return oldRequests.allSatisfy { cancellations.contains($0.id) }
            }
            let cancelled = await context.catalog.autoplayRadios.cancellations
            XCTAssertTrue(oldRequests.allSatisfy { cancelled.contains($0.id) })
            let searches = await context.catalog.searches.requests
            let radios = await context.catalog.radioRefreshRequests
            XCTAssertEqual(searches.count, 10)
            XCTAssertEqual(radios.map(\.forceRefresh), [false, false, false, false])
        }
    }

    func testCancelledSeedSearchCannotStopTheNewStationsLoadingState() async throws {
        let context = try makeContext()
        let f = ExperienceRadioFixtures.self
        let oldTask = context.model.startRadio(f.melancholy)
        let oldSearches = [try await context.catalog.searches.request(at: 0), try await context.catalog.searches.request(at: 1)]
        let wording = Set(f.gym.selection(for: context.model.listeningLanguageProfile).styleQueries)
        let newTask = context.model.startRadio(f.gym)
        _ = try await context.catalog.searches.request(at: 4)
        for request in oldSearches {
            try await context.catalog.searches.complete(request, with: .failure(MusicServiceError.network("Old search failure")))
        }
        await oldTask.value
        XCTAssertTrue(context.model.isLoadingRadio)
        XCTAssertEqual(context.model.selectedRadioExperience, f.gym)
        XCTAssertNil(context.model.radioError)
        XCTAssertNil(context.model.activeRadioExperience)
        try await f.answerStyleSearches(context, from: 2, count: 6, songs: [], expecting: wording)
        try await f.answerSearches(context, from: 8, with: f.gymSearches)
        try await f.answerRadios(context, from: 0, with: f.gymRadios)
        await newTask.value
        XCTAssertEqual(context.model.activeRadioExperience, f.gym)
        XCTAssertEqual(context.player.queue, [f.zinda, f.goat, f.sultan, f.punjabi])
        try await AppModelFixtures.eventually {
            let cancellations = await context.catalog.searches.cancellations
            return oldSearches.allSatisfy { cancellations.contains($0.id) }
        }
    }

    func testExistingAudioAdvancesWhileAStationLoadsAndOnlySwitchesWhenReady() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 20)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = try makeContext(resolver: PlaybackFileResolver(url: url, duration: 20))
        context.model.updatePreferences { $0.autoplay = false }
        let old = libraryTestTrack("already-playing", duration: 20)
        context.model.play(old)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.3 }
        let before = context.player.position
        let f = ExperienceRadioFixtures.self
        let task = context.model.startRadio(f.melancholy)
        _ = try await context.catalog.searches.request(at: 0)
        try await PlaybackTestSupport.waitUntil { context.player.position > before + 0.5 }
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertEqual(context.player.currentTrack, old)
        XCTAssertTrue(context.model.isLoadingRadio)
        try await f.answerSearches(context, from: 0, with: f.melancholySearches)
        try await f.answerRadios(context, from: 0, with: f.melancholyRadios)
        await task.value
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.currentTrack?.id == f.cas.id }
        XCTAssertTrue(context.player.isRadioSession)
        context.player.pause()
    }

    func testExplicitSongPlayCancelsPendingStationEvenWhenItsProviderIgnoresCancellation() async throws {
        let context = try makeContext()
        let f = ExperienceRadioFixtures.self
        let pending = context.model.startRadio(f.melancholy)
        try await f.answerSearches(context, from: 0, with: f.melancholySearches)
        _ = try await context.catalog.autoplayRadios.request(at: 1)
        let explicit = libraryTestTrack("explicit-new-song")
        context.model.play(explicit)
        XCTAssertFalse(context.model.isLoadingRadio)
        try await f.answerRadios(context, from: 0, with: f.melancholyRadios)
        await pending.value
        XCTAssertEqual(context.player.queue, [explicit])
        XCTAssertFalse(context.player.isRadioSession)
        XCTAssertNil(context.model.activeRadioExperience)
        XCTAssertNil(context.model.selectedRadioExperience)
        XCTAssertNil(context.model.radioSessionLabel)
        XCTAssertNil(context.model.radioError)
    }

    func testQueueSelectionCancelsPendingStationButKeepsTheActiveRadioIdentity() async throws {
        let context = try makeContext()
        try await startMelancholy(in: context)
        let f = ExperienceRadioFixtures.self
        let queue = context.player.queue
        let wording = Set(f.gym.selection(for: context.model.listeningLanguageProfile).styleQueries)
        let pending = context.model.startRadio(f.gym)
        _ = try await context.catalog.searches.request(at: 4)
        context.model.playQueueTrack(at: 1)
        try await f.answerStyleSearches(context, from: 2, count: 3, songs: [f.zinda, f.goat, f.sultan, f.punjabi], expecting: wording)
        await pending.value
        XCTAssertEqual(context.player.queue, queue)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertTrue(context.player.isRadioSession)
        XCTAssertEqual(context.model.activeRadioExperience, f.melancholy)
        XCTAssertEqual(context.model.selectedRadioExperience, f.melancholy)
        XCTAssertEqual(context.model.radioSessionLabel, "Fixture melancholy Radio")
        XCTAssertFalse(context.model.isLoadingRadio)
        XCTAssertNil(context.model.radioError)
        let searches = await context.catalog.searches.requests
        let radios = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(searches.count, 5, "Cancellation retires the remaining style queries and backup cues")
        XCTAssertEqual(radios.count, 2)
        try await AppModelFixtures.eventually { await context.catalog.searches.cancellations.isSuperset(of: [2, 3, 4]) }
    }

    func testFailedStartPreservesTheCurrentQueueAndRetryUsesFreshRadio() async throws {
        let old = libraryTestTrack("keep-this-song")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [old], position: 42))
        let f = ExperienceRadioFixtures.self
        let wording = Set(f.melancholy.selection(for: context.model.listeningLanguageProfile).styleQueries)
        let failed = context.model.startRadio(f.melancholy)
        try await f.answerSearches(context, from: 0, with: f.melancholySearches)
        try await f.answerRadios(context, from: 0, with: f.melancholyRadios, fail: true)
        try await f.answerStyleSearches(context, from: 2, count: 6, songs: [], expecting: wording)
        try await f.answerRadios(context, from: 2, with: f.melancholyRadios, fail: true)
        await failed.value
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 42)
        XCTAssertFalse(context.player.isRadioSession)
        XCTAssertFalse(context.model.isLoadingRadio)
        XCTAssertNotNil(context.model.radioError)
        context.model.retryRadio()
        try await f.answerSearches(context, from: 8, with: f.melancholySearches)
        try await f.answerRadios(context, from: 4, with: [f.cas.id: [], f.pixies.id: []])
        try await f.answerStyleSearches(context, from: 10, count: 6, songs: [], expecting: wording)
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 42)
        try await f.answerRadios(context, from: 6, with: f.melancholyRadios)
        try await AppModelFixtures.eventually { !context.model.isLoadingRadio }
        XCTAssertEqual(context.model.activeRadioExperience, f.melancholy)
        XCTAssertNil(context.model.radioError)
        XCTAssertEqual(context.player.queue.map(\.id), ["catalog-cas", "catalog-pixies", "catalog-dream", "catalog-alt"])
        let searches = await context.catalog.searches.requests
        let radios = await context.catalog.radioRefreshRequests
        XCTAssertEqual(searches.count, 16, "Each pass resolves two cues and searches three style queries with both filters")
        XCTAssertEqual(searches.filter { $0.input.filter == .playlists }.count, 6)
        XCTAssertEqual(radios.map(\.forceRefresh), [false, false, true, true, false, false, true, true])
        XCTAssertEqual(Set(radios.prefix(4).map(\.seed.id)), [f.cas.id, f.pixies.id])
        XCTAssertEqual(Set(radios.suffix(4).map(\.seed.id)), [f.cas.id, f.pixies.id])
    }

    func testDislikesAddedDuringLoadingAreCheckedAgainBeforeStartingPlayback() async throws {
        let context = try makeContext()
        let f = ExperienceRadioFixtures.self
        let task = context.model.startRadio(f.melancholy)
        try await f.answerSearches(context, from: 0, with: f.melancholySearches)
        _ = try await context.catalog.autoplayRadios.request(at: 1)
        context.library.toggleDislike(f.dream)
        let replacement = RecommendationFixtures.track("replacement", title: "Night Shift", artist: "Lucy Dacus")
        try await f.answerRadios(context, from: 0, with: [f.cas.id: [f.dream, replacement], f.pixies.id: [f.alt]])
        await task.value
        XCTAssertEqual(context.player.queue.map(\.id), ["catalog-cas", "catalog-pixies", "catalog-alt", "replacement"])
        XCTAssertFalse(context.player.queue.contains { $0.id == f.dream.id })
        XCTAssertTrue(context.player.isRadioSession)
    }

    func testDislikingAnUpcomingRadioSongRemovesItFromTheQueue() async throws {
        let context = try makeContext()
        try await startMelancholy(in: context)
        context.model.toggleDislike(ExperienceRadioFixtures.dream)
        XCTAssertEqual(context.player.queue.map(\.id), ["catalog-cas", "catalog-pixies", "catalog-alt"])
        XCTAssertEqual(context.player.currentTrack, ExperienceRadioFixtures.cas)
        XCTAssertEqual(context.model.activeRadioExperience, ExperienceRadioFixtures.melancholy)
    }

    func testLateDislikesCannotTurnARadioStartIntoASeedOnlyPlaylist() async throws {
        let old = libraryTestTrack("keep-playing")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [old], position: 12))
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "melancholy" })
        let seeds = station.seeds.enumerated().map { index, intent in
            RecommendationFixtures.track("seed-\(index)", title: intent.title, artist: intent.artist.name)
        }
        let searches = Dictionary(uniqueKeysWithValues: zip(station.seeds, seeds).map { ($0.query, $1) })
        let neighbor = RecommendationFixtures.track("blocked-neighbor", title: "Shared radio neighbor")
        let task = context.model.startRadio(station)
        try await ExperienceRadioFixtures.answerSearches(context, from: 0, with: searches)
        _ = try await context.catalog.autoplayRadios.request(at: 0)
        context.library.toggleDislike(neighbor)
        let radios = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, [neighbor]) })
        try await ExperienceRadioFixtures.answerRadios(context, from: 0, with: radios)
        await task.value
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 12)
        XCTAssertNotNil(context.model.radioError)
        XCTAssertNil(context.model.activeRadioExperience)
    }

    func testStationContinuationKeepsPunjabiWithAutoplayOffAndHindiDiscovery() async throws {
        let context = try makeContext(languages: [.hindi])
        context.model.updatePreferences { $0.autoplay = false }
        let f = ExperienceRadioFixtures.self
        let started = context.model.startRadio(f.gym)
        try await f.answerSearches(context, from: 0, with: f.gymSearches)
        try await f.answerRadios(context, from: 0, with: f.gymRadios)
        await started.value
        XCTAssertEqual(context.library.preferences.languages, [.hindi])
        XCTAssertFalse(context.player.settings.autoplay)
        XCTAssertTrue(context.player.isRadioSession)
        XCTAssertTrue(context.player.queue.contains(f.goat))
        XCTAssertTrue(context.player.queue.contains(f.punjabi))

        let nextHindi = RecommendationFixtures.track("next-hindi", title: "Dangal", artist: "Daler Mehndi", language: .hindi)
        let nextPunjabi = RecommendationFixtures.track("next-punjabi", title: "We Rollin", artist: "Shubh")
        let rejected = RecommendationFixtures.track("rejected", title: "Rejected neighbor")
        context.library.toggleDislike(rejected)
        let callback = try XCTUnwrap(context.player.onQueueExhausted)
        let task = Task { await callback(f.punjabi) }
        defer { task.cancel() }
        try await f.answerRadios(context, from: 2, with: [
            f.zinda.id: [f.zinda, RecommendationFixtures.track("video", audio: false), nextHindi],
            f.punjabi.id: [f.punjabi, rejected, nextPunjabi],
        ])
        let additions = await task.value
        XCTAssertEqual(additions, [nextHindi, nextPunjabi])
        context.player.appendAutoplay(additions)
        XCTAssertEqual(context.model.radioSessionLabel, "Fixture gym Radio")
        XCTAssertFalse(context.library.preferences.autoplay)
        XCTAssertTrue(context.library.playlists.isEmpty)
        XCTAssertTrue(context.library.mixes.isEmpty)
        XCTAssertTrue(context.library.recentSearches.isEmpty, "Station seed lookups are not the listener's searches")
        let restored = LibraryStore(directory: context.directory)
        XCTAssertEqual(restored.playback.queue, context.player.queue)
        XCTAssertFalse(restored.preferences.autoplay)

        let manual = libraryTestTrack("manual-song")
        context.model.play(manual)
        await context.catalog.autoplayRadios.enqueue(.success([f.dream]))
        let ordinary = await callback(manual)
        XCTAssertEqual(ordinary, [f.dream])
        XCTAssertNil(context.model.radioSessionLabel)
        let calls = await context.catalog.autoplayRadios.requests
        XCTAssertEqual(calls.last?.input.id, manual.id)
        let targeted = await context.catalog.radios.requests
        XCTAssertTrue(targeted.isEmpty)
    }

    func testLateContinuationCannotAppendAfterAnExplicitNewSong() async throws {
        let context = try makeContext()
        try await startMelancholy(in: context)
        let f = ExperienceRadioFixtures.self
        let callback = try XCTUnwrap(context.player.onQueueExhausted)
        let continuation = Task { await callback(f.alt) }
        defer { continuation.cancel() }
        _ = try await context.catalog.autoplayRadios.request(at: 3)
        let explicit = libraryTestTrack("new-selection")
        context.model.play(explicit)
        let late = RecommendationFixtures.track("late-neighbor")
        try await f.answerRadios(context, from: 2, with: [f.cas.id: [late], f.alt.id: [late]])
        let additions = await continuation.value
        XCTAssertTrue(additions.isEmpty)
        XCTAssertEqual(context.player.queue, [explicit])
        XCTAssertNil(context.model.radioContinuationError)
        XCTAssertNil(context.model.activeRadioExperience)
        XCTAssertFalse(context.model.isContinuingRadio)
    }

    func testContinuationFailureIsRetryableWithoutReplacingThePlayingQueue() async throws {
        let context = try makeContext()
        let wording = Set(ExperienceRadioFixtures.melancholy.selection(for: context.model.listeningLanguageProfile).styleQueries)
        try await startMelancholy(in: context)
        let f = ExperienceRadioFixtures.self
        let queue = context.player.queue
        let callback = try XCTUnwrap(context.player.onQueueExhausted)
        let continuation = Task { await callback(f.alt) }
        defer { continuation.cancel() }
        try await f.answerRadios(context, from: 2, with: [f.cas.id: [], f.alt.id: []], fail: true)
        try await f.answerStyleSearches(context, from: 2, count: 6, songs: [], expecting: wording)
        let additions = await continuation.value
        XCTAssertTrue(additions.isEmpty)
        XCTAssertNotNil(context.model.radioContinuationError)
        XCTAssertEqual(context.model.activeRadioExperience, f.melancholy)
        XCTAssertEqual(context.player.queue, queue)
        let automaticRequests = await context.catalog.radioRefreshRequests
        XCTAssertEqual(automaticRequests.map(\.forceRefresh), [false, false, false, false])

        let nextA = RecommendationFixtures.track("next-a", title: "Space Song", artist: "Beach House")
        let nextB = RecommendationFixtures.track("next-b", title: "Linger", artist: "The Cranberries")
        context.model.retryRadioContinuation()
        try await f.answerRadios(context, from: 4, with: [f.cas.id: [nextA], f.alt.id: [nextB]])
        try await AppModelFixtures.eventually { context.player.queue.count == 6 }
        XCTAssertEqual(context.player.queue, queue + [nextA, nextB])
        XCTAssertEqual(context.player.currentTrack, f.cas)
        XCTAssertNil(context.model.radioContinuationError)
        XCTAssertEqual(context.model.radioSessionLabel, "Fixture melancholy Radio")
        XCTAssertTrue(context.player.isRadioSession)
        XCTAssertEqual(context.model.activeRadioExperience, f.melancholy)
        let retryRequests = await context.catalog.radioRefreshRequests
        XCTAssertEqual(retryRequests.map(\.forceRefresh), [false, false, false, false, true, true])
        XCTAssertEqual(Set(retryRequests.suffix(2).map(\.seed.id)), Set(automaticRequests.suffix(2).map(\.seed.id)),
                       "Retry must refresh the same session round and buckets rather than start another station")

        let nextC = RecommendationFixtures.track("next-c", title: "Night Shift", artist: "Lucy Dacus")
        let nextD = RecommendationFixtures.track("next-d", title: "Myth", artist: "Beach House")
        let automatic = Task { await callback(nextB) }
        defer { automatic.cancel() }
        try await f.answerRadios(context, from: 6, with: [nextA.id: [nextC], f.pixies.id: [nextD]])
        let more = await automatic.value
        XCTAssertEqual(more, [nextC, nextD])
        let subsequentRequests = await context.catalog.radioRefreshRequests
        XCTAssertEqual(subsequentRequests.map(\.forceRefresh), [false, false, false, false, true, true, false, false],
                       "The next automatic continuation must return to normal caching")
        XCTAssertEqual(context.player.queue, queue + [nextA, nextB])
        XCTAssertEqual(context.model.activeRadioExperience, f.melancholy)
        let searches = await context.catalog.searches.requests
        XCTAssertEqual(searches.count, 8, "Only the failed continuation needs the bounded style fallback")
    }

    func testLanguageEditsRefreshDiscoveryWithoutInterruptingTheActiveRadioOrChangingItsScope() async throws {
        let context = try makeContext()
        context.model.setLanguageNudge(.more, for: .english)
        let frozen = context.model.listeningLanguageProfile
        try await startMelancholy(in: context)
        context.player.pause()
        context.player.seek(to: 31)
        let queue = context.player.queue
        context.model.updatePreferences {
            $0.languageNudges[.english] = .less
            $0.languageNudges[.hindi] = .more
        }
        let updated = context.model.listeningLanguageProfile
        XCTAssertGreaterThan(frozen.weights[.english, default: 0], frozen.weights[.hindi, default: 0])
        XCTAssertGreaterThan(updated.weights[.hindi, default: 0], updated.weights[.english, default: 0])
        XCTAssertNotEqual(frozen.requestKey, updated.requestKey)
        XCTAssertTrue(context.model.radioExperiences.contains { $0.id == "melancholy" }, "Every station stays listed for every language")
        XCTAssertEqual(context.player.queue, queue)
        XCTAssertEqual(context.player.position, 31)
        XCTAssertTrue(context.player.isRadioSession)
        XCTAssertEqual(context.model.activeRadioExperience, ExperienceRadioFixtures.melancholy)
        XCTAssertEqual(context.model.radioSessionLabel, "Fixture melancholy Radio")
        XCTAssertEqual(context.model.activeRadioContentLabel, "Automatic discovery")
        XCTAssertTrue(context.model.isActiveRadio(ExperienceRadioFixtures.melancholy))

        let english = RecommendationFixtures.track("next-english", title: "English continuation", language: .english)
        let hindi = RecommendationFixtures.track("next-hindi", title: "Hindi continuation", language: .hindi)
        let unknown = RecommendationFixtures.track("next-unknown", title: "Unknown continuation")
        let callback = try XCTUnwrap(context.player.onQueueExhausted)
        let continuation = Task { await callback(ExperienceRadioFixtures.alt) }
        defer { continuation.cancel() }
        try await ExperienceRadioFixtures.answerRadios(context, from: 2, with: [
            ExperienceRadioFixtures.cas.id: [hindi, unknown], ExperienceRadioFixtures.alt.id: [english],
        ])
        let additions = await continuation.value
        XCTAssertEqual(additions, [english, hindi, unknown], "Frozen weights lead with English while Hindi and unknown recordings stay eligible")
        XCTAssertEqual(context.player.queue, queue)
        XCTAssertEqual(context.library.preferences.languageNudges[.hindi], .more)
        XCTAssertEqual(context.library.preferences.languageNudges[.english], .less)
        XCTAssertEqual(context.library.preferences.languages, [.hindi, .english])
        XCTAssertEqual(context.player.position, 31)
    }

    func testLanguageEditCancelsAPendingStationThatNoLongerMatchesDiscovery() async throws {
        let old = libraryTestTrack("keep-playing")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [old], position: 18))
        let wording = Set(ExperienceRadioFixtures.gym.selection(for: context.model.listeningLanguageProfile).styleQueries)
        let task = context.model.startRadio(ExperienceRadioFixtures.gym)
        _ = try await context.catalog.searches.request(at: 2)
        context.model.setLanguageNudge(.more, for: .hindi)
        XCTAssertFalse(context.model.isLoadingRadio)
        try await ExperienceRadioFixtures.answerStyleSearches(context, from: 0, count: 3,
            songs: [ExperienceRadioFixtures.zinda, ExperienceRadioFixtures.goat, ExperienceRadioFixtures.sultan, ExperienceRadioFixtures.punjabi],
            expecting: wording)
        await task.value
        let radios = await context.catalog.autoplayRadios.requests
        let searches = await context.catalog.searches.requests
        XCTAssertTrue(radios.isEmpty)
        XCTAssertEqual(searches.count, 3)
        XCTAssertEqual(context.model.listeningLanguageProfile.orderedLanguages.first, .hindi)
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 18)
        XCTAssertNil(context.model.radioError)
        XCTAssertNil(context.model.activeRadioExperience)
        XCTAssertNil(context.model.selectedRadioExperience)
        try await AppModelFixtures.eventually { await context.catalog.searches.cancellations.isSuperset(of: [0, 1, 2]) }
    }

    func testAnExplicitSongAfterRadioStillHasLanguageUnrestrictedAutoplay() async throws {
        let context = try makeContext(languages: [.english])
        try await startMelancholy(in: context)
        context.model.play(ExperienceRadioFixtures.zinda)
        var english = ExperienceRadioFixtures.dream
        english.language = .english
        let neighbors = [ExperienceRadioFixtures.sultan, ExperienceRadioFixtures.punjabi, english]
        await context.catalog.autoplayRadios.enqueue(.success(neighbors))
        let callback = try XCTUnwrap(context.player.onQueueExhausted)
        let additions = await callback(ExperienceRadioFixtures.zinda)
        XCTAssertEqual(additions, neighbors)
        XCTAssertFalse(context.player.isRadioSession)
        XCTAssertNil(context.model.radioSessionLabel)
        XCTAssertEqual(context.library.preferences.languages, [.english])
    }

    func testMixedStationBadgeDoesNotClaimADifferentVariantIsAlreadyPlaying() async throws {
        let context = try makeContext()
        context.model.setLanguageNudge(.more, for: .english)
        let f = ExperienceRadioFixtures.self
        let mixed = RadioExperience(id: "fixture-mixed", title: "Mixed fixture", description: "Two language groups", symbol: "radio",
            group: .moods, variants: [
                .init(id: "english", discoveryLanguages: [.english], contentLabel: "English", seeds: f.melancholy.seeds),
                .init(id: "hindi", discoveryLanguages: [.hindi], contentLabel: "Hindi + Punjabi", seeds: f.gym.seeds),
            ])
        let first = context.model.startRadio(mixed)
        try await f.answerSearches(context, from: 0, with: f.melancholySearches)
        try await f.answerRadios(context, from: 0, with: f.melancholyRadios)
        await first.value
        XCTAssertTrue(context.model.isActiveRadio(mixed))
        let queue = context.player.queue
        context.model.updatePreferences {
            $0.languageNudges[.english] = .less
            $0.languageNudges[.hindi] = .more
        }
        XCTAssertTrue(context.model.isActiveRadio(mixed), "Nudges do not change the identity of the playing station")
        XCTAssertEqual(context.model.activeRadioContentLabel, "Automatic discovery")
        XCTAssertEqual(context.player.queue, queue)
        XCTAssertEqual(context.player.currentTrack, f.cas)
        XCTAssertEqual(context.model.listeningLanguageProfile.orderedLanguages.first, .hindi)
        let second = context.model.startRadio(mixed)
        try await f.answerSearches(context, from: 2, with: f.gymSearches)
        try await f.answerRadios(context, from: 2, with: f.gymRadios)
        await second.value
        XCTAssertTrue(context.model.isActiveRadio(mixed))
        XCTAssertEqual(context.model.activeRadioContentLabel, "Automatic discovery")
        XCTAssertEqual(context.player.currentTrack, f.zinda)
        XCTAssertEqual(context.player.queue, [f.zinda, f.sultan, f.goat, f.punjabi])
        XCTAssertNil(context.model.radioError)
    }

    private func startMelancholy(in context: AppModelTestContext) async throws {
        let f = ExperienceRadioFixtures.self
        let task = context.model.startRadio(f.melancholy)
        try await f.answerSearches(context, from: 0, with: f.melancholySearches)
        try await f.answerRadios(context, from: 0, with: f.melancholyRadios)
        await task.value
        XCTAssertEqual(context.model.activeRadioExperience, f.melancholy)
    }

    private func makeContext(languages: Set<MusicLanguage> = Set(MusicLanguage.allCases), snapshot: PlaybackSnapshot = PlaybackSnapshot(),
                             resolver: (any StreamResolving)? = nil) throws -> AppModelTestContext {
        let context = try AppModelTestContext(languages: languages, snapshot: snapshot, resolver: resolver)
        addTeardownBlock { @MainActor in
            context.model.cancelPendingRadio()
            try await context.close()
        }
        return context
    }
}
