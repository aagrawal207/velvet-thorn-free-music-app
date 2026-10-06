import Foundation
import Synchronization
import XCTest
@testable import GanaBajana

@MainActor
final class BackgroundDownloadsTests: XCTestCase {
    nonisolated private static let a = "fsiPzT50ZiM"
    nonisolated private static let b = "NJAv_7lHUIU"
    nonisolated private static let c = "J7p4bzqLvCw"

    func testSystemConfigurationHasStableReattachmentIdentityAndLaunchEvents() {
        let first = SystemBackgroundDownloadSession.configuration()
        let second = SystemBackgroundDownloadSession.configuration()
        XCTAssertEqual(first.identifier, "com.agraabhi.ganabajana.downloads.v1")
        XCTAssertEqual(second.identifier, first.identifier)
        XCTAssertTrue(first.sessionSendsLaunchEvents)
        XCTAssertTrue(first.waitsForConnectivity)
        XCTAssertFalse(first.isDiscretionary)
        XCTAssertNil(first.httpCookieStorage)
        XCTAssertNil(first.urlCache)
        XCTAssertFalse(first.httpShouldSetCookies)
        XCTAssertEqual(first.httpMaximumConnectionsPerHost, 2)
    }

    func testFastYouTubePlanChoosesAACWithoutDownloadingOrPreparingOpus() async throws {
        let aac = URL(string: "https://audio.googlevideo.com/videoplayback?itag=140&dur=8&expire=4000000000&clen=1234")!
        let opus = URL(string: "https://audio.googlevideo.com/videoplayback?itag=251&dur=8&expire=4000000000&clen=2345")!
        let extractions = CatalogTestRecorder<String>()
        let probes = CatalogTestRecorder<URL>()
        let resolver = YouTubeStreamResolver(extract: { id, _ in extractions.record(id); return [] }, validate: { probes.record($0) },
            fastExtract: { _ in FastPathResult(urls: [opus], qualityByURL: [opus: SourceAudioQuality(codec: .opus, bitRate: 160_000)],
                aacFallbacks: [ResolvedStream(url: aac, quality: SourceAudioQuality(codec: .aac, bitRate: 128_000))]) }, opusEnabled: true)
        let plan = try await resolver.backgroundDownloadPlan(for: Self.track(Self.a))
        XCTAssertEqual(plan.stream.url, aac)
        XCTAssertEqual(plan.metadata.fileExtension, "m4a")
        XCTAssertEqual(plan.metadata.bytes, 1234)
        XCTAssertEqual(probes.values, [aac])
        XCTAssertTrue(extractions.values.isEmpty)
        let request = try plan.request(allowCellular: false, now: Date())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-1233")
        XCTAssertFalse(request.allowsCellularAccess)
        XCTAssertFalse(request.allowsExpensiveNetworkAccess)
    }

