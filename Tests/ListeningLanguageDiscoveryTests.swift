import XCTest
@testable import GanaBajana

@MainActor
final class ListeningLanguageDiscoveryTests: XCTestCase {
    func testOnlyValidatedQualifiedSessionsInTheRecentThirtyDaysAreChecked() async throws {
        let clock = makeClock()
        let now = clock.now()
        let cutoff = libraryTestCalendar().date(byAdding: .day, value: -30, to: now)!
        let provider = ListeningDiscoveryLyrics()
        let discovery = makeDiscovery(provider, clock: clock)
        let long = event(track("long"), at: now, seconds: 30)
        var short = track("short")
        short.duration = 40
        var unknownDuration = track("unknown-duration")
        unknownDuration.duration = nil
        var events = [long, long, event(short, at: now, seconds: 20),
                      event(unknownDuration, at: now, seconds: 30), event(track("boundary"), at: cutoff, seconds: 30),
                      event(track("skip"), at: now, seconds: 29.999),
                      event(track("old"), at: cutoff.addingTimeInterval(-0.001), seconds: 90),
                      event(track("future"), at: now.addingTimeInterval(0.001), seconds: 90)]
        short.id = "short-skip"
        events.append(event(short, at: now, seconds: 19.999))
        for seconds in [0, -1, Double.nan, .infinity, 1e300] {
            events.append(event(track("invalid-seconds"), at: now, seconds: seconds))
        }
        for date in [Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: .nan)] {
            events.append(event(track("invalid-date"), at: date, seconds: 60))
        }
        var invalidTrack = track("invalid-track")
        invalidTrack.title = " \n"
        events.append(event(invalidTrack, at: now, seconds: 60))
        invalidTrack.title = "Invalid duration"
        invalidTrack.duration = .nan
        events.append(event(invalidTrack, at: now, seconds: 60))
        let firstCheckpoint = event(track("duplicate-session"), at: now, seconds: 5)
        var duplicate = firstCheckpoint
        duplicate.listenedSeconds = 90
        events += [firstCheckpoint, duplicate]

        discovery.refresh(events: events, overrides: [:], enabled: true, now: now)
        await discovery.waitForChecks()

