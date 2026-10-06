import AVFoundation
import Foundation
import OSLog
import UIKit

/// Resolvers that can name the remote stream worth preloading without starting a complete download. Nil means
/// preloading does not apply: a complete local copy exists or the source streams HLS.
protocol PlaybackPreloadResolving: StreamResolving {
    func preloadStream(for track: Track) async throws -> ResolvedStream?
}

/// Remote assets whose metadata (duration, tracks, playability) has already loaded. A new item built from one skips
/// AVFoundation's opening round trips, which dominate a warm-URL start. Nothing here is persisted or counted as cache.
@MainActor
final class PlaybackPreloadStore {
    static let shared = PlaybackPreloadStore()
    static let defaultCapacity = 8
    /// The same rule as the resolver's signed-URL reuse: an asset this close to expiry would fail mid-song.
    static let minimumRemainingLifetime: TimeInterval = 90

    struct Entry {
        let trackID: String
        let url: URL
        let asset: AVURLAsset
        let expiresAt: Date?
    }

    private var entries: [Entry] = []
    let capacity: Int
    private let now: @MainActor () -> Date
    private var memoryObserver: NSObjectProtocol?

    init(capacity: Int = PlaybackPreloadStore.defaultCapacity, now: @escaping @MainActor () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.now = now
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }

    isolated deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    var count: Int { entries.count }
    var trackIDs: [String] { entries.map(\.trackID) }

    /// Only the exact signed URL qualifies: an asset is bound to the URL it loaded. A prepared asset for an older URL
    /// of the same song is dropped so the preloader prepares the current one again.
    func asset(trackID: String, url: URL) -> AVURLAsset? {
        pruneExpired()
        guard let index = entries.firstIndex(where: { $0.trackID == trackID && $0.url == url }) else {
            entries.removeAll { $0.trackID == trackID }
            return nil
        }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.asset
    }

    func hasUsableAsset(trackID: String) -> Bool {
        pruneExpired()
        return entries.contains { $0.trackID == trackID }
    }

    /// Evicted assets are only released: an item built from one may still be playing, and its loads are finished.
    func store(_ entry: Entry) {
        entries.removeAll { $0.trackID == entry.trackID }
        entries.append(entry)
        while entries.count > capacity { entries.removeFirst() }
    }

    func remove(trackID: String) {
        entries.removeAll { $0.trackID == trackID }
    }

    func removeAll() {
        entries.removeAll()
    }

    private func pruneExpired() {
        let current = now()
        entries.removeAll { entry in
            guard let expiresAt = entry.expiresAt else { return false }
            return expiresAt.timeIntervalSince(current) < Self.minimumRemainingLifetime
        }
    }
}

/// Keeps the songs a listener is likely to start next ready to play: the queue's next five in play order, then what
/// a browsing surface offers. Nearest songs come first, and new work waits while the selected song is starting.
/// Bounds and gates are in `docs/FAST_START.md`.
@MainActor
final class PlaybackPreloader {
    enum Lane: String, Sendable { case queue, browse }

    static let queueDepth = 5
    static let browseLimit = 3
    static let concurrency = 2
    static let failureCooldown: TimeInterval = 60
    static let busyCooldown: TimeInterval = 1.5
    static let busyRetryDelay: Duration = .milliseconds(1600)
    static let skipLifetime: TimeInterval = 600
    static let loadTimeout: TimeInterval = 10

    struct Network {
        var isOffline: @MainActor () -> Bool
        var isConstrained: @MainActor () -> Bool
        var isExpensive: @MainActor () -> Bool
        /// `downloadsOverCellular`; browsing surfaces need it on an expensive path, the listener's own queue does not.
        var allowsExpensive: @MainActor () -> Bool

        static let unrestricted = Network(isOffline: { false }, isConstrained: { false }, isExpensive: { false },
                                          allowsExpensive: { true })
    }

    /// Loads the metadata an item needs before it can start. Replaceable so unit tests never touch AVFoundation's network.
    typealias AssetLoader = @MainActor (URL) async throws -> AVURLAsset

    private struct Job: Equatable {
        let track: Track
        let lane: Lane
    }