    func testDownloadPlanForThePlayingSongReusesThePlayerLinkWithoutASecondLookup() async throws {
        let aac = URL(string: "https://audio.googlevideo.com/videoplayback?itag=140&dur=8&expire=4000000000&clen=1234")!
        let lookups = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { id in
                lookups.record(id)
                return FastPathResult(urls: [aac], qualityByURL: [aac: SourceAudioQuality(codec: .aac, bitRate: 128_000)])
            }, opusEnabled: false)
        let playing = try await resolver.resolve(track: Self.track(Self.a), forceRefresh: false)
        XCTAssertEqual(playing.url, aac)
        let plan = try await resolver.backgroundDownloadPlan(for: Self.track(Self.a))
        XCTAssertEqual(plan.stream.url, aac)
        XCTAssertEqual(lookups.values.count, 1, "Pressing Download right after Play must reuse the player's link")
    }

    func testOpusOnlyFastPlanReturnsRemoteFileForDeliveryPreparation() async throws {
        let source = OpusTestSupport.source()
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in XCTFail("Opus is verified after delivery") },
            fastExtract: { _ in FastPathResult(urls: [source.url], qualityByURL: [source.url: OpusTestSupport.opusQuality]) }, opusEnabled: true)
        let plan = try await resolver.backgroundDownloadPlan(for: Self.track(Self.a))
        XCTAssertFalse(plan.stream.url.isFileURL)
        XCTAssertEqual(plan.metadata.fileExtension, "webm")
    }

    func testFittingOpusPreservesQualityCeilingBeforeAboveCeilingAAC() async throws {
        let opus = OpusTestSupport.source(rate: 64_000)
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in FastPathResult(urls: [opus.url], qualityByURL: [opus.url: opus.quality!],
                aacFallbacks: [ResolvedStream(url: OpusTestSupport.aacURL, quality: OpusTestSupport.aacQuality)]) }, opusEnabled: true)
        await resolver.setAudioQualityPreference(.dataSaver)
        let plan = try await resolver.backgroundDownloadPlan(for: Self.track(Self.a))
        XCTAssertEqual(plan.metadata.quality?.bitRate, 64_000)
        XCTAssertEqual(plan.metadata.fileExtension, "webm")
    }

    func testExpiredPlansAndHLSCannotBeSubmitted() throws {
        let now = Date()
        let expired = try BackgroundDownloadPlan(stream: ResolvedStream(url: Self.remote, expiresAt: now.addingTimeInterval(-1)), now: now)
        XCTAssertThrowsError(try expired.request(allowCellular: true, now: now))
        XCTAssertThrowsError(try BackgroundDownloadPlan(stream: ResolvedStream(url: URL(string: "https://example.com/master.m3u8")!)))
        XCTAssertThrowsError(try BackgroundDownloadPlan(stream: ResolvedStream(url: URL(string: "https://example.com/manifest.mpd")!)))
        XCTAssertThrowsError(try BackgroundDownloadPlan(stream: ResolvedStream(url: URL(fileURLWithPath: "/tmp/audio.m4a"))))
    }

    func testTwoTransfersContinueAfterBackgroundAndThirdWaitsForRuntime() async throws {
        let f = try makeFixture()
        await restore(f)
        await f.engine.setForeground(true)
        let count = await f.engine.enqueue([Self.track(Self.a), Self.track(Self.b), Self.track(Self.c)])
        XCTAssertEqual(count, 3)
        try await wait { f.session.requests.count == 2 }
        await f.engine.setForeground(false)
        XCTAssertTrue(f.session.cancelled.isEmpty)
        for request in f.session.requests { try f.session.deliver(request.id, payload: PlaybackTestSupport.audioData(seconds: 1)) }
        try await wait { await f.engine.items.filter { $0.waitingReason == .processing }.count == 2 }
        XCTAssertEqual(f.session.requests.count, 2)
        let before = await f.cache.isDownloaded(Self.a)
        XCTAssertFalse(before, "Staging is not a downloaded badge")
        await f.engine.setForeground(true)
        try await wait { f.session.requests.count == 3 }
        let third = try XCTUnwrap(f.session.requests.last)
        try f.session.deliver(third.id, payload: PlaybackTestSupport.audioData(seconds: 1))
        try await wait { await f.engine.items.isEmpty }
        let usage = try await f.cache.storageUsage()
        XCTAssertEqual(usage.downloadedSongCount, 3)
        XCTAssertEqual(usage.songCount, 0)
    }

    func testDeliveryCopiesSynchronouslyAndDuplicateCallbacksPublishOnce() async throws {
        let tiers = CatalogTestRecorder<String>()
        let f = try makeFixture()
        await f.engine.setObservers(onChange: { _ in }, onTierChange: { id, _ in tiers.record(id) })
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a)])
        try await wait { f.session.requests.count == 1 }
        let request = f.session.requests[0]
        await f.engine.setForeground(false)
        try f.session.deliver(request.id, payload: PlaybackTestSupport.audioData(seconds: 1))
        XCTAssertNotNil(try f.staging.load(request.token), "Receipt and owned bytes exist before the delivery method returns")
        f.session.send(.delivered(request.token))
        f.session.send(.failed(request.token, .transport))
        await f.engine.setForeground(true)
        try await wait { tiers.values.count == 1 }
        f.session.send(.delivered(request.token))
        f.session.send(.failed(request.token, .transport))
        await settle()
        XCTAssertEqual(tiers.values, [Self.a])
        let remaining = await f.engine.items
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(try f.staging.load(request.token))
    }

    func testColdLaunchReattachesPendingTaskWithoutExtractingAgain() async throws {
        let calls = CatalogTestRecorder<String>()
        let f = try makeFixture(planner: { track in calls.record(track.id); return try Self.plan() })
        let plan = try Self.plan()
        var record = BackgroundPendingDownload(id: Self.a)
        record.attempts = 1
        record.phase = .transferring
        record.metadata = plan.metadata
        record.expiresAt = plan.expiresAt
        try seed([record], at: f.queue)
        let id = f.session.seed(token: record.token, allowsCellular: false)
        await restore(f)
        XCTAssertTrue(f.session.resumed.contains(id))
        XCTAssertTrue(f.session.requests.isEmpty)
        XCTAssertTrue(calls.values.isEmpty)
        let restored = await f.engine.items
        XCTAssertTrue(restored.first?.state.isDownloading == true)
        try f.session.deliver(id, payload: PlaybackTestSupport.audioData(seconds: 1))
        await f.engine.setForeground(true)
        try await wait { await f.engine.items.isEmpty }
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testColdLaunchRecoversReceiptEvenWhenQueueStillSaysTransferring() async throws {
        let f = try makeFixture(planner: { _ in XCTFail("No new request for staged bytes"); return try Self.plan() })
        let plan = try Self.plan()
        var record = BackgroundPendingDownload(id: Self.a)
        record.phase = .transferring
        record.attempts = 1
        record.metadata = plan.metadata
        record.expiresAt = .distantPast
        try seed([record], at: f.queue)
        try f.session.stage(token: record.token, payload: PlaybackTestSupport.audioData(seconds: 1))
        await restore(f)
        let items = await f.engine.items
        XCTAssertEqual(items.first?.waitingReason, .processing)
        await f.engine.setForeground(true)
        try await wait { await f.engine.items.isEmpty }
        let downloaded = await f.cache.isDownloaded(Self.a)
        XCTAssertTrue(downloaded)
    }

    func testDuplicateReattachedTasksKeepOneTransferAndDropMissingTrack() async throws {
        let f = try makeFixture()
        var record = BackgroundPendingDownload(id: Self.a)
        record.phase = .transferring
        record.attempts = 1
        let plan = try Self.plan()
        record.metadata = plan.metadata
        record.expiresAt = plan.expiresAt
        try seed([record, BackgroundPendingDownload(id: Self.b)], at: f.queue)
        let first = f.session.seed(token: record.token, allowsCellular: false)
        let second = f.session.seed(token: record.token, allowsCellular: false)
        await f.engine.restore { _ in [Self.track(Self.a)] }
        XCTAssertEqual(f.session.cancelled.filter { $0 == first || $0 == second }.count, 1)
        XCTAssertEqual(f.session.resumed.filter { $0 == first || $0 == second }.count, 1)
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).trackIDs, [Self.a])
        let duplicate = try XCTUnwrap(f.session.cancelled.first)
        f.session.send(.failed(record.token, .interrupted, taskID: duplicate))
        await settle()
        let state = await f.engine.items.first?.state
        XCTAssertTrue(state?.isDownloading == true, "Cancelling the duplicate cannot retire the kept task")
    }

    func testTaskCompletionDuringLibraryLookupCannotLeaveAPhantomTransfer() async throws {
        for deliversFile in [false, true] {
            let f = try makeFixture()
            let gate = BackgroundPublicationGate()
            var record = BackgroundPendingDownload(id: Self.a)
            record.phase = .transferring
            record.attempts = 1
            let plan = try Self.plan()
            record.metadata = plan.metadata
            record.expiresAt = plan.expiresAt
            try seed([record], at: f.queue)
            let id = f.session.seed(token: record.token, allowsCellular: false)
            let restoring = Task {
                await f.engine.restore { ids in
                    await gate.wait()
                    return ids.map(Self.track)
                }
            }
            try await wait { gate.entered }
            if deliversFile { try f.session.deliver(id, payload: PlaybackTestSupport.audioData(seconds: 1)) }
            else { f.session.fail(id, .transport) }
            await settle()
            gate.release()
            await restoring.value
            let items = await f.engine.items
            XCTAssertEqual(items.first?.waitingReason, deliversFile ? .processing : .foregroundResolution)
            XCTAssertFalse(items.first?.state.isDownloading == true)
        }
    }

    func testFailedStagedPublicationDoesNotRetryItselfAtColdLaunch() async throws {
        let f = try makeFixture(planner: { _ in XCTFail("Failed deliveries require explicit Retry"); return try Self.plan() })
        var record = BackgroundPendingDownload(id: Self.a)
        record.phase = .failed
        record.failure = .publication
        record.metadata = try Self.plan().metadata
        try seed([record], at: f.queue)
        try f.session.stage(token: record.token, payload: PlaybackTestSupport.audioData(seconds: 1))
        await restore(f)
        await f.engine.setForeground(true)
        await settle()
        let items = await f.engine.items
        XCTAssertEqual(items.first?.state, .failed(reason: BackgroundDownloadFailure.publication.message))
        XCTAssertNotNil(try f.staging.load(record.token))
        await f.engine.retry(Self.a)
        try await wait { await f.engine.items.isEmpty }
        XCTAssertTrue(f.session.requests.isEmpty)
    }

    func testExpiredReattachedTaskWaitsForForegroundThenRenewsWithinAttemptBudget() async throws {
        let calls = CatalogTestRecorder<String>()
        let f = try makeFixture(planner: { track in calls.record(track.id); return try Self.plan() })
        var record = BackgroundPendingDownload(id: Self.a)
        record.phase = .transferring
        record.attempts = 1
        record.metadata = try Self.plan().metadata
        record.expiresAt = Date().addingTimeInterval(-1)
        try seed([record], at: f.queue)
        let old = f.session.seed(token: record.token, allowsCellular: false)
        await restore(f)
        XCTAssertTrue(f.session.cancelled.contains(old))
        XCTAssertTrue(calls.values.isEmpty)
        let waiting = await f.engine.items
        XCTAssertEqual(waiting.first?.waitingReason, .foregroundResolution)
        await f.engine.setForeground(true)
        try await wait { f.session.requests.count == 1 }
        XCTAssertEqual(calls.values.count, 1)
        XCTAssertNotEqual(f.session.requests[0].token, record.token)
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).pending?.first?.attempts, 2)
    }

    func testHTTP403InBackgroundWaitsForForegroundAndNeverPersistsURL() async throws {
        let f = try makeFixture()
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a)])
        try await wait { f.session.requests.count == 1 }
        await f.engine.setForeground(false)
        let request = f.session.requests[0]
        do {
            try f.session.stage(token: request.token, payload: PlaybackTestSupport.audioData(seconds: 1), status: 403)
            XCTFail("HTTP 403 must retire the signed plan")
        } catch let failure as BackgroundDownloadFailure {
            XCTAssertEqual(failure, .expired)
            f.session.fail(request.id, failure)
        }
        try await wait { await f.engine.items.first?.waitingReason == .foregroundResolution }
        let text = try String(contentsOf: f.queue, encoding: .utf8)
        for sensitive in ["https", "googlevideo", "signature", "TOP_SECRET", "resumeData", "Fixture Song"] {
            XCTAssertFalse(text.contains(sensitive), sensitive)
        }
        await f.engine.setForeground(true)
        try await wait { f.session.requests.count == 2 }
    }

    func testForegroundReturnRenewsAnExpiredTaskWithoutAProcessRestart() async throws {
        let clock = BackgroundClock()
        let f = try makeFixture(planner: { _ in
            try BackgroundDownloadPlan(stream: ResolvedStream(url: Self.remote, duration: 1), now: clock.now)
        }, now: { clock.now })
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a)])
        try await wait { f.session.requests.count == 1 }
        let old = f.session.requests[0]
        await f.engine.setForeground(false)
        clock.advance(7 * 3_600)
        XCTAssertTrue(f.session.cancelled.isEmpty)
        await f.engine.setForeground(true)
        try await wait { f.session.requests.count == 2 }
        XCTAssertTrue(f.session.cancelled.contains(old.id))
        XCTAssertNotEqual(f.session.requests[1].token, old.token)
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).pending?.first?.attempts, 2)
    }

    func testThreeAttemptsAreDurableAndManualRetryResetsBudget() async throws {
        let f = try makeFixture()
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a)])
        for attempt in 1...3 {
            try await wait { f.session.requests.count == attempt }
            f.session.fail(f.session.requests[attempt - 1].id, .transport)
        }
        try await wait { await f.engine.items.first?.state.isPending == false }
        let record = try DownloadQueueRecord.read(from: f.queue)
        XCTAssertEqual(record.pending?.first?.attempts, 3)
        XCTAssertEqual(record.pending?.first?.phase, .failed)
        await settle()
        XCTAssertEqual(f.session.requests.count, 3)
        await f.engine.retry(Self.a)
        try await wait { f.session.requests.count == 4 }
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).pending?.first?.attempts, 1)
    }

    func testTransientPlanningFailuresWaitWithoutSpendingTheThreeAttempts() async throws {
        let calls = BackgroundCounter()
        let f = try makeFixture(planner: { _ in
            // Four busy lookups (timeouts, a superseded fetch, no candidate) are followed by a working one.
            let call = calls.increment()
            switch call {
            case 1: throw PlaybackStreamError.timedOut
            case 2: throw URLError(.networkConnectionLost)
            case 3: throw CancellationError()
            case 4: throw PlaybackStreamError.noAudio
            default: return try Self.plan()
            }
        })
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a)])
        try await wait { f.session.requests.count == 1 }
        XCTAssertEqual(calls.value, 5)
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).pending?.first?.attempts, 1,
                       "Only the successful plan counts as an attempt")
    }

    func testPermanentPlanningFailureStillStopsAfterThreeAttempts() async throws {
        let calls = BackgroundCounter()
        let f = try makeFixture(planner: { _ in
            _ = calls.increment()
            throw PlaybackStreamError.invalidID
        })
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a)])
        try await wait { await f.engine.items.first?.state.isPending == false }
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).pending?.first?.phase, .failed)
    }

    func testDownloadingThePlayingSongJoinsItsCacheCopyInsteadOfFetchingAgain() async throws {
        let calls = BackgroundCounter()
        let f = try makeFixture(planner: { _ in _ = calls.increment(); return try Self.plan() })
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let session = f.session, staging = f.staging
        // Staged inside the wait: restoring the second engine sweeps staging files it does not own.
        let spy = BackgroundCopyInProgressStore(cache: f.cache) { cache in
            let token = UUID()
            do {
                try session.stage(token: token, payload: payload)
                let part = AudioDownloader.Part(url: staging.media(token), bytes: Int64(payload.count), fileExtension: "wav")
                try await cache.publishBackgroundDownload(track: Self.track(Self.a), part: part,
                    metadata: AudioCache.Sidecar(duration: 1, bytes: Int64(payload.count), storedAt: Date(), fileExtension: "wav"),
                    fence: DownloadPublicationFence())
            } catch { XCTFail("The simulated player copy must publish: \(error)") }
        }
        let engine = BackgroundDownloadEngine(store: spy, planner: { _ in _ = calls.increment(); return try Self.plan() },
            publication: { _, _, _, _ in }, promotion: { try await f.cache.promoteToDownloads($0, fence: $1) },
            session: f.session, staging: f.staging, queueFile: f.root.appendingPathComponent("spy-queue.json"),
            connectivity: BackgroundConnectivity(), backoff: [0.001, 0.001])
        addTeardownBlock { await engine.cancelAll() }
        await engine.restore { ids in ids.map(Self.track) }
        await engine.setForeground(true)
        await engine.enqueue([Self.track(Self.a)])
        try await wait { await engine.items.isEmpty }
        XCTAssertEqual(calls.value, 0, "The in-progress copy is promoted; no second lookup or transfer starts")
        XCTAssertTrue(f.session.requests.isEmpty)
        let downloaded = await f.cache.isDownloaded(Self.a)
        XCTAssertTrue(downloaded)
        XCTAssertEqual(spy.waits.value, 1)
    }

    func testProgressClampsAndUnknownLengthNeverClaimsCompletion() async throws {
        let f = try makeFixture()
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a)])
        try await wait { f.session.requests.count == 1 }
        let token = f.session.requests[0].token
        f.session.send(.progress(token, written: 60, expected: 100))
        try await wait { await f.engine.items.first?.state == .downloading(fraction: 0.6) }
        f.session.send(.progress(token, written: 100, expected: 100))
        try await wait { await f.engine.items.first?.state == .downloading(fraction: 0.99) }
        f.session.send(.progress(token, written: 100, expected: -1))
        try await wait { await f.engine.items.first?.state == .downloading(fraction: 0) }
        let downloaded = await f.cache.isDownloaded(Self.a)
        XCTAssertFalse(downloaded)
    }

    func testCellularSwitchCancelsOldTasksAndWaitsForCancellationAcknowledgement() async throws {
        let connectivity = BackgroundConnectivity(expensive: true)
        let f = try makeFixture(connectivity: connectivity)
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a), Self.track(Self.b)])
        await settle()
        XCTAssertTrue(f.session.requests.isEmpty)
        let waiting = await f.engine.items
        XCTAssertTrue(waiting.allSatisfy { $0.state == .waitingForWiFi })
        await f.engine.setAllowCellular(true)
        try await wait { f.session.requests.count == 2 }
        XCTAssertTrue(f.session.requests.allSatisfy { $0.request.allowsCellularAccess })
        f.session.acknowledgesCancellation = false
        await f.engine.setAllowCellular(false)
        XCTAssertEqual(f.session.cancelled.count, 2)
        connectivity.expensive = false
        await f.engine.connectivityChanged()
        await settle()
        XCTAssertEqual(f.session.requests.count, 2, "Cancelling tasks retain slots until the OS acknowledges")
        for id in f.session.cancelled { f.session.acknowledgeCancellation(id) }
        try await wait { f.session.requests.count == 4 }
        XCTAssertTrue(f.session.requests.suffix(2).allSatisfy { !$0.request.allowsCellularAccess })
        XCTAssertTrue(try DownloadQueueRecord.read(from: f.queue).pending?.allSatisfy { $0.attempts == 1 } == true)
    }

    func testCancellationFencesPublisherThatIgnoresTaskCancellation() async throws {
        let gate = BackgroundPublicationGate()
        let commits = CatalogTestRecorder<String>()
        let f = try makeFixture(publication: { track, _, _, fence in
            await gate.wait()
            try fence.withValid { commits.record(track.id) }
        })
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a)])
        try await wait { f.session.requests.count == 1 }
        let request = f.session.requests[0]
        try f.session.deliver(request.id, payload: PlaybackTestSupport.audioData(seconds: 1))
        try await wait { gate.entered }
        let cancelled = await f.engine.cancel(Self.a)
        XCTAssertTrue(cancelled)
        gate.release()
        await settle()
        XCTAssertTrue(commits.values.isEmpty)
        XCTAssertTrue(try DownloadQueueRecord.read(from: f.queue).trackIDs.isEmpty)
        f.session.send(.delivered(request.token))
        await settle()
        XCTAssertTrue(commits.values.isEmpty)
    }

    func testFailedPublicationKeepsReceiptAndExplicitRetryUsesSameBytes() async throws {
        let fail = BackgroundFlag(true)
        let commits = CatalogTestRecorder<String>()
        let f = try makeFixture(publication: { track, part, _, fence in
            if fail.value { throw BackgroundDownloadFailure.publication }
            XCTAssertTrue(FileManager.default.fileExists(atPath: part.url.path))
            try fence.withValid { commits.record(track.id) }
        })
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a)])
        try await wait { f.session.requests.count == 1 }
        let request = f.session.requests[0]
        try f.session.deliver(request.id, payload: PlaybackTestSupport.audioData(seconds: 1))
        try await wait { await f.engine.items.first?.state.isPending == false }
        XCTAssertNotNil(try f.staging.load(request.token))
        XCTAssertTrue(commits.values.isEmpty)
        fail.value = false
        await f.engine.retry(Self.a)
        try await wait { commits.values.count == 1 }
        try await wait { await f.engine.items.isEmpty }
        XCTAssertEqual(f.session.requests.count, 1)
        XCTAssertNil(try f.staging.load(request.token))
    }

    func testMalformedFutureAndOversizedQueueArePreservedAndBlockSubmission() async throws {
        for data in [Data("{broken".utf8), Data("{\"version\":999,\"trackIDs\":[]}".utf8), Data(repeating: 0, count: (2 << 20) + 1)] {
            let f = try makeFixture()
            try data.write(to: f.queue)
            let orphan = f.session.seed(token: UUID(), allowsCellular: true)
            await restore(f)
            await f.engine.setForeground(true)
            let added = await f.engine.enqueue([Self.track(Self.a)])
            XCTAssertEqual(added, 0)
            XCTAssertEqual(try Data(contentsOf: f.queue), data)
            XCTAssertTrue(f.session.cancelled.contains(orphan))
            XCTAssertTrue(f.session.requests.isEmpty)
            let error = await f.engine.storageFailure
            XCTAssertTrue(error)
        }
    }

    func testQueueWriteFailurePreventsSubmissionAndDoesNotAcknowledgeCancellation() async throws {
        let failWrites = BackgroundFlag(false)
        let f = try makeFixture(save: { record, url in
            if failWrites.value { throw BackgroundDownloadFailure.staging }
            try record.save(to: url)
        })
        await restore(f)
        await f.engine.setForeground(true)
        failWrites.value = true
        let added = await f.engine.enqueue([Self.track(Self.a)])
        XCTAssertEqual(added, 0)
        XCTAssertTrue(f.session.requests.isEmpty)
        failWrites.value = false
        await restore(f)
        await f.engine.enqueue([Self.track(Self.a)])
        try await wait { f.session.requests.count == 1 }
        failWrites.value = true
        let cancelled = await f.engine.cancel(Self.a)
        XCTAssertFalse(cancelled)
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).trackIDs, [Self.a])
        let blocked = await f.engine.storageFailure
        XCTAssertTrue(blocked)
        failWrites.value = false
        let retriedCancellation = await f.engine.cancel(Self.a)
        XCTAssertTrue(retriedCancellation)
    }

    func testPlanBookkeepingMustSaveBeforeTheOSTaskIsCreated() async throws {
        let f = try makeFixture(save: { record, url in
            if record.pending?.contains(where: { $0.phase == .transferring }) == true { throw BackgroundDownloadFailure.staging }
            try record.save(to: url)
        })
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a)])
        try await wait { await f.engine.storageFailure }
        XCTAssertTrue(f.session.requests.isEmpty)
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).pending?.first?.phase, .queued)
    }

    func testQueueRecoveryDropsRetiringTasksNoLongerOwnedByOS() async throws {
        let failWrites = BackgroundFlag(false)
        let f = try makeFixture(save: { record, url in
            if failWrites.value { throw BackgroundDownloadFailure.staging }
            try record.save(to: url)
        })
        await restore(f)
        await f.engine.setForeground(true)
        await f.engine.enqueue([Self.track(Self.a), Self.track(Self.b)])
        try await wait { f.session.requests.count == 2 }
        f.session.acknowledgesCancellation = false
        failWrites.value = true
        await f.engine.cancelAll()
        failWrites.value = false
        await restore(f)
        try await wait { f.session.requests.count == 4 }
        XCTAssertTrue(try DownloadQueueRecord.read(from: f.queue).pending?.allSatisfy { $0.attempts == 2 } == true)
    }

    func testLegacyQueueMigrationDropsMissingMetadataAndCancelsOrphanTasks() async throws {
        let f = try makeFixture()
        try DownloadQueueRecord(trackIDs: [Self.a, Self.b]).save(to: f.queue)
        let orphan = f.session.seed(token: UUID(), allowsCellular: false)
        await f.engine.restore { _ in [Self.track(Self.a)] }
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).version, 2)
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).trackIDs, [Self.a])
        XCTAssertTrue(f.session.cancelled.contains(orphan))
    }

    func testUnavailableLibraryLookupPreservesPendingIDsUntilRecovery() async throws {
        let f = try makeFixture()
        try DownloadQueueRecord(trackIDs: [Self.a]).save(to: f.queue)
        let original = try Data(contentsOf: f.queue)
        await f.engine.restore { _ in throw BackgroundDownloadFailure.staging }
        XCTAssertEqual(try Data(contentsOf: f.queue), original)
        let blocked = await f.engine.storageFailure
        XCTAssertTrue(blocked)
        await restore(f)
        XCTAssertEqual(try DownloadQueueRecord.read(from: f.queue).trackIDs, [Self.a])
    }

    func testBadResponseTypesLengthAndTruncatedRangesNeverGetReceipts() throws {
        let f = try makeFixture()
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let invalidHeaders = [
            ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": "\(payload.count)"],
            ["Content-Type": "audio/wav", "Content-Length": "\(payload.count + 1)"],
            ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)", "Content-Encoding": "gzip"],
            ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)", "Content-Range": "bytes 0-\(payload.count - 1)/\(payload.count + 1)"],
        ]
        for headers in invalidHeaders {
            let token = UUID()
            XCTAssertThrowsError(try f.session.stage(token: token, payload: payload,
                status: headers["Content-Range"] == nil ? 200 : 206, headers: headers))
            XCTAssertNil(try f.staging.load(token))
        }
        XCTAssertThrowsError(try f.session.stage(token: UUID(), payload: Data(repeating: 0, count: 128),
                                                headers: ["Content-Type": "audio/mp4", "Content-Length": "128"]))
        let valid = UUID()
        try f.session.stage(token: valid, payload: payload, status: 206,
            headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)", "Content-Range": "bytes 0-\(payload.count - 1)/\(payload.count)"])
        XCTAssertNotNil(try f.staging.load(valid))
    }

    func testCacheRejectsFakeMP4AndCancelledFenceWithoutDownloadedBadge() async throws {
        let f = try makeFixture()
        let fake = Data([0, 0, 0, 24] + Array("ftypM4A ".utf8) + Array(repeating: UInt8(0), count: 40))
        let token = UUID()
        try f.session.stage(token: token, payload: fake, headers: ["Content-Type": "audio/mp4", "Content-Length": "\(fake.count)"])
        let part = AudioDownloader.Part(url: f.staging.media(token), bytes: Int64(fake.count), fileExtension: "m4a")
        do {
            try await f.cache.publishBackgroundDownload(track: Self.track(Self.a), part: part,
                metadata: AudioCache.Sidecar(bytes: Int64(fake.count), storedAt: Date(), fileExtension: "m4a"), fence: DownloadPublicationFence())
            XCTFail("Magic bytes alone are not native audio validation")
        } catch { }
        let downloaded = await f.cache.isDownloaded(Self.a)
        XCTAssertFalse(downloaded)
        let cancelled = DownloadPublicationFence()
        cancelled.cancel()
        do { _ = try await f.cache.promoteToDownloads(Self.a, fence: cancelled); XCTFail("Cancelled fence must reject promotion") }
        catch is CancellationError { }
    }

    func testNativeWAVDeliveryPublishesFromOpaquePartURL() async throws {
        let f = try makeFixture()
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let token = UUID()
        try f.session.stage(token: token, payload: payload)
        let part = AudioDownloader.Part(url: f.staging.media(token), bytes: Int64(payload.count), fileExtension: "wav")
        XCTAssertEqual(part.url.pathExtension, "part")
        let metadata = AudioCache.Sidecar(duration: 1, bytes: part.bytes, storedAt: Date(), fileExtension: "wav")
        try await f.cache.publishBackgroundDownload(track: Self.track(Self.a), part: part,
                                                   metadata: metadata, fence: DownloadPublicationFence())
        let local = await f.cache.entry(for: Self.a)
        let audio = try XCTUnwrap(local)
        XCTAssertTrue(audio.isDownloaded)
        XCTAssertEqual(audio.url.pathExtension, "wav")
        XCTAssertEqual(try XCTUnwrap(audio.duration), 1, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: audio.url), payload)
        let readers = await f.cache.activeReaderCount
        XCTAssertEqual(readers, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.cache.directory.path), [])
    }

    func testNativeAACDeliveryPublishesFromOpaquePartURL() async throws {
        let f = try makeFixture()
        let wave = f.root.appendingPathComponent("source.wav")
        try PlaybackTestSupport.audioData(seconds: 1).write(to: wave)
        let encoded = f.root.appendingPathComponent("source.m4a")
        let stream = try await DebugFixtureAudio.exportAAC(from: wave, to: encoded)
        let payload = try Data(contentsOf: encoded)
        let token = UUID()
        try f.session.stage(token: token, payload: payload,
                            headers: ["Content-Type": "audio/mp4", "Content-Length": "\(payload.count)"])
        let part = AudioDownloader.Part(url: f.staging.media(token), bytes: Int64(payload.count), fileExtension: "m4a")
        XCTAssertEqual(part.url.pathExtension, "part")
        let metadata = AudioCache.Sidecar(duration: stream.duration, bytes: part.bytes, storedAt: Date(),
                                         fileExtension: "m4a", quality: stream.quality)
        try await f.cache.publishBackgroundDownload(track: Self.track(Self.a), part: part,
                                                   metadata: metadata, fence: DownloadPublicationFence())
        let local = await f.cache.entry(for: Self.a)
        let audio = try XCTUnwrap(local)
        XCTAssertTrue(audio.isDownloaded)
        XCTAssertEqual(audio.quality?.codec, .aac)
        XCTAssertEqual(try Data(contentsOf: audio.url), payload)
    }

    func testNativeContainerHintDoesNotAcceptMislabeledWAVAsAAC() async throws {
        let f = try makeFixture()
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let token = UUID()
        try f.session.stage(token: token, payload: payload)
        let part = AudioDownloader.Part(url: f.staging.media(token), bytes: Int64(payload.count), fileExtension: "m4a")
        let metadata = AudioCache.Sidecar(duration: 1, bytes: part.bytes, storedAt: Date(), fileExtension: "m4a",
                                         quality: SourceAudioQuality(codec: .aac, bitRate: 128_000))
        do {
            try await f.cache.publishBackgroundDownload(track: Self.track(Self.a), part: part,
                                                       metadata: metadata, fence: DownloadPublicationFence())
            XCTFail("A parser hint is not proof of codec or playable content")
        } catch { }
        let downloaded = await f.cache.isDownloaded(Self.a)
        XCTAssertFalse(downloaded)
        XCTAssertEqual(try Data(contentsOf: part.url), payload)
    }

    func testBackgroundOpusPublicationUsesExistingRemuxAndNativeValidationContract() async throws {
        let f = try makeFixture()
        let token = UUID()
        try f.session.stage(token: token, payload: OpusTestSupport.webM,
                            headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"])
        let part = AudioDownloader.Part(url: f.staging.media(token), bytes: Int64(OpusTestSupport.webM.count), fileExtension: "webm")
        let metadata = AudioCache.Sidecar(duration: 8, bytes: part.bytes, storedAt: Date(), fileExtension: "webm", quality: OpusTestSupport.opusQuality)
        try await f.cache.publishBackgroundDownload(track: Self.track(Self.a), part: part, metadata: metadata, fence: DownloadPublicationFence())
        let audio = await f.cache.entry(for: Self.a)
        XCTAssertEqual(audio?.opusPreparationVersion, 1)
        XCTAssertEqual(audio?.isDownloaded, true)
        XCTAssertEqual(audio?.quality?.codec, .opus)
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.url.path), "Caller owns staging cleanup after durable acknowledgement")
    }

    func testCacheMaintenanceRetainsDeliveryReaderAndRejectsStalePublication() async throws {
        let f = try makeFixture()
        let gate = BackgroundPublicationGate()
        let cache = AudioCache(directory: f.root.appendingPathComponent("MaintenanceAudio"),
                               downloadsDirectory: f.root.appendingPathComponent("MaintenanceDownloads"),
                               opusPreparation: { input, output in
            await gate.wait()
            XCTAssertTrue(FileManager.default.fileExists(atPath: input.path), "Maintenance cannot remove a native reader's input")
            return try await OpusTestSupport.prepare(input: input, output: output)
        })
        let token = UUID()
        try f.session.stage(token: token, payload: OpusTestSupport.webM,
                            headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"])
        let part = AudioDownloader.Part(url: f.staging.media(token), bytes: Int64(OpusTestSupport.webM.count), fileExtension: "webm")
        let metadata = AudioCache.Sidecar(duration: 8, bytes: part.bytes, storedAt: Date(), fileExtension: "webm", quality: OpusTestSupport.opusQuality)
        let task = Task { try await cache.publishBackgroundDownload(track: Self.track(Self.a), part: part,
                                                                    metadata: metadata, fence: DownloadPublicationFence()) }
        try await wait { gate.entered }
        _ = try await cache.clearUnused()
        gate.release()
        do { try await task.value; XCTFail("The pre-maintenance generation must not publish") }
        catch is CancellationError { }
        let downloaded = await cache.isDownloaded(Self.a)
        XCTAssertFalse(downloaded)
    }

    func testBackgroundManagerRemoveAndInUseDeleteKeepExistingTierSemantics() async throws {
        let f = try makeFixture()
        let manager = DownloadManager(store: f.cache, transfer: { _ in throw PlaybackStreamError.noAudio },
                                      connectivity: BackgroundConnectivity(), queueFile: f.queue, background: f.engine)
        await manager.restore { ids in ids.map(Self.track) }
        await manager.setForeground(true)
        await manager.enqueue([Self.track(Self.a)])
        try await wait { f.session.requests.count == 1 }
        try f.session.deliver(f.session.requests[0].id, payload: PlaybackTestSupport.audioData(seconds: 1))
        try await wait { await f.engine.items.isEmpty }
        let removed = try await manager.removeDownload(Self.a)
        guard case .moved = removed else { return XCTFail("Remove must demote") }
        let cached = await f.cache.entry(for: Self.a)
        XCTAssertEqual(cached?.isDownloaded, false)
        await manager.enqueue([Self.track(Self.a)])
        try await wait { await f.cache.isDownloaded(Self.a) }
        await f.cache.pin(Self.a)
        let deleted = try await manager.deleteDownload(Self.a)
        guard case .demotedInUse = deleted else { return XCTFail("An in-use reader must retain its file") }
        let retained = await f.cache.entry(for: Self.a)
        XCTAssertNotNil(retained)
        XCTAssertEqual(retained?.isDownloaded, false)
        await f.cache.unpin(Self.a)
        XCTAssertEqual(f.session.requests.count, 1, "A cached promotion never starts a new transfer")
    }

    func testApplicationCompletionWaitsForDrainAndAlsoHandlesEarlyDrain() {
        var finished = 0
        XCTAssertFalse(BackgroundDownloadCompletion.handleEvents(identifier: "unrelated", completionHandler: { finished += 100 }))
        XCTAssertTrue(BackgroundDownloadCompletion.handleEvents(identifier: SystemBackgroundDownloadSession.identifier, completionHandler: { finished += 1 }))
        XCTAssertEqual(finished, 0)
        BackgroundDownloadCompletion.didDrain()
        XCTAssertEqual(finished, 1)
        BackgroundDownloadCompletion.didDrain()
        XCTAssertTrue(BackgroundDownloadCompletion.handleEvents(identifier: SystemBackgroundDownloadSession.identifier, completionHandler: { finished += 1 }))
        XCTAssertEqual(finished, 2)
    }

    // MARK: Fixtures

    private struct Fixture {
        let root: URL
        let queue: URL
        let cache: AudioCache
        let staging: BackgroundDownloadStaging
        let session: BackgroundSessionDouble
        let engine: BackgroundDownloadEngine
    }

    private func makeFixture(connectivity: BackgroundConnectivity = BackgroundConnectivity(),
                             planner: BackgroundDownloadEngine.Planner? = nil,
                             publication: BackgroundDownloadEngine.Publication? = nil,
                             save: BackgroundDownloadEngine.Save? = nil,
                             now: @escaping @Sendable () -> Date = { Date() }) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundDownloadsTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = root.appendingPathComponent("downloads-queue.json")
        let staging = BackgroundDownloadStaging(directory: root.appendingPathComponent("DownloadStaging"))
        let session = BackgroundSessionDouble(staging: staging)
        let cache = AudioCache(directory: root.appendingPathComponent("Audio"), downloadsDirectory: root.appendingPathComponent("Downloads"),
                               opusPreparation: { try await OpusTestSupport.prepare(input: $0, output: $1) })
        let engine = BackgroundDownloadEngine(store: cache, planner: planner ?? { _ in try Self.plan() },
            publication: { track, part, metadata, fence in
                try await publication?(track, part, metadata, fence)
                try await cache.publishBackgroundDownload(track: track, part: part, metadata: metadata, fence: fence)
            }, promotion: { try await cache.promoteToDownloads($0, fence: $1) }, session: session, staging: staging,
            queueFile: queue, connectivity: connectivity, backoff: [0.001, 0.001], transientBackoff: [0.001, 0.001, 0.001, 0.001],
            now: now, save: save ?? { try $0.save(to: $1) })
        addTeardownBlock {
            await engine.cancelAll()
            session.finish()
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, queue: queue, cache: cache, staging: staging, session: session, engine: engine)
    }

    private func restore(_ f: Fixture) async {
        await f.engine.restore { ids in ids.map(Self.track) }
    }

    private func seed(_ pending: [BackgroundPendingDownload], at url: URL) throws {
        var record = DownloadQueueRecord(trackIDs: pending.map(\.id))
        record.version = 2
        record.pending = pending
        try record.save(to: url)
    }

    nonisolated private static var remote: URL { URL(string: "https://audio.googlevideo.com/file.wav?signature=TOP_SECRET")! }
    nonisolated private static func plan() throws -> BackgroundDownloadPlan {
        try BackgroundDownloadPlan(stream: ResolvedStream(url: remote, duration: 1))
    }
    nonisolated private static func track(_ id: String) -> Track {
        Track(id: id, title: "Fixture Song", artists: ["Fixture Artist"], duration: 1)
    }

    private func wait(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the download boundary", file: file, line: line)
        throw PlaybackStreamError.timedOut
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }
}