        XCTAssertEqual(Set(provider.requests.values.map(\.id)), ["long", "short", "unknown-duration", "boundary"])
        XCTAssertEqual(discovery.results.count, 4)
        XCTAssertEqual(ListeningAnalytics.summary(events: events, for: .month, now: now,
                                                 calendar: libraryTestCalendar()).plays, 4)
        XCTAssertFalse(discovery.hasPendingChecks)
        XCTAssertFalse(discovery.hadFailures)
    }

    func testDuplicateRecordingsAndFiveSecondCheckpointsKeepUsefulFlights() async throws {
        let clock = makeClock()
        let provider = gatedLyrics()
        let discovery = makeDiscovery(provider, clock: clock)
        var listening = event(track("checkpoint"), at: clock.now(), seconds: 30)
        let earlierSession = event(listening.track, at: clock.now().addingTimeInterval(-60), seconds: 90)
        discovery.refresh(events: [listening, listening, earlierSession], overrides: [:], enabled: true, now: clock.now())
        let original = try await provider.requests.request(at: 0)

        for _ in 0..<20 {
            clock.advance(5)
            listening.listenedSeconds += 5
            discovery.refresh(events: [listening, listening, earlierSession], overrides: [:], enabled: true, now: clock.now())
        }
        let fresh = event(track("newly-qualified"), at: clock.now(), seconds: 30)
        discovery.refresh(events: [listening, fresh], overrides: [:], enabled: true, now: clock.now())
        let added = try await provider.requests.request(at: 1)
        XCTAssertEqual(added.input.id, fresh.track.id)
        let cancellations = await provider.requests.cancellations
        XCTAssertTrue(cancellations.isEmpty)
        try await provider.requests.complete(original, with: .success(ArtistSpotlightTestSupport.document(original.input)))
        try await provider.requests.complete(added, with: .success(ArtistSpotlightTestSupport.document(added.input)))
        await discovery.waitForChecks()

        for _ in 0..<5 {
            clock.advance(5)
            discovery.refresh(events: [listening, fresh], overrides: [:], enabled: true, now: clock.now())
            await discovery.waitForChecks()
        }
        let requests = await provider.requests.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(discovery.results.count, 2)
        XCTAssertTrue(discovery.results.values.allSatisfy { $0.language == .english })
    }

    func testDistinctRecordingIDsWithIdenticalMetadataAreCheckedSeparately() async throws {
        let clock = makeClock()
        let provider = ListeningDiscoveryLyrics()
        let discovery = makeDiscovery(provider, clock: clock)
        let first = track("one-recording")
        var second = first
        second.id = "another-recording"
        XCTAssertEqual(LyricsMatcher.RecordingKey(first), LyricsMatcher.RecordingKey(second))
        let events = [first, second].map { event($0, at: clock.now(), seconds: 30) }
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(Set(provider.requests.values.map(\.id)), [first.id, second.id])
        XCTAssertEqual(discovery.results.count, 2)
    }

    func testInputsAreSnapshotsAndChangedRecordingMetadataInvalidatesReuse() async throws {
        let clock = makeClock()
        let provider = ListeningDiscoveryLyrics()
        let discovery = makeDiscovery(provider, clock: clock)
        let original = track("metadata")
        var events = [event(original, at: clock.now(), seconds: 30)]
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        events[0].track.title = "Changed outside the last refresh"
        await discovery.waitForChecks()
        XCTAssertEqual(discovery.results[LyricsRequestKey(original)]?.language, .english)
        XCTAssertNil(discovery.results[LyricsRequestKey(events[0].track)])

        var variants = [events[0].track]
        var changed = original
        changed.artists = ["Another credited singer"]
        variants.append(changed)
        changed = original
        changed.albumTitle = "Another release"
        variants.append(changed)
        changed = original
        changed.duration = 201
        variants.append(changed)
        for changed in variants {
            discovery.refresh(events: [event(changed, at: clock.now(), seconds: 30)], overrides: [:],
                              enabled: true, now: clock.now())
            XCTAssertTrue(discovery.results.isEmpty)
            await discovery.waitForChecks()
            XCTAssertEqual(Set(discovery.results.keys), [LyricsRequestKey(changed)])
        }
        XCTAssertEqual(provider.requests.values.count, 5)
    }

    func testOverridesAndVerifiedTrackMetadataSkipLyricsAndMetadataLookups() async throws {
        let clock = makeClock()
        let provider = ListeningDiscoveryLyrics()
        let metadataCalls = CatalogTestRecorder<Track>()
        let discovery = makeDiscovery(provider, clock: clock, metadataLookup: { recording in
            metadataCalls.record(recording)
            return nil
        })
        var english = track("verified-english")
        english.language = .english
        var hindi = track("verified-hindi")
        hindi.language = .hindi
        let corrected = track("corrected-bengali")
        let unclassified = track("corrected-unclassified")
        let overrides = [corrected.id: "bn", unclassified.id: "unclassified"]
        let events = [english, hindi, corrected, unclassified].map { event($0, at: clock.now(), seconds: 30) }

        discovery.refresh(events: events, overrides: overrides, enabled: true, now: clock.now())
        await discovery.waitForChecks()

        XCTAssertTrue(provider.requests.values.isEmpty)
        XCTAssertTrue(metadataCalls.values.isEmpty)
        XCTAssertTrue(discovery.results.isEmpty)
        XCTAssertFalse(discovery.isChecking)
        XCTAssertFalse(discovery.hasPendingChecks)
        XCTAssertEqual(overrides[corrected.id], "bn")
    }

    func testCorrectionDuringFlightCancelsAndCannotBecomeAutomaticEvidence() async throws {
        let clock = makeClock()
        let provider = gatedLyrics()
        let discovery = makeDiscovery(provider, clock: clock)
        let listening = event(track("corrected"), at: clock.now(), seconds: 30)
        discovery.refresh(events: [listening], overrides: [:], enabled: true, now: clock.now())
        let stale = try await provider.requests.request(at: 0)
        discovery.refresh(events: [listening], overrides: [listening.track.id: "bn"], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        try await AppModelFixtures.eventually { await provider.requests.cancellations.contains(stale.id) }
        try await provider.requests.complete(stale, with: .success(ArtistSpotlightTestSupport.document(stale.input)))
        await Task.yield()

        XCTAssertTrue(discovery.results.isEmpty)
        XCTAssertFalse(discovery.hadFailures)
        var confirmed = listening
        confirmed.track.language = .hindi
        discovery.refresh(events: [confirmed], overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        let requests = await provider.requests.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testChangedMetadataRejectsAnOlderCancellationIgnoringResponse() async throws {
        let clock = makeClock()
        let provider = gatedLyrics()
        let discovery = makeDiscovery(provider, clock: clock)
        let original = track("reused-id")
        var changed = original
        changed.title = "Corrected recording title"
        changed.duration = 180
        discovery.refresh(events: [event(original, at: clock.now(), seconds: 30)], overrides: [:],
                          enabled: true, now: clock.now())
        let stale = try await provider.requests.request(at: 0)
        discovery.refresh(events: [event(changed, at: clock.now(), seconds: 30)], overrides: [:],
                          enabled: true, now: clock.now())
        let current = try await provider.requests.request(at: 1)
        try await provider.requests.complete(current, with: .success(ArtistSpotlightTestSupport.document(current.input)))
        await discovery.waitForChecks()
        try await provider.requests.complete(stale, with: .success(ArtistSpotlightTestSupport.document(stale.input,
                                                                                                  text: ArtistSpotlightFixtures.tamilText)))
        await Task.yield()
        XCTAssertNil(discovery.results[LyricsRequestKey(original)])
        XCTAssertEqual(discovery.results[LyricsRequestKey(changed)], .identified(.english, source: .matchedLyrics))
        XCTAssertFalse(discovery.hadFailures)
    }

    func testMissingAndFailedChecksHaveFiveMinuteCooldownsAndLaterRetry() async throws {
        for failed in [false, true] {
            let clock = makeClock()
            let provider = gatedLyrics()
            let discovery = makeDiscovery(provider, clock: clock)
            let recording = track("cooldown")
            let listening = event(recording, at: clock.now(), seconds: 30)
            if failed { await provider.requests.enqueue(.failure(MusicServiceError.network("Synthetic failure"))) }
            else { await provider.requests.enqueue(.success(LyricsDocument(trackID: recording.id, kind: .unavailable))) }
            discovery.refresh(events: [listening], overrides: [:], enabled: true, now: clock.now())
            await discovery.waitForChecks()
            XCTAssertEqual(discovery.results[LyricsRequestKey(recording)], .unclassified(failed ? .lookupFailed : .noMatchedLyrics))
            XCTAssertEqual(discovery.hadFailures, failed)
            XCTAssertFalse(discovery.hasPendingChecks)

            clock.advance(299)
            discovery.refresh(events: [listening], overrides: [:], enabled: true, now: clock.now())
            await discovery.waitForChecks()
            let cachedRequests = await provider.requests.requests
            XCTAssertEqual(cachedRequests.count, 1)
            clock.advance(1)
            await provider.requests.enqueue(.success(ArtistSpotlightTestSupport.document(recording)))
            discovery.refresh(events: [listening], overrides: [:], enabled: true, now: clock.now())
            await discovery.waitForChecks()
            let retried = await provider.requests.requests
            XCTAssertEqual(retried.count, 2)
            XCTAssertEqual(discovery.results[LyricsRequestKey(recording)]?.language, .english)
            XCTAssertFalse(discovery.hadFailures)
        }
    }

    func testUnexpectedSourceCancellationAlsoGetsFailureCooldown() async throws {
        let clock = makeClock()
        let provider = ListeningDiscoveryLyrics { _ in throw CancellationError() }
        let discovery = makeDiscovery(provider, clock: clock)
        let events = [event(track("source-cancelled"), at: clock.now(), seconds: 30)]
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(provider.requests.values.count, 1)
        XCTAssertEqual(discovery.results.values.first, .unclassified(.lookupFailed))
        XCTAssertTrue(discovery.hadFailures)
    }

    func testLikelyEvidenceRemainsUnclassifiedAndUsesTheNegativeLifetime() async throws {
        let clock = makeClock()
        let provider = ListeningDiscoveryLyrics { LyricsDocument(trackID: $0.id, kind: .unavailable) }
        let discovery = makeDiscovery(provider, clock: clock)
        let recording = ArtistSpotlightTestSupport.track("suggestion", title: "A paper lantern (Tamil)")
        let events = [event(recording, at: clock.now(), seconds: 30)]
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(discovery.results[LyricsRequestKey(recording)], .likely(.tamil, source: .titleLabel))
        XCTAssertNil(discovery.results[LyricsRequestKey(recording)]?.language)
        clock.advance(299)
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(provider.requests.values.count, 1)
        clock.advance(1)
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(provider.requests.values.count, 2)
        XCTAssertFalse(discovery.hadFailures)
    }

    func testPositiveEvidenceIsReusedForTwelveHours() async throws {
        let clock = makeClock()
        let provider = ListeningDiscoveryLyrics()
        let discovery = makeDiscovery(provider, clock: clock)
        let events = [event(track("positive"), at: clock.now(), seconds: 30)]
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        clock.advance(12 * 60 * 60 - 1)
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(provider.requests.values.count, 1)
        clock.advance(1)
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(provider.requests.values.count, 2)
        XCTAssertEqual(discovery.results.values.first?.language, .english)
    }

    func testEachRefreshHasTwelveChecksAndAtMostTwoServiceSlotsWithRecentTracksFirst() async throws {
        let clock = makeClock()
        let provider = gatedLyrics()
        let service = makeService(provider, clock: clock)
        let discovery = ListeningLanguageDiscovery(service: service, now: { clock.now() })
        let events = (0..<40).map { event(track("priority-\($0)"), at: clock.now().addingTimeInterval(-Double($0)), seconds: 30) }
        discovery.refresh(events: events.reversed(), overrides: [:], enabled: true, now: clock.now())
        let first = try await provider.requests.request(at: 0)
        let second = try await provider.requests.request(at: 1)
        XCTAssertEqual(Set([first.input.id, second.input.id]), ["priority-0", "priority-1"])

        for index in 0..<12 {
            let request = try await provider.requests.request(at: index)
            let activity = await service.activity
            XCTAssertLessThanOrEqual(activity.activeLookups, 2)
            XCTAssertLessThanOrEqual(discovery.activity.activeLookups, 2)
            try await provider.requests.complete(request, with: .success(ArtistSpotlightTestSupport.document(request.input)))
        }
        await discovery.waitForChecks()
        let firstPass = await provider.requests.requests
        XCTAssertEqual(firstPass.count, 12)
        XCTAssertEqual(Set(firstPass.map(\.input.id)), Set((0..<12).map { "priority-\($0)" }))
        XCTAssertEqual(discovery.results.count, 12)
        XCTAssertTrue(discovery.results.values.allSatisfy { $0.language == .english })
        XCTAssertTrue(discovery.hasPendingChecks)
        XCTAssertFalse(discovery.isChecking)
        XCTAssertFalse(discovery.hadFailures)

        clock.advance(5)
        let latest = event(track("brand-new"), at: clock.now(), seconds: 30)
        discovery.refresh(events: events + [latest], overrides: [:], enabled: true, now: clock.now())
        let a = try await provider.requests.request(at: 12)
        let b = try await provider.requests.request(at: 13)
        XCTAssertEqual(Set([a.input.id, b.input.id]), ["brand-new", "priority-12"])
        for index in 12..<24 {
            let request = try await provider.requests.request(at: index)
            try await provider.requests.complete(request, with: .success(ArtistSpotlightTestSupport.document(request.input)))
        }
        await discovery.waitForChecks()
        await Task.yield()
        let all = await provider.requests.requests
        XCTAssertEqual(all.count, 24)
        XCTAssertEqual(discovery.results.count, 24)
        XCTAssertFalse(discovery.hadFailures)
    }

    func testSynchronousProjectionRefreshCannotTurnOnePassIntoAnAutomaticLoop() async throws {
        let clock = makeClock()
        let provider = ListeningDiscoveryLyrics()
        let discovery = makeDiscovery(provider, clock: clock)
        let events = (0..<40).map { event(track("projection-\($0)"), at: clock.now(), seconds: 30) }
        discovery.onResultsChanged = { [weak discovery] in
            discovery?.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        }
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(provider.requests.values.count, 12)
        XCTAssertEqual(discovery.results.count, 12)
        XCTAssertTrue(discovery.hasPendingChecks)
        XCTAssertFalse(discovery.isChecking)
    }

    func testCandidateCacheAndConfigurationCapsAreHardBounds() async throws {
        let clock = makeClock()
        let provider = gatedLyrics()
        var configuration = ListeningLanguageDiscovery.Configuration()
        configuration.batchSize = 999
        configuration.maximumConcurrentChecks = 999
        configuration.maximumPendingCandidates = 999
        configuration.maximumCacheEntries = 999
        let discovery = makeDiscovery(provider, clock: clock, configuration: configuration)
        let events = (0..<600).map { event(track("bounded-\($0)"), at: clock.now().addingTimeInterval(-Double($0)), seconds: 30) }
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        _ = try await provider.requests.request(at: 1)
        XCTAssertEqual(discovery.activity.snapshotRecordings, 512)
        XCTAssertEqual(discovery.activity.pendingCandidates, 128)
        XCTAssertEqual(discovery.activity.activeLookups, 2)
        discovery.pause()
        await discovery.waitForChecks()
        let cancelled = await provider.requests.requests
        for request in cancelled {
            try await provider.requests.complete(request, with: .success(ArtistSpotlightTestSupport.document(request.input)))
        }

        let smallProvider = ListeningDiscoveryLyrics()
        configuration.maximumCacheEntries = 4
        let small = makeDiscovery(smallProvider, clock: clock, configuration: configuration)
        small.refresh(events: Array(events.prefix(8)), overrides: [:], enabled: true, now: clock.now())
        await small.waitForChecks()
        XCTAssertEqual(small.results.count, 4)
        XCTAssertEqual(small.activity.cachedRecordings, 4)
        small.refresh(events: Array(events.prefix(8)), overrides: [:], enabled: true, now: clock.now())
        await small.waitForChecks()
        XCTAssertEqual(smallProvider.requests.values.count, 4)
        clock.advance(1)
        let latest = event(track("bounded-new"), at: clock.now(), seconds: 30)
        small.refresh(events: Array(events.prefix(8)) + [latest], overrides: [:], enabled: true, now: clock.now())
        await small.waitForChecks()
        XCTAssertEqual(smallProvider.requests.values.count, 5)
        XCTAssertEqual(small.results.count, 4)
        XCTAssertNil(small.results[LyricsRequestKey(events[3].track)])
    }

    func testPauseKeepsSavedStatsEvidenceAndPersistsOnlyAlreadyCompletedChecks() async throws {
        let clock = makeClock()
        let provider = gatedLyrics()
        let url = try cacheURL()
        let discovery = makeDiscovery(provider, clock: clock, cacheURL: url)
        let events = [event(track("accepted"), at: clock.now(), seconds: 60),
                      event(track("pending"), at: clock.now().addingTimeInterval(-1), seconds: 40)]
        let summary = ListeningAnalytics.summary(events: events, for: .month, now: clock.now())
        var publications = 0
        discovery.onResultsChanged = { publications += 1 }
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        let a = try await provider.requests.request(at: 0)
        let b = try await provider.requests.request(at: 1)
        let accepted = a.input.id == "accepted" ? a : b
        let pending = a.input.id == "pending" ? a : b
        try await provider.requests.complete(accepted, with: .success(ArtistSpotlightTestSupport.document(accepted.input)))
        try await AppModelFixtures.eventually { discovery.results.count == 1 }
        let evidence = discovery.results
        discovery.pause()
        await discovery.waitForChecks()
        try await provider.requests.complete(pending, with: .success(ArtistSpotlightTestSupport.document(pending.input)))
        await Task.yield()

        XCTAssertEqual(discovery.results, evidence)
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(discovery.isChecking)
        XCTAssertFalse(discovery.hasPendingChecks)
        XCTAssertFalse(discovery.hadFailures)
        let after = ListeningAnalytics.summary(events: events, for: .month, now: clock.now())
        XCTAssertEqual(after.seconds, summary.seconds)
        XCTAssertEqual(after.plays, summary.plays)
        let stored = await ListeningLanguageDiscoveryCache(url: url).load()
        XCTAssertEqual(stored.entries.map(\.key.id), ["accepted"])
    }

    func testResetDisableAndEmptyHistoryBlockLateLyricsAndMetadataPublication() async throws {
        for boundary in 0..<3 {
            let clock = makeClock()
            let provider = gatedLyrics()
            let metadata = AppModelRequestGate<Track, ArtistSongLanguageResult?>()
            addTeardownBlock { await metadata.close() }
            let discovery = makeDiscovery(provider, clock: clock, metadataLookup: { try await metadata.receive($0) })
            let events = [event(track("privacy-boundary"), at: clock.now(), seconds: 30)]
            var publications = 0
            discovery.onResultsChanged = { publications += 1 }
            discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
            let lyricsRequest = try await provider.requests.request(at: 0)
            let metadataRequest = try await metadata.request(at: 0)
            switch boundary {
            case 0: discovery.reset()
            case 1: discovery.refresh(events: events, overrides: [:], enabled: false, now: clock.now())
            default: discovery.refresh(events: [], overrides: [:], enabled: true, now: clock.now())
            }
            await discovery.waitForChecks()
            try await AppModelFixtures.eventually {
                let lyricsCancelled = await provider.requests.cancellations.contains(lyricsRequest.id)
                let metadataCancelled = await metadata.cancellations.contains(metadataRequest.id)
                return lyricsCancelled && metadataCancelled
            }
            try await provider.requests.complete(lyricsRequest, with: .success(ArtistSpotlightTestSupport.document(lyricsRequest.input)))
            try await metadata.complete(metadataRequest, with: .success(work(.bengali)))
            await Task.yield()
            XCTAssertTrue(discovery.results.isEmpty)
            XCTAssertEqual(publications, 0)
            XCTAssertFalse(discovery.isChecking)
            XCTAssertFalse(discovery.hasPendingChecks)
            XCTAssertFalse(discovery.hadFailures)
        }
    }

    func testResetDoesNotLetAnOldResponseReplaceANewerFlightForTheSameKey() async throws {
        let clock = makeClock()
        let provider = gatedLyrics()
        let discovery = makeDiscovery(provider, clock: clock, cacheURL: try cacheURL())
        let events = [event(track("reset-and-resume"), at: clock.now(), seconds: 30)]
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        let stale = try await provider.requests.request(at: 0)
        discovery.reset()
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        let current = try await provider.requests.request(at: 1)
        try await provider.requests.complete(current, with: .success(ArtistSpotlightTestSupport.document(current.input)))
        await discovery.waitForChecks()
        try await provider.requests.complete(stale, with: .success(ArtistSpotlightTestSupport.document(stale.input,
                                                                                                  text: ArtistSpotlightFixtures.tamilText)))
        await Task.yield()
        XCTAssertEqual(discovery.results.values.first, .identified(.english, source: .matchedLyrics))
        XCTAssertEqual(discovery.cacheStatus, .saved)
        XCTAssertFalse(discovery.hadFailures)
    }

    func testDiscoveryDeinitCancelsChecksWithoutRetainingTheOwner() async throws {
        let clock = makeClock()
        let provider = gatedLyrics()
        var discovery: ListeningLanguageDiscovery? = makeDiscovery(provider, clock: clock)
        weak var weakDiscovery = discovery
        var publications = 0
        discovery?.onResultsChanged = { publications += 1 }
        discovery?.refresh(events: [event(track("owner-release"), at: clock.now(), seconds: 30)], overrides: [:],
                           enabled: true, now: clock.now())
        let pending = try await provider.requests.request(at: 0)
        discovery = nil
        XCTAssertNil(weakDiscovery)
        try await AppModelFixtures.eventually { await provider.requests.cancellations.contains(pending.id) }
        try await provider.requests.complete(pending, with: .success(ArtistSpotlightTestSupport.document(pending.input)))
        await Task.yield()
        XCTAssertEqual(publications, 0)
    }

    func testRestartReusesOnlyTheMetadataAwareMinimalDerivedCache() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        let provider = ListeningDiscoveryLyrics { LyricsDocument(trackID: $0.id, kind: .unavailable) }
        let evidence = work(.bengali)
        let first = makeDiscovery(provider, clock: clock, cacheURL: url, metadataLookup: { _ in evidence })
        var recording = track("restart")
        recording.playCount = 987_654
        recording.artworkURL = URL(string: "https://example.invalid/private-artwork?token=not-a-cache-field")
        let events = [event(recording, at: clock.now().addingTimeInterval(-600), seconds: 123)]
        first.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await first.waitForChecks()
        XCTAssertEqual(first.results[LyricsRequestKey(recording)], evidence)
        XCTAssertEqual(first.cacheStatus, .saved)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "entries"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let encodedEntries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(encodedEntries.count, 1)
        XCTAssertEqual(Set(encodedEntries[0].keys), ["key", "result", "checkedAt", "expiresAt"])
        let text = String(decoding: data, as: UTF8.self)
        for excluded in ["listenedSeconds", "startedAt", "playCount", "artworkURL", "not-a-cache-field", "recordingLanguageOverrides"] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
        XCTAssertLessThanOrEqual(data.count, 2 * 1024 * 1024)

        let restartProvider = ListeningDiscoveryLyrics()
        let metadataCalls = CatalogTestRecorder<Track>()
        let restarted = makeDiscovery(restartProvider, clock: clock, cacheURL: url, metadataLookup: {
            metadataCalls.record($0)
            return nil
        })
        restarted.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await restarted.waitForChecks()
        XCTAssertEqual(restarted.results[LyricsRequestKey(recording)], evidence)
        XCTAssertTrue(restartProvider.requests.values.isEmpty)
        XCTAssertTrue(metadataCalls.values.isEmpty)
        XCTAssertEqual(restarted.cacheStatus, .loaded)

        recording.title = "Different metadata for the reused ID"
        restarted.refresh(events: [event(recording, at: clock.now(), seconds: 30)], overrides: [:], enabled: true, now: clock.now())
        await restarted.waitForChecks()
        XCTAssertEqual(restartProvider.requests.values.count, 1)
        XCTAssertEqual(restarted.results[LyricsRequestKey(recording)]?.language, .english)
        XCTAssertEqual(restarted.results.count, 1)
    }

    func testDisabledColdLaunchHydratesOnlyAllowedCacheEvidenceWithoutCheckingSources() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        let saved = track("disabled-saved")
        let removed = track("disabled-removed")
        let expired = track("disabled-expired")
        let oldMetadata = track("disabled-metadata")
        var changed = oldMetadata
        changed.title = "Corrected recording metadata"
        let corrected = track("disabled-correction")
        var verified = track("disabled-verified")
        verified.language = .hindi
        let evidence = work(.bengali)
        let bytes = try cacheData([
            cacheEntry(saved, result: evidence, checked: clock.now()),
            cacheEntry(removed, checked: clock.now()),
            cacheEntry(expired, checked: clock.now().addingTimeInterval(-12 * 60 * 60)),
            cacheEntry(oldMetadata, checked: clock.now()),
            cacheEntry(corrected, checked: clock.now()),
            cacheEntry(verified, checked: clock.now())
        ])
        try bytes.write(to: url)
        let provider = ListeningDiscoveryLyrics()
        let metadataCalls = CatalogTestRecorder<Track>()
        let discovery = makeDiscovery(provider, clock: clock, cacheURL: url, metadataLookup: {
            metadataCalls.record($0)
            return nil
        })
        let events = [saved, expired, changed, corrected, verified, track("disabled-uncached")]
            .map { event($0, at: clock.now(), seconds: 30) }
        var publications = 0
        discovery.onResultsChanged = { publications += 1 }

        discovery.refresh(events: events, overrides: [corrected.id: "ta"], enabled: false, now: clock.now())
        XCTAssertFalse(discovery.isChecking)
        XCTAssertFalse(discovery.hasPendingChecks)
        await discovery.waitForChecks()

        XCTAssertEqual(discovery.results, [LyricsRequestKey(saved): evidence])
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(discovery.cacheStatus, .loaded)
        XCTAssertEqual(discovery.activity.activeLookups, 0)
        XCTAssertTrue(provider.requests.values.isEmpty)
        XCTAssertTrue(metadataCalls.values.isEmpty)
        XCTAssertFalse(discovery.isChecking)
        XCTAssertFalse(discovery.hasPendingChecks)
        XCTAssertFalse(discovery.hadFailures)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testDisabledRefreshRemovesEvidenceForRemovedHistoryWithoutRewritingCache() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        let first = track("disabled-first")
        let second = track("disabled-second")
        let bytes = try cacheData([cacheEntry(first, checked: clock.now()), cacheEntry(second, checked: clock.now())])
        try bytes.write(to: url)
        let provider = ListeningDiscoveryLyrics()
        let discovery = makeDiscovery(provider, clock: clock, cacheURL: url)
        let events = [first, second].map { event($0, at: clock.now(), seconds: 30) }
        var publications = 0
        discovery.onResultsChanged = { publications += 1 }
        discovery.refresh(events: events, overrides: [:], enabled: false, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(discovery.results.count, 2)

        discovery.refresh(events: [events[1]], overrides: [:], enabled: false, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertNil(discovery.results[LyricsRequestKey(first)])
        XCTAssertEqual(discovery.results[LyricsRequestKey(second)], .identified(.english, source: .matchedLyrics))
        discovery.pause()
        await discovery.waitForChecks()
        XCTAssertEqual(discovery.results.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        discovery.refresh(events: [], overrides: [:], enabled: false, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertTrue(discovery.results.isEmpty)
        XCTAssertEqual(publications, 3)
        XCTAssertEqual(discovery.cacheStatus, .loaded)
        XCTAssertTrue(provider.requests.values.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testPendingDisabledHydrationUsesTheLatestSavedHistorySnapshot() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        let original = track("disabled-original-snapshot")
        let latest = track("disabled-latest-snapshot")
        let bytes = try cacheData([cacheEntry(original, checked: clock.now()), cacheEntry(latest, checked: clock.now())])
        try bytes.write(to: url)
        let provider = ListeningDiscoveryLyrics()
        let discovery = makeDiscovery(provider, clock: clock, cacheURL: url)
        var publications: [Set<LyricsRequestKey>] = []
        discovery.onResultsChanged = { [weak discovery] in
            if let discovery { publications.append(Set(discovery.results.keys)) }
        }
        discovery.refresh(events: [event(original, at: clock.now(), seconds: 30)], overrides: [:], enabled: false, now: clock.now())
        discovery.refresh(events: [event(latest, at: clock.now(), seconds: 30)], overrides: [:], enabled: false, now: clock.now())
        await discovery.waitForChecks()

        XCTAssertEqual(publications, [Set([LyricsRequestKey(latest)])])
        XCTAssertEqual(Set(discovery.results.keys), [LyricsRequestKey(latest)])
        XCTAssertTrue(provider.requests.values.isEmpty)
        XCTAssertFalse(discovery.isChecking)
        XCTAssertFalse(discovery.hasPendingChecks)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testPauseRetiresPendingDisabledHydrationWithoutRestartingIt() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        let recording = track("disabled-paused-read")
        let bytes = try cacheData([cacheEntry(recording, checked: clock.now())])
        try bytes.write(to: url)
        let provider = ListeningDiscoveryLyrics()
        let discovery = makeDiscovery(provider, clock: clock, cacheURL: url)
        var publications = 0
        discovery.onResultsChanged = { publications += 1 }
        discovery.pause()
        await discovery.waitForChecks()
        XCTAssertEqual(discovery.cacheStatus, .notLoaded)
        discovery.refresh(events: [event(recording, at: clock.now(), seconds: 30)], overrides: [:], enabled: false, now: clock.now())
        discovery.pause()
        await discovery.waitForChecks()
        await Task.yield()
        XCTAssertTrue(discovery.results.isEmpty)
        XCTAssertEqual(discovery.cacheStatus, .notLoaded)
        XCTAssertEqual(publications, 0)

        discovery.refresh(events: [], overrides: [:], enabled: false, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertTrue(discovery.results.isEmpty)
        XCTAssertEqual(discovery.cacheStatus, .loaded)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(provider.requests.values.isEmpty)
        XCTAssertFalse(discovery.isChecking)
        XCTAssertFalse(discovery.hasPendingChecks)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testRestartKeepsFailureCooldownAndExpiredEntriesAreRetried() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        let offline = ListeningDiscoveryLyrics { _ in throw MusicServiceError.network("Synthetic offline source") }
        let first = makeDiscovery(offline, clock: clock, cacheURL: url)
        let events = [event(track("restart-failure"), at: clock.now(), seconds: 30)]
        first.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await first.waitForChecks()
        XCTAssertEqual(first.cacheStatus, .saved)
        clock.advance(299)
        let recovered = ListeningDiscoveryLyrics()
        let restarted = makeDiscovery(recovered, clock: clock, cacheURL: url)
        restarted.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await restarted.waitForChecks()
        XCTAssertTrue(recovered.requests.values.isEmpty)
        XCTAssertTrue(restarted.hadFailures)
        XCTAssertEqual(restarted.results.values.first, .unclassified(.lookupFailed))
        clock.advance(1)
        restarted.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await restarted.waitForChecks()
        XCTAssertEqual(recovered.requests.values.count, 1)
        XCTAssertEqual(restarted.results.values.first?.language, .english)
        XCTAssertFalse(restarted.hadFailures)
    }

    func testFutureCheckedCacheIsNotReusedAfterClockRollback() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        let recording = track("future-check")
        let future = cacheEntry(recording, result: .identified(.tamil, source: .matchedLyrics),
                                checked: clock.now().addingTimeInterval(60))
        try cacheData([future]).write(to: url)
        let provider = ListeningDiscoveryLyrics()
        let discovery = makeDiscovery(provider, clock: clock, cacheURL: url)
        discovery.refresh(events: [event(recording, at: clock.now(), seconds: 30)], overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(provider.requests.values.count, 1)
        XCTAssertEqual(discovery.results.values.first, .identified(.english, source: .matchedLyrics))
    }

    func testCorruptUnsupportedNewerAndOversizeCachesAreIgnoredAndPreserved() async throws {
        let clock = makeClock()
        let invalid = [Data("{truncated".utf8), Data(#"{"schemaVersion":0,"entries":[]}"#.utf8),
                       Data(#"{"schemaVersion":999,"entries":[]}"#.utf8),
                       Data(#"{"anotherCache":[]}"#.utf8), Data(repeating: 32, count: 2 * 1024 * 1024 + 1)]
        for bytes in invalid {
            let url = try cacheURL()
            try bytes.write(to: url)
            let provider = ListeningDiscoveryLyrics()
            let discovery = makeDiscovery(provider, clock: clock, cacheURL: url)
            discovery.refresh(events: [event(track("untrusted-cache"), at: clock.now(), seconds: 30)], overrides: [:],
                              enabled: true, now: clock.now())
            await discovery.waitForChecks()
            XCTAssertEqual(discovery.results.values.first?.language, .english)
            XCTAssertEqual(discovery.cacheStatus, .ignored)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testCacheRejectsInvalidCountsDatesStringsAndAuthoritativeSources() async throws {
        let clock = makeClock()
        let recording = track("invalid-entry")
        let valid = cacheEntry(recording, checked: clock.now())
        var longID = recording
        longID.id = String(repeating: "x", count: 513)
        var excessiveArtists = recording
        excessiveArtists.artists = (0..<33).map { "Credited singer \($0)" }
        let invalid: [[ListeningLanguageDiscoveryCache.Entry]] = [
            Array(repeating: valid, count: 513), [valid, valid],
            [cacheEntry(recording, checked: Date(timeIntervalSince1970: -1))],
            [cacheEntry(recording, checked: clock.now(), lifetime: 0)],
            [cacheEntry(recording, checked: clock.now(), lifetime: 12 * 60 * 60 + 1)],
            [cacheEntry(longID, checked: clock.now())], [cacheEntry(excessiveArtists, checked: clock.now())],
            [cacheEntry(recording, result: .identified(.hindi, source: .userOverride), checked: clock.now())],
            [cacheEntry(recording, result: .identified(.hindi, source: .recordingMetadata), checked: clock.now())],
            [cacheEntry(recording, result: .unclassified(.lookupFailed), checked: clock.now(), lifetime: 301)],
            [cacheEntry(recording, result: .identified(.english, source: .musicBrainzWork(recordingID: "invalid", workID: "invalid")),
                        checked: clock.now())]
        ]
        for entries in invalid {
            let url = try cacheURL()
            let bytes = try cacheData(entries)
            try bytes.write(to: url)
            let cache = ListeningLanguageDiscoveryCache(url: url)
            let loaded = await cache.load()
            XCTAssertEqual(loaded.status, .ignored)
            XCTAssertTrue(loaded.entries.isEmpty)
            let saved = await cache.save([valid], revision: 1)
            XCTAssertEqual(saved, .ignored)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        let unknown = String(decoding: try cacheData([valid]), as: UTF8.self)
            .replacingOccurrences(of: "matchedLyrics", with: "futureEvidence")
        let url = try cacheURL()
        try Data(unknown.utf8).write(to: url)
        let loaded = await ListeningLanguageDiscoveryCache(url: url).load()
        XCTAssertEqual(loaded.status, .ignored)
    }

    func testLatestCacheWriteWinsAndResetFencesDelayedSaves() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        let cache = ListeningLanguageDiscoveryCache(url: url)
        let english = cacheEntry(track("ordered-writes"), checked: clock.now())
        let bengali = cacheEntry(track("ordered-writes"), result: work(.bengali), checked: clock.now())
        let gate = LyricsTestGate()
        let delayed = Task {
            await gate.wait()
            return await cache.save([english], revision: 1)
        }
        let newer = await cache.save([bengali], revision: 2)
        XCTAssertEqual(newer, .saved)
        await gate.open()
        let obsolete = await delayed.value
        XCTAssertEqual(obsolete, .superseded)
        let readback = await ListeningLanguageDiscoveryCache(url: url).load()
        XCTAssertEqual(readback.entries.first?.result, bengali.result)

        let resetGate = LyricsTestGate()
        let preReset = Task {
            await resetGate.wait()
            return await cache.save([bengali], revision: 3)
        }
        let cleared = await cache.reset(revision: 4)
        XCTAssertEqual(cleared, .cleared)
        await resetGate.open()
        let stale = await preReset.value
        XCTAssertEqual(stale, .superseded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let afterReset = await cache.save([english], revision: 6)
        XCTAssertEqual(afterReset, .saved)
        let olderReset = await cache.reset(revision: 5)
        XCTAssertEqual(olderReset, .superseded)
        let current = await ListeningLanguageDiscoveryCache(url: url).load()
        XCTAssertEqual(current.entries.first?.result, english.result)
        let cancellationGate = LyricsTestGate()
        let cancelledReset = Task {
            await cancellationGate.wait()
            return await cache.reset(revision: 7)
        }
        cancelledReset.cancel()
        await cancellationGate.open()
        let resetOutcome = await cancelledReset.value
        XCTAssertEqual(resetOutcome, .cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testResetDuringInitialCacheLoadCannotPublishSavedEvidence() async throws {
        for enabled in [true, false] {
            let clock = makeClock()
            let url = try cacheURL()
            let recording = track("cancelled-cache-read")
            try cacheData([cacheEntry(recording, checked: clock.now())]).write(to: url)
            let provider = ListeningDiscoveryLyrics()
            let discovery = makeDiscovery(provider, clock: clock, cacheURL: url)
            var publications = 0
            discovery.onResultsChanged = { publications += 1 }
            let events = [event(recording, at: clock.now(), seconds: 30)]
            discovery.refresh(events: events, overrides: [:], enabled: enabled, now: clock.now())
            discovery.reset()
            discovery.refresh(events: events, overrides: [:], enabled: false, now: clock.now())
            await discovery.waitForChecks()
            XCTAssertEqual(publications, 0)
            XCTAssertTrue(discovery.results.isEmpty)
            XCTAssertTrue(provider.requests.values.isEmpty)
            XCTAssertEqual(discovery.cacheStatus, .cleared)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testQueuedPrivacyResetSurvivesOwnerReleaseAndOnlyRemovesItsCache() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        try cacheData([cacheEntry(track("remove-owned-cache"), checked: clock.now())]).write(to: url)
        let libraryURL = url.deletingLastPathComponent().appendingPathComponent(LibraryPersistence.fileName)
        let libraryBytes = try LibraryPersistence.encode(LibraryDocument())
        try libraryBytes.write(to: libraryURL)
        var discovery: ListeningLanguageDiscovery? = makeDiscovery(ListeningDiscoveryLyrics(), clock: clock, cacheURL: url)
        weak var weakDiscovery = discovery
        discovery?.reset()
        discovery = nil
        XCTAssertNil(weakDiscovery)
        try await AppModelFixtures.eventually { !FileManager.default.fileExists(atPath: url.path) }
        XCTAssertEqual(try Data(contentsOf: libraryURL), libraryBytes)
    }

    func testFailedCacheWriteCannotDamageTheLibraryOrClaimDurability() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        let libraryURL = url.deletingLastPathComponent().appendingPathComponent(LibraryPersistence.fileName)
        let libraryBytes = try LibraryPersistence.encode(LibraryDocument())
        try libraryBytes.write(to: libraryURL)
        let provider = gatedLyrics()
        let discovery = makeDiscovery(provider, clock: clock, cacheURL: url)
        discovery.refresh(events: [event(track("write-failure"), at: clock.now(), seconds: 30)], overrides: [:],
                          enabled: true, now: clock.now())
        let request = try await provider.requests.request(at: 0)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let marker = url.appendingPathComponent("preserve-this-file")
        let markerBytes = Data("Unrelated file inside an unexpected directory".utf8)
        try markerBytes.write(to: marker)
        try await provider.requests.complete(request, with: .success(ArtistSpotlightTestSupport.document(request.input)))
        await discovery.waitForChecks()
        XCTAssertEqual(discovery.results.values.first?.language, .english)
        XCTAssertEqual(discovery.cacheStatus, .failed)
        XCTAssertFalse(discovery.hadFailures)
        XCTAssertEqual(try Data(contentsOf: libraryURL), libraryBytes)
        discovery.reset()
        await discovery.waitForChecks()
        XCTAssertEqual(discovery.cacheStatus, .failed)
        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
        XCTAssertEqual(try Data(contentsOf: libraryURL), libraryBytes)
    }

    func testExternalCacheReplacementIsPreservedOnTheNextWrite() async throws {
        let clock = makeClock()
        let url = try cacheURL()
        let provider = ListeningDiscoveryLyrics()
        let discovery = makeDiscovery(provider, clock: clock, cacheURL: url)
        var events = [event(track("before-external-change"), at: clock.now(), seconds: 30)]
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        let replacement = Data(#"{"schemaVersion":99,"entries":[]}"#.utf8)
        try replacement.write(to: url, options: .atomic)
        events.append(event(track("after-external-change"), at: clock.now(), seconds: 30))
        discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
        await discovery.waitForChecks()
        XCTAssertEqual(discovery.results.count, 2)
        XCTAssertEqual(discovery.cacheStatus, .ignored)
        XCTAssertEqual(try Data(contentsOf: url), replacement)
    }

    func testNilCacheURLIsMemoryOnlyAndCannotLeakBetweenInstances() async throws {
        let clock = makeClock()
        let events = [event(track("isolated"), at: clock.now(), seconds: 30)]
        for _ in 0..<2 {
            let provider = ListeningDiscoveryLyrics()
            let discovery = makeDiscovery(provider, clock: clock)
            discovery.refresh(events: events, overrides: [:], enabled: false, now: clock.now())
            await discovery.waitForChecks()
            XCTAssertTrue(provider.requests.values.isEmpty)
            XCTAssertTrue(discovery.results.isEmpty)
            XCTAssertEqual(discovery.cacheStatus, .memoryOnly)
            discovery.refresh(events: events, overrides: [:], enabled: true, now: clock.now())
            await discovery.waitForChecks()
            XCTAssertEqual(provider.requests.values.count, 1)
            XCTAssertEqual(discovery.cacheStatus, .memoryOnly)
            discovery.reset()
            await discovery.waitForChecks()
            XCTAssertEqual(discovery.cacheStatus, .memoryOnly)
            XCTAssertTrue(discovery.results.isEmpty)
        }
    }

    func testSharedCodableTypesRoundTripWithoutChangingConfidenceOrTaxonomy() throws {
        let values: [ArtistSongLanguageResult] = ArtistSongLanguage.allCases.flatMap { language -> [ArtistSongLanguageResult] in
            [.identified(language, source: .matchedLyrics), .likely(language, source: .titleLabel)]
        } + [.identified(.english, source: .recordingMetadata), .identified(.hindi, source: .linkedLyrics),
             .likely(.tamil, source: .lyricsScript), .likely(.telugu, source: .titleScript), work(.bengali),
             .identified(.hindi, source: .userOverride), .unclassified(.noMatchedLyrics), .unclassified(.insufficientText),
             .unclassified(.uncertainLanguage), .unclassified(.lookupFailed), .unclassified(.conflictingEvidence),
             .unclassified(.userOverride)]
        let encoded = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([ArtistSongLanguageResult].self, from: encoded)
        XCTAssertEqual(decoded, values)
        XCTAssertTrue(decoded.filter(\.isLikely).allSatisfy { $0.language == nil })
        XCTAssertEqual(ArtistSongLanguage.allCases.map(\.rawValue), ["bn", "en", "hi", "ta", "te"])
        XCTAssertEqual(MusicLanguage.allCases.count, 2)
        let key = LyricsRequestKey(track("roundtrip-key"))
        XCTAssertEqual(try JSONDecoder().decode(LyricsRequestKey.self, from: JSONEncoder().encode(key)), key)
    }

    private func makeClock() -> LyricsTestClock {
        let clock = LyricsTestClock()
        let now = libraryTestDate(2026, 9, 20, calendar: libraryTestCalendar())
        clock.advance(now.timeIntervalSince(clock.now()))
        return clock
    }

    private func track(_ id: String) -> Track { ArtistSpotlightTestSupport.track(id) }

    private func event(_ track: Track, at date: Date, seconds: TimeInterval) -> ListeningEvent {
        ListeningEvent(id: UUID(), track: track, startedAt: date, listenedSeconds: seconds)
    }

    private func gatedLyrics() -> ArtistSpotlightLyricsFixture {
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await provider.requests.close() }
        return provider
    }

    private func makeService(_ provider: any LyricsProviding, clock: LyricsTestClock,
                             metadataLookup: ArtistSpotlightLanguageService.MetadataLookup? = nil) -> ArtistSpotlightLanguageService {
        var configuration = ArtistSpotlightLanguageService.Configuration()
        // Coordinator reuse must be observable in source call counts, rather than hidden by the service's own cache.
        configuration.capacity = 0
        return ArtistSpotlightLanguageService(provider: provider, configuration: configuration,
            hypotheses: ArtistSpotlightTestSupport.originalScriptHypotheses, now: { clock.now() }, metadataLookup: metadataLookup)
    }

    private func makeDiscovery(_ provider: any LyricsProviding, clock: LyricsTestClock, cacheURL: URL? = nil,
                               configuration: ListeningLanguageDiscovery.Configuration = .init(),
                               metadataLookup: ArtistSpotlightLanguageService.MetadataLookup? = nil) -> ListeningLanguageDiscovery {
        var configuration = configuration
        configuration.calendar = libraryTestCalendar()
        return ListeningLanguageDiscovery(service: makeService(provider, clock: clock, metadataLookup: metadataLookup),
                                          cacheURL: cacheURL, now: { clock.now() }, configuration: configuration)
    }

    private func cacheURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ListeningLanguageDiscoveryTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(ListeningLanguageDiscoveryCache.fileName)
    }

    private func work(_ language: ArtistSongLanguage) -> ArtistSongLanguageResult {
        .identified(language, source: .musicBrainzWork(recordingID: ArtistSpotlightMusicBrainzFixtures.recordingID,
                                                       workID: ArtistSpotlightMusicBrainzFixtures.workID))
    }

    private func cacheEntry(_ track: Track, result: ArtistSongLanguageResult = .identified(.english, source: .matchedLyrics),
                            checked: Date, lifetime: TimeInterval = 12 * 60 * 60) -> ListeningLanguageDiscoveryCache.Entry {
        .init(key: LyricsRequestKey(track), result: result, checkedAt: checked, expiresAt: checked.addingTimeInterval(lifetime))
    }

    private func cacheData(_ entries: [ListeningLanguageDiscoveryCache.Entry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let raw = try JSONSerialization.jsonObject(with: encoder.encode(entries))
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": raw], options: [.sortedKeys])
    }
}

private struct ListeningDiscoveryLyrics: LyricsProviding {
    let requests = CatalogTestRecorder<Track>()
    let response: @Sendable (Track) async throws -> LyricsDocument

    init(response: @escaping @Sendable (Track) async throws -> LyricsDocument = { ArtistSpotlightTestSupport.document($0) }) {
        self.response = response
    }

    func lyrics(for track: Track) async throws -> LyricsDocument {
        requests.record(track)
        return try await response(track)
    }
}