    private let resolver: (any PlaybackPreloadResolving)?
    let store: PlaybackPreloadStore
    private let loadAsset: AssetLoader
    private let enabled: Bool
    private let now: @MainActor () -> Date
    var network = Network.unrestricted {
        didSet { pump() }
    }
    private(set) var queueTracks: [Track] = []
    private(set) var browseTracks: [Track] = []
    private var browseOwner: String?
    private(set) var isHolding = false
    /// Playing intent for the queue lane; a paused or restored queue keeps its preparations but starts none.
    private(set) var isQueueAllowed = true
    /// A cancelled worker can finish after a newer job for the same song started; the token tells them apart.
    private var workers: [String: (token: UUID, job: Job, task: Task<Void, Never>)] = [:]
    private var lastGate: (block: String?, browse: Bool)?
    private var retryTask: Task<Void, Never>?
    private var cooldowns: [String: Date] = [:]
    private var skipped: [String: Date] = [:]
    /// Assets this preloader stored since launch; tests and the fixture UI read it.
    private(set) var preparedCount = 0
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Playback")

    /// Seeded UI runs and unit hosts keep preloading off unless a test injects a preloader explicitly.
    nonisolated static var isEnabledByDefault: Bool { PlaybackWarmer.isEnabledByDefault }

    static let nativeAssetLoader: AssetLoader = { url in
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: [HTTPCookie]()])
        do {
            let playable = try await PlaybackDeadline.run(seconds: loadTimeout) { () async throws -> Bool in
                let (playable, _, tracks) = try await asset.load(.isPlayable, .duration, .tracks)
                return playable && !tracks.isEmpty
            }
            guard playable else { throw PlaybackStreamError.invalidMedia }
        } catch {
            asset.cancelLoading()
            throw error
        }
        return asset
    }

    init(resolver: any StreamResolving, store: PlaybackPreloadStore = .shared,
         loadAsset: @escaping AssetLoader = PlaybackPreloader.nativeAssetLoader,
         enabled: Bool = PlaybackPreloader.isEnabledByDefault, now: @escaping @MainActor () -> Date = { Date() }) {
        self.resolver = resolver as? any PlaybackPreloadResolving
        self.store = store
        self.loadAsset = loadAsset
        self.enabled = enabled
        self.now = now
    }

    isolated deinit {
        retryTask?.cancel()
        workers.values.forEach { $0.task.cancel() }
    }

    var isAvailable: Bool { enabled && resolver != nil }
    var activeTrackIDs: Set<String> { Set(workers.keys) }

    /// The queue's upcoming songs in play order; the caller excludes the current song.
    func setQueue(_ tracks: [Track]) {
        let selected = Self.candidates(tracks, limit: Self.queueDepth)
        guard selected.map(\.id) != queueTracks.map(\.id) else { return }
        queueTracks = selected
        pump()
    }

    /// Replaces the browsing surface's candidates; `owner` names the page so leaving it clears only its own request.
    func setBrowse(_ tracks: [Track], owner: String) {
        browseOwner = owner
        // The limit applies after removing songs the queue already covers, so overlap never shrinks the surface.
        browseTracks = Self.candidates(tracks, limit: Self.browseLimit + Self.queueDepth)
        pump()
    }

    /// Re-plans only when connectivity or the cellular consent changed since the last plan.
    func refreshNetwork() {
        guard isAvailable else { return }
        let gate = (block: blockReason, browse: allowsBrowse)
        guard lastGate == nil || lastGate!.block != gate.block || lastGate!.browse != gate.browse else { return }
        pump()
    }

    private var allowsBrowse: Bool { !network.isExpensive() || network.allowsExpensive() }

    func cancelBrowse(owner: String? = nil) {
        if let owner, owner != browseOwner { return }
        guard browseOwner != nil || !browseTracks.isEmpty else { return }
        browseOwner = nil
        browseTracks = []
        pump()
    }

    /// While the selected song starts, new work in both lanes waits so it never competes with the listener's request.
    func setHolding(_ holding: Bool) {
        guard holding != isHolding else { return }
        isHolding = holding
        pump()
    }

    /// The player's single update: queue, playing intent and the starting hold are applied together before one plan,
    /// so a stale hold can never let new queue work start beside the song just selected.
    func update(queue tracks: [Track], queueAllowed: Bool, holding: Bool) {
        let selected = Self.candidates(tracks, limit: Self.queueDepth)
        guard selected.map(\.id) != queueTracks.map(\.id) || queueAllowed != isQueueAllowed || holding != isHolding else {
            refreshNetwork()
            return
        }
        queueTracks = selected
        isQueueAllowed = queueAllowed
        isHolding = holding
        pump()
    }

    /// Prepared assets for old signed URLs would never match again after a quality or extraction-rules change.
    func reset() {
        store.removeAll()
        skipped.removeAll()
        cooldowns.removeAll()
        workers.values.forEach { $0.task.cancel() }
        workers.removeAll()
        pump()
    }

    /// Stops all work and forgets requests; prepared assets stay until they expire or are evicted.
    func cancelAll() {
        queueTracks = []
        browseOwner = nil
        browseTracks = []
        retryTask?.cancel()
        retryTask = nil
        workers.values.forEach { $0.task.cancel() }
        workers.removeAll()
    }

    private static func candidates(_ tracks: [Track], limit: Int) -> [Track] {
        var seen = Set<String>()
        return Array(tracks.filter { $0.isAudioRecording != false && $0.source != .gaana && seen.insert($0.id).inserted }
            .prefix(limit))
    }

    private var blockReason: String? {
        if network.isOffline() { return "offline" }
        if network.isConstrained() { return "low_data" }
        return nil
    }

    /// Queue songs first in play order, then the browsing surface's.
    private func plannedJobs() -> [Job] {
        let current = now()
        cooldowns = cooldowns.filter { $0.value > current }
        skipped = skipped.filter { current.timeIntervalSince($0.value) < Self.skipLifetime }
        var jobs = isQueueAllowed ? queueTracks.map { Job(track: $0, lane: .queue) } : []
        if allowsBrowse {
            // Queue songs never repeat in the browse lane, even while the queue lane itself is paused.
            let queued = Set(queueTracks.map(\.id))
            jobs += browseTracks.filter { !queued.contains($0.id) }.prefix(Self.browseLimit).map { Job(track: $0, lane: .browse) }
        }
        return jobs.filter { skipped[$0.track.id] == nil && !store.hasUsableAsset(trackID: $0.track.id) }
    }

    private func pump() {
        guard isAvailable else { return }
        lastGate = (blockReason, allowsBrowse)
        if let reason = blockReason {
            if !workers.isEmpty { log.debug("event=playback_preload_skipped reason=\(reason, privacy: .public)") }
            workers.values.forEach { $0.task.cancel() }
            workers.removeAll()
            return
        }
        let jobs = plannedJobs()
        let wanted = Set(jobs.map(\.track.id))
        for (id, worker) in workers where !wanted.contains(id) {
            worker.task.cancel()
            workers.removeValue(forKey: id)
            log.debug("event=playback_preload outcome=cancelled lane=\(worker.job.lane.rawValue, privacy: .public)")
        }
        guard !isHolding else { return }
        for job in jobs where workers.count < Self.concurrency {
            let id = job.track.id
            guard workers[id] == nil, cooldowns[id] == nil else { continue }
            let token = UUID()
            workers[id] = (token, job, Task { @MainActor [weak self] in await self?.run(job, token: token) })
        }
    }

    private func run(_ job: Job, token: UUID) async {
        let id = job.track.id
        let started = ContinuousClock.now
        var outcome = "failed"
        var resolveMS = -1
        defer {
            if workers[id]?.token == token {
                workers.removeValue(forKey: id)
                let ms = Int(started.duration(to: .now) / .milliseconds(1))
                log.info("event=playback_preload outcome=\(outcome, privacy: .public) lane=\(job.lane.rawValue, privacy: .public) ms=\(ms) resolve_ms=\(resolveMS)")
                pump()
            }
        }
        guard let resolver else { return }
        do {
            let resolved = try await resolver.preloadStream(for: job.track)
            resolveMS = Int(started.duration(to: .now) / .milliseconds(1))
            guard let stream = resolved, !stream.url.isFileURL else {
                skipped[id] = now()
                outcome = "skipped"
                return
            }
            try Task.checkCancellation()
            let expiresAt = stream.expiresAt ?? PlaybackTiming.expiry(in: stream.url)
            if let expiresAt, expiresAt.timeIntervalSince(now()) < PlaybackPreloadStore.minimumRemainingLifetime {
                outcome = "expired"
                cooldowns[id] = now().addingTimeInterval(Self.failureCooldown)
                return
            }
            let asset = try await loadAsset(stream.url)
            guard !Task.isCancelled, workers[id]?.token == token else {
                asset.cancelLoading()
                outcome = "cancelled"
                return
            }
            store.store(PlaybackPreloadStore.Entry(trackID: id, url: stream.url, asset: asset, expiresAt: expiresAt))
            PlaybackStartTrace.markWarmed(id)
            preparedCount += 1
            outcome = "prepared"
        } catch is CancellationError {
            if Task.isCancelled { outcome = "cancelled"; return }
            // The resolver turns speculative work away while its background slots are full; try again shortly.
            outcome = "busy"
            cooldowns[id] = now().addingTimeInterval(Self.busyCooldown)
            scheduleRetry()
        } catch {
            cooldowns[id] = now().addingTimeInterval(Self.failureCooldown)
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.busyRetryDelay)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.pump()
        }
    }
}