private final class BackgroundSessionDouble: BackgroundDownloadSession, Sendable {
    struct Request: Sendable { let id: Int; let token: UUID; let request: URLRequest }
    private struct State {
        var next = 1
        var live: [Int: Request] = [:]
        var requests: [Request] = []
        var resumed: [Int] = []
        var cancelled: [Int] = []
        var acknowledgesCancellation = true
    }
    let events: AsyncStream<BackgroundDownloadEvent>
    private let feed: AsyncStream<BackgroundDownloadEvent>.Continuation
    private let state = Mutex(State())
    private let staging: BackgroundDownloadStaging
    init(staging: BackgroundDownloadStaging) {
        self.staging = staging
        let channel = AsyncStream<BackgroundDownloadEvent>.makeStream()
        events = channel.stream
        feed = channel.continuation
    }
    var requests: [Request] { state.withLock { $0.requests } }
    var resumed: [Int] { state.withLock { $0.resumed } }
    var cancelled: [Int] { state.withLock { $0.cancelled } }
    var acknowledgesCancellation: Bool {
        get { state.withLock { $0.acknowledgesCancellation } }
        set { state.withLock { $0.acknowledgesCancellation = newValue } }
    }
    func allTasks() async -> [BackgroundDownloadTask] {
        state.withLock { $0.live.values.map { BackgroundDownloadTask(id: $0.id, token: $0.token, allowsCellular: $0.request.allowsCellularAccess) } }
    }
    func create(_ request: URLRequest, token: UUID) -> Int {
        state.withLock {
            let value = Request(id: $0.next, token: token, request: request)
            $0.next += 1
            $0.live[value.id] = value
            $0.requests.append(value)
            return value.id
        }
    }
    func seed(token: UUID, allowsCellular: Bool) -> Int {
        var request = URLRequest(url: URL(string: "https://example.com/audio.wav")!)
        request.allowsCellularAccess = allowsCellular
        let id = create(request, token: token)
        state.withLock { $0.requests.removeAll { $0.id == id } }
        return id
    }
    func resume(_ id: Int) { state.withLock { $0.resumed.append(id) } }
    func cancel(_ id: Int) {
        let acknowledge = state.withLock { value in
            value.cancelled.append(id)
            value.live.removeValue(forKey: id)
            return value.acknowledgesCancellation
        }
        if acknowledge { acknowledgeCancellation(id) }
    }
    func acknowledgeCancellation(_ id: Int) { feed.yield(.completed(id)) }
    func send(_ event: BackgroundDownloadEvent) { feed.yield(event) }
    func finish() { feed.finish() }
    func fail(_ id: Int, _ failure: BackgroundDownloadFailure) {
        guard let request = state.withLock({ $0.live.removeValue(forKey: id) }) else { return }
        feed.yield(.failed(request.token, failure, taskID: id))
        feed.yield(.completed(id))
    }
    func deliver(_ id: Int, payload: Data) throws {
        guard let request = state.withLock({ $0.live.removeValue(forKey: id) }) else { throw BackgroundDownloadFailure.interrupted }
        try stage(token: request.token, payload: payload)
        feed.yield(.delivered(request.token, taskID: id))
        feed.yield(.completed(id))
    }
    func stage(token: UUID, payload: Data, status: Int = 200, headers: [String: String]? = nil) throws {
        let temporary = staging.directory.deletingLastPathComponent().appendingPathComponent("delivery-\(UUID())")
        try payload.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let response = HTTPURLResponse(url: URL(string: "https://example.com/file?signature=TOP_SECRET")!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers ?? ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"])!
        try staging.receive(temporary, token: token, response: response, declaredBytes: nil)
    }
}

private final class BackgroundConnectivity: DownloadConnectivity, Sendable {
    private let value: Mutex<Bool>
    init(expensive: Bool = false) { value = Mutex(expensive) }
    var expensive: Bool { get { value.withLock { $0 } } set { value.withLock { $0 = newValue } } }
    var isOffline: Bool { false }
    var isExpensivePath: Bool { expensive }
}

private final class BackgroundCounter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    @discardableResult func increment() -> Int { storage.withLock { $0 += 1; return $0 } }
}

