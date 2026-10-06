import AVFoundation
import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackPreloaderTests: XCTestCase {
    private func track(_ id: String) -> Track { Track(id: id, title: id) }
    private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.id) }

    private func makePreloader(_ resolver: any StreamResolving, log: AssetLoadLog = AssetLoadLog(),
                               store: PlaybackPreloadStore = PlaybackPreloadStore(),
                               now: @escaping @MainActor () -> Date = { Date() }) -> PlaybackPreloader {
        PlaybackPreloader(resolver: resolver, store: store, loadAsset: { url in
            log.urls.append(url)
            return AVURLAsset(url: url)
        }, enabled: true, now: now)
    }

    // MARK: Queue lane

    func testQueueLanePreparesTheNextFiveEligibleSongsNearestFirstTwoAtATime() async throws {
        let fake = PreloadResolverFake(holds: true)
        addTeardownBlock { await fake.release() }
        let log = AssetLoadLog()
        let preloader = makePreloader(fake, log: log)
        var video = track("video000001")
        video.isAudioRecording = false
        let songs = (1...6).map { track("queue00000\($0)") }
        preloader.setQueue([songs[0], songs[0], video, track("gaana:123")] + Array(songs[1...]))
        let expected = ids(Array(songs.prefix(5)))
        XCTAssertEqual(ids(preloader.queueTracks), expected, "Videos, Gaana HLS and duplicates never take a queue slot")

        try await PlaybackTestSupport.eventually { await fake.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(150))
        let held = await fake.calls
        XCTAssertEqual(Set(held), [songs[0].id, songs[1].id], "The two nearest songs go first")
        XCTAssertEqual(held.count, PlaybackPreloader.concurrency, "No third request starts while two are in flight")
        XCTAssertEqual(preloader.activeTrackIDs, [songs[0].id, songs[1].id])

        await fake.release()
        try await PlaybackTestSupport.waitUntil { preloader.preparedCount == 5 && preloader.activeTrackIDs.isEmpty }
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(Set(calls), Set(expected))
        let peak = await fake.maxInFlight
        XCTAssertEqual(peak, PlaybackPreloader.concurrency)
        XCTAssertEqual(preloader.store.count, 5)
        XCTAssertEqual(Set(preloader.store.trackIDs), Set(expected))
        XCTAssertEqual(log.urls.count, 5)
        XCTAssertFalse(calls.contains(songs[5].id), "The sixth eligible song is beyond the queue depth")
    }

    func testHoldingDefersNewWorkUntilReleased() async throws {
        let fake = PreloadResolverFake()
        let preloader = makePreloader(fake)
        preloader.setHolding(true)
        XCTAssertTrue(preloader.isHolding)
        preloader.setQueue([track("hold0000001"), track("hold0000002")])
        try await Task.sleep(for: .milliseconds(150))
        let waiting = await fake.calls
        XCTAssertTrue(waiting.isEmpty, "A starting song never competes with speculative work")
        XCTAssertTrue(preloader.activeTrackIDs.isEmpty)

        preloader.setHolding(false)
        try await PlaybackTestSupport.waitUntil { preloader.preparedCount == 2 }
        let calls = await fake.calls
        XCTAssertEqual(Set(calls), ["hold0000001", "hold0000002"])
    }

    func testShiftingTheWindowRequestsOnlyTheNewSongAndKeepsPreparedAssets() async throws {
        let fake = PreloadResolverFake()
        let preloader = makePreloader(fake)
        let songs = ["B", "C", "D", "E", "F", "G"].map { track("shift00000\($0)") }
        preloader.setQueue(Array(songs[0..<5]))
        try await PlaybackTestSupport.waitUntil { preloader.preparedCount == 5 && preloader.activeTrackIDs.isEmpty }

        preloader.setQueue(Array(songs[1..<6]))
        try await PlaybackTestSupport.waitUntil { preloader.preparedCount == 6 && preloader.activeTrackIDs.isEmpty }
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 6, "Songs already prepared are not requested again")
        XCTAssertEqual(calls.last, songs[5].id)
        XCTAssertTrue(preloader.store.hasUsableAsset(trackID: songs[0].id), "Leaving the window does not discard an asset")
        XCTAssertEqual(preloader.store.count, 6)
    }

    // MARK: Browse lane

    func testQueueSongsPrecedeBrowseSongsAndBrowseIsLimitedToThree() async throws {
        let fake = PreloadResolverFake(holds: true)
        addTeardownBlock { await fake.release() }
        let preloader = makePreloader(fake)
        let queue = [track("queue000001"), track("queue000002")]
        let browse = (1...4).map { track("browse00000\($0)") }
        preloader.setHolding(true)
        preloader.setBrowse(browse, owner: PlaybackWarmer.searchOwner)
        preloader.setQueue(queue)
        XCTAssertEqual(ids(Array(preloader.browseTracks.prefix(3))), ids(Array(browse.prefix(3))))
        preloader.setHolding(false)

        try await PlaybackTestSupport.eventually { await fake.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        let first = await fake.calls
        XCTAssertEqual(Set(first), Set(ids(queue)), "The listener's own queue goes before a browsing guess")

        await fake.release()
        try await PlaybackTestSupport.waitUntil { preloader.preparedCount == 5 && preloader.activeTrackIDs.isEmpty }
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(Set(calls), Set(ids(queue) + ids(Array(browse.prefix(3)))))
        XCTAssertFalse(calls.contains(browse[3].id))
    }

    func testABrowseCandidateAlreadyInTheQueueIsRequestedOnce() async throws {
        let fake = PreloadResolverFake()
        let preloader = makePreloader(fake)
        let shared = track("shared00001")
        let other = track("browse00001")
        preloader.setHolding(true)
        preloader.setQueue([shared])
        preloader.setBrowse([shared, other], owner: "album")
        preloader.setHolding(false)
        try await PlaybackTestSupport.waitUntil { preloader.preparedCount == 2 && preloader.activeTrackIDs.isEmpty }
        let calls = await fake.calls
        XCTAssertEqual(calls.filter { $0 == shared.id }.count, 1)
        XCTAssertEqual(calls.count, 2)
    }

    func testNetworkGatesProtectBrowseOnExpensivePathsAndStopEverythingWhenConstrainedOrOffline() async throws {
        let fake = PreloadResolverFake()
        addTeardownBlock { await fake.release() }
        let preloader = makePreloader(fake)
        let network = NetworkGate()
        network.expensive = true
        network.allowsExpensive = false
        preloader.network = network.value
        let first = track("queue000001")
        let second = track("queue000002")
        let browse = track("browse00001")
        preloader.setBrowse([browse], owner: PlaybackWarmer.searchOwner)
        preloader.setQueue([first])
        try await PlaybackTestSupport.waitUntil { preloader.preparedCount == 1 && preloader.activeTrackIDs.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        let unconsented = await fake.calls
        XCTAssertEqual(unconsented, [first.id], "Cellular without consent still prepares the listener's own queue")

        network.allowsExpensive = true
        preloader.network = network.value
        try await PlaybackTestSupport.waitUntil { preloader.preparedCount == 2 }
        XCTAssertTrue(preloader.store.hasUsableAsset(trackID: browse.id))

        await fake.setHolds(true)
        preloader.setQueue([first, second])
        try await PlaybackTestSupport.eventually { await fake.calls.contains(second.id) }
        network.constrained = true
        preloader.network = network.value
        XCTAssertTrue(preloader.activeTrackIDs.isEmpty)
        try await PlaybackTestSupport.eventually { await fake.cancelledIDs == [second.id] }

        network.constrained = false
        network.offline = true
        preloader.network = network.value
        try await Task.sleep(for: .milliseconds(150))
        let offlineCount = await fake.calls.filter { $0 == second.id }.count
        XCTAssertEqual(offlineCount, 1, "Offline starts nothing")

        network.offline = false
        preloader.network = network.value
        try await PlaybackTestSupport.eventually { await fake.calls.filter { $0 == second.id }.count == 2 }
        network.offline = true
        preloader.network = network.value
        XCTAssertTrue(preloader.activeTrackIDs.isEmpty)
        try await PlaybackTestSupport.eventually { await fake.cancelledIDs == [second.id, second.id] }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(preloader.store.hasUsableAsset(trackID: second.id), "Cancelled work stores nothing")
        XCTAssertEqual(preloader.preparedCount, 2)
    }

    func testCancelBrowseClearsOnlyItsOwnersRequest() {
        let preloader = makePreloader(PreloadResolverFake())
        preloader.setHolding(true)
        let browse = [track("browse00001")]
        preloader.setBrowse(browse, owner: "album-b")
        preloader.cancelBrowse(owner: "album-a")
        XCTAssertEqual(ids(preloader.browseTracks), ids(browse), "A late disappearance of an older page leaves the newer request")
        preloader.cancelBrowse(owner: "album-b")
        XCTAssertTrue(preloader.browseTracks.isEmpty)

        preloader.setBrowse(browse, owner: "album-c")
        preloader.cancelBrowse()
        XCTAssertTrue(preloader.browseTracks.isEmpty, "An ownerless cancel clears any request")
    }

    // MARK: Failures

    func testUnavailableSongsAreSkippedAndFailuresCoolDownUntilTheirLifetimesPass() async throws {
        let unavailable = track("nilstream01")
        let failing = track("failing0001")
        let fake = PreloadResolverFake(nilIDs: [unavailable.id], failingIDs: [failing.id])
        let clock = TestClock()
        let preloader = makePreloader(fake, now: { clock.now })
        preloader.setQueue([unavailable, failing])
        try await PlaybackTestSupport.eventually { await fake.calls.count == 2 && preloader.activeTrackIDs.isEmpty }
        XCTAssertEqual(preloader.preparedCount, 0)

        let ready = track("ready000001")
        preloader.setQueue([unavailable, failing, ready])
        try await PlaybackTestSupport.waitUntil { preloader.preparedCount == 1 && preloader.activeTrackIDs.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        let calls = await fake.calls
        XCTAssertEqual(calls.filter { $0 == unavailable.id }.count, 1, "A song with nothing to preload is not asked again")
        XCTAssertEqual(calls.filter { $0 == failing.id }.count, 1, "A failure is not retried within its cooldown")
        XCTAssertEqual(calls.count, 3)

        clock.now = clock.now.addingTimeInterval(PlaybackPreloader.skipLifetime + 1)
        preloader.setQueue([unavailable, failing, ready, track("ready000002")])
        try await PlaybackTestSupport.waitUntil { preloader.preparedCount == 2 && preloader.activeTrackIDs.isEmpty }
        let later = await fake.calls
        XCTAssertEqual(later.filter { $0 == unavailable.id }.count, 2)
        XCTAssertEqual(later.filter { $0 == failing.id }.count, 2)
        XCTAssertEqual(later.filter { $0 == ready.id }.count, 1)
    }

    func testABusyResolverIsRetriedAfterTheBusyDelay() async throws {
        let busy = track("busy0000001")
        let fake = PreloadResolverFake(busyOnceIDs: [busy.id])
        let preloader = makePreloader(fake)
        preloader.setQueue([busy])
        try await PlaybackTestSupport.eventually { await fake.calls.count == 1 && preloader.activeTrackIDs.isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        let early = await fake.calls.count
        XCTAssertEqual(early, 1, "A busy refusal waits out its cooldown")
        XCTAssertEqual(preloader.preparedCount, 0)

        try await PlaybackTestSupport.waitUntil(timeout: 3) { preloader.preparedCount == 1 }
        let calls = await fake.calls
        XCTAssertEqual(calls, [busy.id, busy.id])
        XCTAssertTrue(preloader.store.hasUsableAsset(trackID: busy.id))
    }

    func testAStreamCloseToExpiryIsNotStored() async throws {
        let expiring = track("expiring001")
        let fresh = track("fresh000001")
        let fake = PreloadResolverFake(shortLivedIDs: [expiring.id])
        let log = AssetLoadLog()
        let preloader = makePreloader(fake, log: log)
        preloader.setQueue([expiring, fresh])
        try await PlaybackTestSupport.eventually { await fake.calls.count == 2 && preloader.activeTrackIDs.isEmpty }
        XCTAssertEqual(preloader.preparedCount, 1)
        XCTAssertFalse(preloader.store.hasUsableAsset(trackID: expiring.id))
        XCTAssertTrue(preloader.store.hasUsableAsset(trackID: fresh.id))
        XCTAssertEqual(log.urls.map(\.lastPathComponent), ["\(fresh.id).m4a"], "An expiring URL is never even opened")
    }

    // MARK: Store

    func testStoreMatchesExactURLsEvictsLeastRecentlyUsedAndPrunesExpiry() async throws {
        let clock = TestClock()
        let store = PlaybackPreloadStore(capacity: 2, now: { clock.now })
        let urlA = URL(string: "https://example.invalid/a.m4a?sig=1")!
        let assetA = AVURLAsset(url: urlA)
        store.store(.init(trackID: "a", url: urlA, asset: assetA, expiresAt: nil))
        XCTAssertNil(store.asset(trackID: "b", url: urlA))
        XCTAssertTrue(store.asset(trackID: "a", url: urlA) === assetA)
        XCTAssertNil(store.asset(trackID: "a", url: URL(string: "https://example.invalid/a.m4a?sig=2")!),
                     "An asset is bound to the signed URL it loaded")
        XCTAssertFalse(store.hasUsableAsset(trackID: "a"), "A newer signed URL retires the stale preparation")
        store.store(.init(trackID: "a", url: urlA, asset: assetA, expiresAt: nil))

        let urlB = URL(string: "https://example.invalid/b.m4a")!
        let urlC = URL(string: "https://example.invalid/c.m4a")!
        store.store(.init(trackID: "b", url: urlB, asset: AVURLAsset(url: urlB), expiresAt: nil))
        _ = store.asset(trackID: "a", url: urlA)
        store.store(.init(trackID: "c", url: urlC, asset: AVURLAsset(url: urlC), expiresAt: nil))
        XCTAssertEqual(store.trackIDs, ["a", "c"], "The least recently used entry leaves first")

        let urlD = URL(string: "https://example.invalid/d.m4a")!
        store.store(.init(trackID: "d", url: urlD, asset: AVURLAsset(url: urlD), expiresAt: clock.now.addingTimeInterval(100)))
        XCTAssertTrue(store.hasUsableAsset(trackID: "d"))
        clock.now = clock.now.addingTimeInterval(11)
        XCTAssertFalse(store.hasUsableAsset(trackID: "d"), "Under the minimum remaining lifetime an asset would fail mid-song")
        XCTAssertEqual(store.trackIDs, ["c"])

        store.removeAll()
        XCTAssertEqual(store.count, 0)

        store.store(.init(trackID: "a", url: urlA, asset: assetA, expiresAt: nil))
        XCTAssertEqual(store.count, 1)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await PlaybackTestSupport.waitUntil(timeout: 2) { store.count == 0 }
    }

    func testMakeItemReusesAStoredAssetOnlyForTheExactRemoteURL() {
        let store = PlaybackPreloadStore()
        let url = URL(string: "https://example.invalid/song.m4a?expire=1")!
        let asset = AVURLAsset(url: url)
        store.store(.init(trackID: "song", url: url, asset: asset, expiresAt: nil))

        let hit = PlaybackStreamLoading.makeItem(stream: ResolvedStream(url: url), trackID: "song", duration: 200, preloads: store)
        XCTAssertTrue(hit.usesPreload)
        XCTAssertTrue(hit.item.asset === asset)

        let other = URL(string: "https://example.invalid/song.m4a?expire=2")!
        let miss = PlaybackStreamLoading.makeItem(stream: ResolvedStream(url: other), trackID: "song", duration: 200, preloads: store)
        XCTAssertFalse(miss.usesPreload)
        XCTAssertFalse(miss.item.asset === asset)
        XCTAssertEqual((miss.item.asset as? AVURLAsset)?.url, other)

        let anonymous = PlaybackStreamLoading.makeItem(stream: ResolvedStream(url: url), trackID: nil, duration: 200, preloads: store)
        XCTAssertFalse(anonymous.usesPreload)
        XCTAssertFalse(anonymous.item.asset === asset)

        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preloaded.m4a")
        let fileAsset = AVURLAsset(url: file)
        store.store(.init(trackID: "local", url: file, asset: fileAsset, expiresAt: nil))
        let local = PlaybackStreamLoading.makeItem(stream: ResolvedStream(url: file), trackID: "local", duration: 200, preloads: store)
        XCTAssertFalse(local.usesPreload, "Local files start instantly without a preloaded asset")
        XCTAssertFalse(local.item.asset === fileAsset)
    }

    // MARK: Warmer routing

    func testWarmerRoutesProgressiveSongsToThePreloaderAndURLWarmsOnlyGaana() async throws {
        let fake = RoutingResolverFake()
        let preloader = makePreloader(fake)
        let warmer = PlaybackWarmer(resolver: fake, network: PlaybackWarmer.Network(
            isOffline: { false }, isExpensive: { false }, isConstrained: { false }, allowsExpensive: { true }),
                                    preloader: preloader, enabled: true)
        let songs = [track("youtube0001"), track("saavn:1"), track("gaana:1"), track("youtube0002")]
        warmer.warm(songs, surface: .search, owner: PlaybackWarmer.searchOwner)
        // The search limit of three applies to the event before routing, so the fourth song reaches neither path.
        XCTAssertEqual(ids(preloader.browseTracks), ["youtube0001", "saavn:1"])

        try await PlaybackTestSupport.eventually { await fake.warms.count == 1 }
        let warm = await fake.warms[0]
        XCTAssertEqual(warm.ids, ["gaana:1"], "Only HLS songs still need a warm signed URL")
        XCTAssertFalse(warm.download, "A preloader makes the speculative complete download unnecessary")
        try await PlaybackTestSupport.eventually { await fake.preloadCalls.count == 2 }
        let preloads = await fake.preloadCalls
        XCTAssertEqual(Set(preloads), ["youtube0001", "saavn:1"])

        warmer.cancel(owner: "album")
        XCTAssertEqual(ids(preloader.browseTracks), ["youtube0001", "saavn:1"], "Another page's cancel leaves this request")
        warmer.cancel(owner: PlaybackWarmer.searchOwner)
        XCTAssertTrue(preloader.browseTracks.isEmpty)
    }
}

@MainActor
private final class AssetLoadLog {
    var urls: [URL] = []
}

@MainActor
private final class TestClock {
    // Starts at the real time because the fake signs URLs relative to the wall clock.
    var now = Date()
}

@MainActor
private final class NetworkGate {
    var offline = false
    var constrained = false
    var expensive = false
    var allowsExpensive = true

    var value: PlaybackPreloader.Network {
        PlaybackPreloader.Network(isOffline: { self.offline }, isConstrained: { self.constrained },
                                  isExpensive: { self.expensive }, allowsExpensive: { self.allowsExpensive })
    }
}

/// Records preload requests in arrival order and can hold each one open so tests observe concurrency and cancellation.
private actor PreloadResolverFake: PlaybackPreloadResolving {
    private(set) var calls: [String] = []
    private(set) var cancelledIDs: [String] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private var holds: Bool
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let nilIDs: Set<String>
    private let failingIDs: Set<String>
    private var busyOnceIDs: Set<String>
    private let shortLivedIDs: Set<String>

    init(holds: Bool = false, nilIDs: Set<String> = [], failingIDs: Set<String> = [], busyOnceIDs: Set<String> = [],
         shortLivedIDs: Set<String> = []) {
        self.holds = holds
        self.nilIDs = nilIDs
        self.failingIDs = failingIDs
        self.busyOnceIDs = busyOnceIDs
        self.shortLivedIDs = shortLivedIDs
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        throw PlaybackStreamError.noAudio
    }

    func preloadStream(for track: Track) async throws -> ResolvedStream? {
        calls.append(track.id)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if holds { await hold(track.id) }
        try Task.checkCancellation()
        // A plain CancellationError in an uncancelled task is how the resolver reports full background slots.
        if busyOnceIDs.remove(track.id) != nil { throw CancellationError() }
        if failingIDs.contains(track.id) { throw PlaybackStreamError.noAudio }
        if nilIDs.contains(track.id) { return nil }
        let lifetime: TimeInterval = shortLivedIDs.contains(track.id) ? 60 : 3_600
        let expire = Int(Date().timeIntervalSince1970 + lifetime)
        return ResolvedStream(url: URL(string: "https://example.invalid/\(track.id).m4a?expire=\(expire)")!)
    }

    func setHolds(_ holds: Bool) { self.holds = holds }

    func release() {
        holds = false
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func hold(_ id: String) async {
        let key = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[key] = $0 }
        } onCancel: {
            Task { await self.cancelled(key, id: id) }
        }
    }

    private func cancelled(_ key: UUID, id: String) {
        guard let waiter = waiters.removeValue(forKey: key) else { return }
        cancelledIDs.append(id)
        waiter.resume()
    }
}

/// A resolver offering both paths, so the warmer's routing between URL warming and preloading is observable.
private actor RoutingResolverFake: StreamWarming, PlaybackPreloadResolving {
    struct Warm: Sendable {
        let ids: [String]
        let download: Bool
    }

    private(set) var warms: [Warm] = []
    private(set) var preloadCalls: [String] = []

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        throw PlaybackStreamError.noAudio
    }

    func warm(_ tracks: [Track], download: Bool, token: UUID) async -> StreamWarmOutcome {
        warms.append(Warm(ids: tracks.map(\.id), download: download))
        return StreamWarmOutcome(resolved: tracks.count)
    }

    func preloadStream(for track: Track) async throws -> ResolvedStream? {
        preloadCalls.append(track.id)
        return nil
    }
}
