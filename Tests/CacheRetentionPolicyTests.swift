import XCTest
@testable import GanaBajana

@MainActor
final class CacheRetentionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_819_200)
    private let day: TimeInterval = 86_400
    private let a = Track(id: "fsiPzT50ZiM", title: "Frequently heard", duration: 180)
    private let b = Track(id: "NJAv_7lHUIU", title: "Recently heard", duration: 180)
    private let c = Track(id: "J7p4bzqLvCw", title: "Suggestion", duration: 180)

    func testFrequencyIsCappedAtTwentyAndRecencyHasASevenDayHalfLife() {
        let frequent = (0..<40).map { _ in event(a, ageDays: 7, seconds: 60) }
        let recent = event(b, ageDays: 0, seconds: 1)
        let policy = AudioCacheRetentionPolicy(events: frequent + [recent], now: now)
        XCTAssertEqual(policy.qualifyingPlays(for: a.id, now: now), 20)
        XCTAssertEqual(policy.score(for: a.id, now: now), 0.725, accuracy: 0.000_001)
        XCTAssertEqual(policy.score(for: b.id, now: now), 0.55, accuracy: 0.000_001)
        XCTAssertEqual(policy.score(for: b.id, now: now.addingTimeInterval(7 * day)), 0.275, accuracy: 0.000_001)
        XCTAssertEqual(policy.score(for: c.id, now: now), 0)
        let today = AudioCacheRetentionPolicy(events: (0..<25).map { _ in event(a, ageDays: 0, seconds: 60) }, now: now)
        XCTAssertEqual(today.score(for: a.id, now: now), 1, accuracy: 0.000_001)
        XCTAssertEqual(today.signals[a.id]?.qualifyingSessions.count, 20)
    }

    func testThirtyAndNinetyDayBoundariesAgeWithoutAnotherHistoryUpdate() {
        let atThirty = event(a, ageDays: 30, seconds: 30)
        let atNinety = event(b, ageDays: 90, seconds: 1)
        let policy = AudioCacheRetentionPolicy(events: [atThirty, atNinety], now: now)
        XCTAssertEqual(policy.qualifyingPlays(for: a.id, now: now), 1)
        XCTAssertEqual(policy.qualifyingPlays(for: a.id, now: now.addingTimeInterval(0.001)), 0)
        XCTAssertEqual(policy.lastListen(for: b.id, now: now), atNinety.startedAt)
        XCTAssertGreaterThan(policy.score(for: b.id, now: now), 0)
        XCTAssertEqual(policy.score(for: b.id, now: now.addingTimeInterval(0.001)), 0)
        XCTAssertEqual(policy.score(for: a.id, now: now.addingTimeInterval(91 * day)), 0)
    }

    func testDuplicateCheckpointsCountOneSessionAndConflictingIdentitiesContributeNothing() {
        let id = UUID()
        let small = event(a, ageDays: 1, seconds: 10, id: id)
        let full = event(a, ageDays: 1, seconds: 40, id: id)
        for input in [[small, full, full], [full, small, full]] {
            let policy = AudioCacheRetentionPolicy(events: input, now: now)
            XCTAssertEqual(policy.qualifyingPlays(for: a.id, now: now), 1)
            XCTAssertEqual(policy.signals[a.id]?.qualifyingSessions, [full.startedAt])
        }
        let conflict = event(b, ageDays: 1, seconds: 40, id: id)
        let invalid = AudioCacheRetentionPolicy(events: [full, conflict, full], now: now)
        XCTAssertTrue(invalid.signals.isEmpty)
    }

    func testOnlyPositiveActualListeningSetsRecencyAndShortSongsUseTheExistingQualification() {
        let short = Track(id: c.id, title: "Short song", duration: 20)
        let positive = event(a, ageDays: 2, seconds: 0.5)
        let policy = AudioCacheRetentionPolicy(events: [positive, event(a, ageDays: 0, seconds: 0),
            event(a, ageDays: 0, seconds: -1), event(a, ageDays: 0, seconds: .infinity),
            event(b, ageDays: -1, seconds: 60), event(short, ageDays: 1, seconds: 10)], now: now)
        XCTAssertEqual(policy.lastListen(for: a.id, now: now), positive.startedAt)
        XCTAssertEqual(policy.qualifyingPlays(for: a.id, now: now), 0)
        XCTAssertEqual(policy.score(for: b.id, now: now), 0)
        XCTAssertEqual(policy.qualifyingPlays(for: short.id, now: now), 1)
        XCTAssertTrue(AudioCacheRetentionPolicy(events: [positive], now: Date(timeIntervalSince1970: .nan)).signals.isEmpty)
        XCTAssertEqual(policy.score(for: short.id, now: now.addingTimeInterval(-10 * day)), 0)
    }

    func testEvictionBalancesRecentAndFrequentListeningAndBreaksTiesDeterministically() {
        let history = (0..<20).map { _ in event(a, ageDays: 14, seconds: 60) } + [event(b, ageDays: 0, seconds: 60)]
        let policy = AudioCacheRetentionPolicy(events: history, now: now)
        let entries = [candidate(b.id, accessed: 1), candidate(c.id, accessed: 1_000), candidate(a.id, accessed: 2)]
        XCTAssertEqual(policy.evictionOrder(entries, now: now).map(\.id), [c.id, a.id, b.id])
        let equallyScored = AudioCacheRetentionPolicy(events: [event(a, ageDays: 0, seconds: 1), event(b, ageDays: 0, seconds: 1)], now: now)
        XCTAssertEqual(equallyScored.evictionOrder([candidate(b.id, accessed: 2), candidate(a.id, accessed: 1)], now: now).map(\.id), [a.id, b.id])
        let cold = AudioCacheRetentionPolicy()
        XCTAssertEqual(cold.evictionOrder([candidate("z", accessed: 1), candidate("a", accessed: 1)], now: now).map(\.id), ["a", "z"])
    }

    func testDerivedHistoryIsBoundedAndPreservesSignalsForStoredRecordings() {
        var events = (0..<(AudioCacheRetentionPolicy.maximumHistoryTracks + 20)).map { index in
            event(Track(id: "history-\(index)", title: "History", duration: 180), ageDays: 0, seconds: 60)
        }
        events.append(event(a, ageDays: 89, seconds: 1))
        let policy = AudioCacheRetentionPolicy(events: events, now: now, retaining: [a.id])
        XCTAssertEqual(policy.signals.count, AudioCacheRetentionPolicy.maximumHistoryTracks)
        XCTAssertNotNil(policy.signals[a.id])
        XCTAssertTrue(policy.signals.values.allSatisfy { $0.qualifyingSessions.count <= 20 })
        XCTAssertTrue(AudioCacheRetentionPolicy(events: [], now: now).signals.isEmpty)
    }

    func testDurableHistoryOutranksCacheReadsAndClearingHistoryRestoresCacheRecencyFallback() async throws {
        let fixture = try makeFixture()
        let first = try fixture.seed(a.id)
        let second = try fixture.seed(b.id)
        let third = try fixture.seed(c.id)
        let bytes = Int64(try Data(contentsOf: first).count)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-50)], ofItemAtPath: second.path)
        let player = PlayerController(resolver: fixture.resolver())
        defer { player.pause() }
        await player.updateCacheListeningHistory([event(a, ageDays: 0, seconds: 60), event(b, ageDays: 1, seconds: 1)], now: now)?.value
        for _ in 0..<10 { _ = await fixture.cache.entry(for: c.id) }

        let trimmed = try await fixture.cache.updatePolicy(capacityBytes: bytes * 2, maximumFiles: 20)

        XCTAssertEqual(trimmed.songCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.path), "Reading a suggestion does not make it listened music")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        await player.updateCacheListeningHistory([], now: now)?.value
        let emptyHistory = try await fixture.cache.updatePolicy(capacityBytes: bytes, maximumFiles: 20)
        XCTAssertEqual(emptyHistory.songCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "An empty history removes the old frequency advantage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testBothSongAndByteLimitsKeepProtectedOverageAndOldAudioHasNoTTL() async throws {
        let fixture = try makeFixture()
        let first = try fixture.seed(a.id)
        try fixture.seed(b.id)
        let ancient = now.addingTimeInterval(-4_000 * day)
        try FileManager.default.setAttributes([.modificationDate: ancient], ofItemAtPath: first.path)
        let before = try await fixture.cache.snapshot()
        XCTAssertEqual(before.songs.count, 2)
        XCTAssertTrue(before.songs.allSatisfy(\.isPlayable))
        await fixture.cache.pin(only: [a.id, b.id])
        let overage = try await fixture.cache.updatePolicy(capacityBytes: 1, maximumFiles: 1)
        XCTAssertEqual(overage.songCount, 2)
        XCTAssertEqual(overage.retainedBytes, overage.bytes)
        XCTAssertGreaterThan(overage.bytes, overage.capacityBytes)
        await fixture.cache.pin(only: [b.id])
        let after = try await fixture.cache.updatePolicy(capacityBytes: overage.bytes, maximumFiles: 1)
        XCTAssertEqual(after.songCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testSpeculativeAdmissionPreservesHigherScoredAudioButForegroundCanReplaceIt() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeFixture(capacityBytes: Int64(payload.count), maximumFiles: 1)
        let original = try fixture.seed(a.id)
        await fixture.cache.updateListeningHistory([event(a, ageDays: 0, seconds: 60)], now: now)
        let remote = AudioCacheTests.remote(b.id)
        do {
            _ = try await fixture.cache.store(trackID: b.id, from: remote, stream: ResolvedStream(url: remote), speculative: true)
            XCTFail("Speculation must not displace more valuable audio")
        } catch {
            guard case AudioCache.ManagementError.admissionDeferred = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: original), payload)
        let afterRejection = try await fixture.cache.snapshot()
        XCTAssertEqual(afterRejection.songs.map(\.id), [a.id])
        XCTAssertEqual(afterRejection.usage.pendingDownloads, 0)
        _ = try await fixture.cache.store(trackID: b.id, from: remote, stream: ResolvedStream(url: remote))
        let foreground = try await fixture.cache.snapshot()
        XCTAssertEqual(foreground.songs.map(\.id), [b.id])
        XCTAssertLessThanOrEqual(foreground.usage.bytes, Int64(payload.count))
    }

    func testPinnedUpcomingAudioCanBeAdmittedWithoutRemovingThePlayingSong() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeFixture(capacityBytes: Int64(payload.count), maximumFiles: 1)
        try fixture.seed(a.id)
        await fixture.cache.updateListeningHistory([event(a, ageDays: 0, seconds: 60)], now: now)
        await fixture.cache.pin(only: [a.id, b.id])
        let remote = AudioCacheTests.remote(b.id)
        _ = try await fixture.cache.store(trackID: b.id, from: remote, stream: ResolvedStream(url: remote), speculative: true)
        let snapshot = try await fixture.cache.snapshot()
        XCTAssertEqual(snapshot.usage.songCount, 2)
        XCTAssertEqual(snapshot.usage.bytes, Int64(payload.count * 2))
        XCTAssertEqual(snapshot.usage.retainedSongCount, 2)
    }

    func testFailedAdmissionDoesNotPartiallyEvictLowerValueSongs() async throws {
        let time = now
        let oneSong = PlaybackTestSupport.audioData(seconds: 1)
        let incoming = PlaybackTestSupport.audioData(seconds: 2)
        let fixture = try CacheManagementFixture(capacityBytes: Int64(oneSong.count * 2), handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(incoming.count)"], data: incoming)
        }, now: { time })
        addTeardownBlock { try await fixture.close() }
        let valuable = try fixture.seed(a.id)
        let cold = try fixture.seed(b.id)
        await fixture.cache.updateListeningHistory([event(a, ageDays: 0, seconds: 60)], now: now)
        let source = AudioCacheTests.remote(c.id)
        do {
            _ = try await fixture.cache.store(trackID: c.id, from: source, stream: ResolvedStream(url: source), speculative: true)
            XCTFail("Removing only the cold entry cannot make enough room")
        } catch { XCTAssertTrue(error is AudioCache.ManagementError) }
        XCTAssertEqual(try Data(contentsOf: valuable), oneSong)
        XCTAssertEqual(try Data(contentsOf: cold), oneSong)
        let after = try await fixture.cache.snapshot()
        XCTAssertEqual(after.usage.bytes, Int64(oneSong.count * 2))
        XCTAssertEqual(after.usage.songCount, 2)
    }

    func testSpeculativeOpusReservationCannotEvictHigherScoredAudioBeforeDownload() async throws {
        let time = now
        let fixture = try CacheManagementFixture(capacityBytes: 128 << 20, handler: { _ in
            XCTFail("Rejected speculative preparation must not download")
            throw PlaybackStreamError.noAudio
        }, opusPreparation: OpusTestSupport.prepare, now: { time })
        addTeardownBlock { try await fixture.close() }
        let original = try fixture.seed(a.id)
        await fixture.cache.updateListeningHistory([event(a, ageDays: 0, seconds: 60)], now: now)
        let permit = try await fixture.cache.writePermit()
        do {
            _ = try await fixture.cache.storeOpus(trackID: b.id, stream: OpusTestSupport.source(), permit: permit,
                                                 foreground: false, speculative: true)
            XCTFail("The full preparation reservation must obey admission priority")
        } catch { XCTAssertTrue(error is AudioCache.ManagementError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
        let snapshot = try await fixture.cache.snapshot()
        XCTAssertEqual(snapshot.songs.map(\.id), [a.id])
        XCTAssertEqual(snapshot.usage.pendingDownloads, 0)
    }

    func testDeferredSpeculativeOpusDoesNotImposeAFailureCooldownOnForegroundPreparation() async throws {
        let time = now
        let wave = PlaybackTestSupport.audioData(seconds: 1)
        let reservation: Int64 = 128 << 20
        for keepsCachedFallback in [false, true] {
            let preparations = CatalogTestRecorder<Bool>()
            let extractions = CatalogTestRecorder<String>()
            let fixture = try CacheManagementFixture(capacityBytes: reservation, handler: { request in
                if request.url?.query?.contains("itag=140") == true {
                    return CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(wave.count)"], data: wave)
                }
                return CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"],
                                   data: OpusTestSupport.webM)
            }, opusPreparation: { input, output in
                preparations.record(true)
                return try await OpusTestSupport.prepare(input: input, output: output)
            }, now: { time })
            addTeardownBlock { try await fixture.close() }
            let original = try fixture.seed(a.id)
            await fixture.cache.updateListeningHistory([event(a, ageDays: 0, seconds: 60)], now: now)
            let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
                fastExtract: { id in extractions.record(id); return OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true)
            await resolver.prefetch([b])
            try await PlaybackTestSupport.eventually { await resolver.prefetchDownloadTrackID == nil }

            let prefetched = try await resolver.audioCacheSnapshot()
            let fallback = try XCTUnwrap(prefetched?.songs.first { $0.id == b.id }?.preferredAudio)
            XCTAssertEqual(fallback.quality?.codec, .aac)
            XCTAssertEqual(try Data(contentsOf: fallback.url), wave)
            XCTAssertEqual(try Data(contentsOf: original), wave, "Speculation must keep the higher-scored song")
            XCTAssertEqual(prefetched?.usage.bytes, Int64(wave.count * 2))
            XCTAssertEqual(prefetched?.usage.songCount, 2)
            XCTAssertEqual(prefetched?.usage.pendingDownloads, 0)
            XCTAssertTrue(preparations.values.isEmpty, "The Opus reservation is deferred before acquisition or preparation")
            XCTAssertEqual(fixture.mock.state.requests.map(\.url), [OpusTestSupport.aacURL])

            let sourceCalls = extractions.values
            for forceRefresh in [false, true] {
                let cached = try await resolver.resolve(track: b, forceRefresh: forceRefresh)
                XCTAssertEqual(cached.url, fallback.url)
                XCTAssertEqual(cached.quality?.codec, .aac, "A normal forced resolution still prefers complete cached audio")
            }
            XCTAssertEqual(extractions.values, sourceCalls)
            XCTAssertEqual(fixture.mock.state.requests.map(\.url), [OpusTestSupport.aacURL])

            let foreground: ResolvedStream
            if keepsCachedFallback {
                await resolver.retainCached([b.id])
                // Preparation needs its full reservation in addition to the immutable, in-use AAC fallback.
                _ = try await fixture.cache.updatePolicy(capacityBytes: reservation + fallback.bytes, maximumFiles: 40)
                XCTAssertEqual(try Data(contentsOf: original), wave)
                foreground = try await resolver.refreshQuality(track: b)
                XCTAssertEqual(try Data(contentsOf: fallback.url), wave)
            } else {
                // Removing AAC exposes fresh selection; the complete download prepares Opus without resetting a cooldown,
                // while a forced first play streams the AAC.
                await resolver.discardCached(b)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.url.path))
                await resolver.retainCached([b.id])
                let restarted = try await resolver.resolve(track: b, forceRefresh: true)
                XCTAssertEqual(restarted.url, OpusTestSupport.aacURL, "The forced first play streams the AAC at once")
                foreground = try await resolver.download(b)
            }
            XCTAssertTrue(foreground.url.isFileURL)
            XCTAssertEqual(foreground.quality?.codec, .opus)
            XCTAssertEqual(preparations.values, [true])
            XCTAssertEqual(extractions.values.count, sourceCalls.count + 1)
            XCTAssertEqual(fixture.mock.state.requests.map(\.url), [OpusTestSupport.aacURL, OpusTestSupport.opusURL])
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "Foreground preparation can evict the unused song")
            let completed = try await resolver.audioCacheSnapshot()
            XCTAssertEqual(completed?.songs.map(\.id), [b.id])
            XCTAssertEqual(completed?.songs.first?.variantCount, keepsCachedFallback ? 2 : 1)
            XCTAssertEqual(completed?.songs.first?.preferredAudio?.url, foreground.url)
        }
    }

    private func event(_ track: Track, ageDays: Double, seconds: TimeInterval, id: UUID = UUID()) -> ListeningEvent {
        ListeningEvent(id: id, track: track, startedAt: now.addingTimeInterval(-ageDays * day), listenedSeconds: seconds)
    }

    private func candidate(_ id: String, accessed: TimeInterval) -> AudioCacheRetentionPolicy.Candidate {
        .init(id: id, bytes: 10, accessedAt: Date(timeIntervalSince1970: accessed))
    }

    private func makeFixture(capacityBytes: Int64 = 200 << 20, maximumFiles: Int = 40) throws -> CacheManagementFixture {
        let time = now
        let fixture = try CacheManagementFixture(capacityBytes: capacityBytes, maximumFiles: maximumFiles, now: { time })
        addTeardownBlock { try await fixture.close() }
        return fixture
    }
}