/// The real cache, except that a copy of the song is being written when the engine asks and finishes during the wait.
private final class BackgroundCopyInProgressStore: DownloadTierStore, Sendable {
    let cache: AudioCache
    let waits = BackgroundCounter()
    private let finishCopy: @Sendable (AudioCache) async -> Void
    init(cache: AudioCache, finishCopy: @escaping @Sendable (AudioCache) async -> Void) {
        self.cache = cache
        self.finishCopy = finishCopy
    }
    func waitForCopyInProgress(of trackID: String, allowOpus: Bool, seconds: TimeInterval) async -> Bool {
        waits.increment()
        await finishCopy(cache)
        if cache.isDownloaded(trackID: trackID) { return true }
        return await cache.hasCompleteCopy(of: trackID, allowOpus: allowOpus)
    }
    func hasCompleteCopy(of trackID: String, allowOpus: Bool) async -> Bool { await cache.hasCompleteCopy(of: trackID, allowOpus: allowOpus) }
    func promoteToDownloads(_ trackID: String) async throws -> AudioCache.DownloadTierChange { try await cache.promoteToDownloads(trackID) }
    func demoteToCache(_ trackID: String) async throws -> AudioCache.DownloadTierChange { try await cache.demoteToCache(trackID) }
    func deleteDownload(_ trackID: String) async throws -> AudioCache.DownloadDeletion { try await cache.deleteDownload(trackID) }
    func isDownloaded(_ trackID: String) async -> Bool { await cache.isDownloaded(trackID) }
    func entry(for trackID: String, allowOpus: Bool) async -> CachedAudio? { await cache.entry(for: trackID, allowOpus: allowOpus) }
    func withLocalCopy<Result: Sendable>(for trackID: String, allowOpus: Bool,
                                         operation: @Sendable (CachedAudio) async throws -> Result) async throws -> Result? {
        try await cache.withLocalCopy(for: trackID, allowOpus: allowOpus, operation: operation)
    }
    nonisolated func transferProgress(for trackID: String) -> Double? { cache.transferProgress(for: trackID) }
}

private final class BackgroundFlag: Sendable {
    private let storage: Mutex<Bool>
    init(_ value: Bool) { storage = Mutex(value) }
    var value: Bool { get { storage.withLock { $0 } } set { storage.withLock { $0 = newValue } } }
}

private final class BackgroundClock: Sendable {
    private let storage = Mutex(Date())
    var now: Date { storage.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { storage.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

private final class BackgroundPublicationGate: Sendable {
    private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
    var entered: Bool { continuation.withLock { $0 != nil } }
    func wait() async { await withCheckedContinuation { value in continuation.withLock { $0 = value } } }
    func release() { continuation.withLock { let result = $0; $0 = nil; return result }?.resume() }
}
