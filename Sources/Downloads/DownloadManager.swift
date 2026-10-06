import Foundation
import OSLog

/// Tier operations the manager needs from the audio store; `AudioCache` is the production implementation.
protocol DownloadTierStore: Sendable {
    func hasCompleteCopy(of trackID: String, allowOpus: Bool) async -> Bool
    func promoteToDownloads(_ trackID: String) async throws -> AudioCache.DownloadTierChange
    func demoteToCache(_ trackID: String) async throws -> AudioCache.DownloadTierChange
    func deleteDownload(_ trackID: String) async throws -> AudioCache.DownloadDeletion
    func isDownloaded(_ trackID: String) async -> Bool
    func entry(for trackID: String, allowOpus: Bool) async -> CachedAudio?
    func withLocalCopy<Result: Sendable>(for trackID: String, allowOpus: Bool,
                                        operation: @Sendable (CachedAudio) async throws -> Result) async throws -> Result?
    nonisolated func transferProgress(for trackID: String) -> Double?
    /// Waits, at most `seconds`, for a cache copy of `trackID` that is already being written, and reports whether a
    /// complete copy exists afterwards. False at once when nothing is writing it.
    func waitForCopyInProgress(of trackID: String, allowOpus: Bool, seconds: TimeInterval) async -> Bool
}

extension DownloadTierStore {
    func waitForCopyInProgress(of trackID: String, allowOpus: Bool, seconds: TimeInterval) async -> Bool { false }
}

extension AudioCache: DownloadTierStore { }

protocol DownloadConnectivity: Sendable {
    var isOffline: Bool { get }
    var isExpensivePath: Bool { get }
}

/// Whole-song queue with an OS background backend for production and a foreground transfer boundary for fixtures.
actor DownloadManager {
    typealias Transfer = @Sendable (Track) async throws -> ResolvedStream
    typealias TrackLookup = @Sendable ([String]) async throws -> [Track]

    struct Configuration: Sendable {
        var maximumConcurrent = 2
        var maximumAttempts = 3
        var backoff: [Duration] = [.seconds(2), .seconds(6)]
        var progressInterval: Duration = .milliseconds(400)
        var allowOpus = OpusNativeAudio.isSupported
    }

    static let defaultQueueFile = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory).appendingPathComponent("GanaBajana", isDirectory: true)
        .appendingPathComponent("downloads-queue.json", isDirectory: false)

    private let store: any DownloadTierStore
    private let transfer: Transfer
    private let background: BackgroundDownloadEngine?
    private let connectivity: any DownloadConnectivity
    private let queueFile: URL?
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private(set) var items: [DownloadItem] = []
    private(set) var allowCellular = false
    private(set) var queueError: String?
    private var attempts: [String: Int] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var pollers: [String: Task<Void, Never>] = [:]
    /// Items held back by connectivity gating; they are re-dispatched only when the path or the rule changes.
    private var parked: Set<String> = []
    private var onChange: (@Sendable ([DownloadItem]) -> Void)?
    private var onTierChange: (@Sendable (String, Bool) -> Void)?
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Downloads")

    init(store: any DownloadTierStore, transfer: @escaping Transfer, connectivity: any DownloadConnectivity,
         queueFile: URL? = DownloadManager.defaultQueueFile, configuration: Configuration = Configuration(),
         now: @escaping @Sendable () -> Date = { Date() }, background: BackgroundDownloadEngine? = nil) {
        self.store = store
        self.transfer = transfer
        self.connectivity = connectivity
        self.queueFile = queueFile
        self.configuration = configuration
        self.now = now
        self.background = background
    }

    static func background(store: AudioCache, planner: @escaping BackgroundDownloadEngine.Planner,
                           connectivity: any DownloadConnectivity, allowCellular: Bool,
                           queueFile: URL = defaultQueueFile) -> DownloadManager {
        let staging = BackgroundDownloadStaging(directory: queueFile.deletingLastPathComponent()
            .appendingPathComponent("DownloadStaging", isDirectory: true))
        let session = SystemBackgroundDownloadSession(staging: staging)
        let engine = BackgroundDownloadEngine(store: store, planner: planner, publication: { track, part, metadata, fence in
            try await store.publishBackgroundDownload(track: track, part: part, metadata: metadata, fence: fence)
        }, promotion: { id, fence in
            try await store.promoteToDownloads(id, fence: fence)
        }, session: session, staging: staging, queueFile: queueFile, connectivity: connectivity, allowCellular: allowCellular)
        return DownloadManager(store: store, transfer: { _ in throw PlaybackStreamError.noAudio }, connectivity: connectivity,
                               queueFile: queueFile, background: engine)
    }

    var activeCount: Int { background == nil ? running.count : items.filter { $0.state.isDownloading }.count }

    func setObservers(onChange: @escaping @Sendable ([DownloadItem]) -> Void,
                      onTierChange: @escaping @Sendable (_ trackID: String, _ downloaded: Bool) -> Void,
                      onQueueError: @escaping @Sendable (String?) -> Void = { _ in }) async {
        self.onChange = onChange
        self.onTierChange = onTierChange
        onChange(items)
        if let background {
            await background.setObservers(onChange: { [weak self] items in await self?.acceptBackgroundItems(items) },
                                          onTierChange: { id, downloaded in onTierChange(id, downloaded) },
                                          onStorageError: { [weak self] failed in
                let message = failed ? "The download queue could not be saved or restored. Retry after storage is available." : nil
                await self?.acceptQueueError(message)
                onQueueError(message)
            })
        }
    }

    private func acceptBackgroundItems(_ items: [DownloadItem]) { self.items = items; publish() }
    private func acceptQueueError(_ error: String?) { queueError = error }

    func setForeground(_ active: Bool) async { await background?.setForeground(active) }

    func setAllowCellular(_ allowed: Bool) async {
        if let background { allowCellular = allowed; await background.setAllowCellular(allowed); return }
        guard allowed != allowCellular else { return }
        allowCellular = allowed
        releaseParked()
    }

    /// Re-evaluates gating after a path change; a lost connection pauses waiting items without failing them.
    func connectivityChanged() async {
        if let background { await background.connectivityChanged(); return }
        releaseParked()
    }

    private func releaseParked() {
        parked.removeAll()
        for index in items.indices where items[index].state == .waitingForWiFi { items[index].state = .queued }
        publish()
        pump()
    }

    /// Restores the persisted queue; IDs that no longer resolve to library metadata are dropped and logged.
    func restore(resolvingTracks lookup: TrackLookup) async {
        if let background { await background.restore(resolvingTracks: lookup); return }
        guard let queueFile, let record = DownloadQueueRecord.load(from: queueFile), !record.trackIDs.isEmpty else { return }
        let known = Set(items.map(\.id))
        let wanted = record.trackIDs.filter { !known.contains($0) }
        guard let tracks = try? await lookup(wanted) else { return }
        let resolved = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = wanted.compactMap { resolved[$0] }
        log.info("event=download_queue_restored count=\(ordered.count) dropped=\(wanted.count - ordered.count)")
        _ = await enqueue(ordered)
    }

    /// Adds tracks in order, skipping duplicates, invalid IDs and songs already in the download tier. Returns the number added.
    @discardableResult
    func enqueue(_ tracks: [Track]) async -> Int {
        if let background { return await background.enqueue(tracks) }
        var added = 0
        for track in tracks where AudioCache.isProviderTrackID(track.id) {
            if let index = items.firstIndex(where: { $0.id == track.id }) {
                if case .failed = items[index].state {
                    items[index].state = .queued
                    attempts[track.id] = 0
                    added += 1
                }
                continue
            }
            items.append(DownloadItem(track: track, enqueuedAt: now()))
            added += 1
        }
        if added > 0 {
            log.info("event=download_enqueued count=\(added) queued=\(self.items.filter { $0.state.isPending }.count)")
            persist()
            publish()
            pump()
        }
        return added
    }

    func retry(_ trackID: String) async {
        if let background { await background.retry(trackID); return }
        guard let index = items.firstIndex(where: { $0.id == trackID }), case .failed = items[index].state else { return }
        items[index].state = .queued
        attempts[trackID] = 0
        parked.remove(trackID)
        persist()
        publish()
        pump()
    }

    func cancel(_ trackID: String) async {
        if let background { _ = await background.cancel(trackID); return }
        guard let index = items.firstIndex(where: { $0.id == trackID }) else { return }
        let wasRunning = running[trackID] != nil
        running.removeValue(forKey: trackID)?.cancel()
        pollers.removeValue(forKey: trackID)?.cancel()
        items.remove(at: index)
        attempts.removeValue(forKey: trackID)
        parked.remove(trackID)
        log.info("event=download outcome=cancelled active=\(wasRunning ? 1 : 0)")
        persist()
        publish()
        pump()
    }

    func cancelAll() async {
        if let background { await background.cancelAll(); return }
        let count = items.count
        running.values.forEach { $0.cancel() }
        pollers.values.forEach { $0.cancel() }
        running.removeAll()
        pollers.removeAll()
        items.removeAll()
        attempts.removeAll()
        parked.removeAll()
        log.info("event=download_cancel_all count=\(count)")
        persist()
        publish()
    }

    func clearFailed() async {
        if let background { await background.clearFailed(); return }
        items.removeAll { if case .failed = $0.state { return true } else { return false } }
        publish()
    }

    /// Moves the song back to the temporary tier; it stays playable until the cache evicts it.
    func removeDownload(_ trackID: String) async throws -> AudioCache.DownloadTierChange {
        if let background {
            guard await background.cancel(trackID) else { throw BackgroundDownloadFailure.staging }
        } else if items.contains(where: { $0.id == trackID }) { await cancel(trackID) }
        let change = try await store.demoteToCache(trackID)
        onTierChange?(trackID, false)
        return change
    }

    func deleteDownload(_ trackID: String) async throws -> AudioCache.DownloadDeletion {
        if let background {
            guard await background.cancel(trackID) else { throw BackgroundDownloadFailure.staging }
        } else if items.contains(where: { $0.id == trackID }) { await cancel(trackID) }
        let deletion = try await store.deleteDownload(trackID)
        onTierChange?(trackID, false)
        return deletion
    }

    func isDownloaded(_ trackID: String) async -> Bool {
        await store.isDownloaded(trackID)
    }

    func localCopy(for trackID: String) async -> CachedAudio? {
        await store.entry(for: trackID, allowOpus: configuration.allowOpus)
    }

    func withLocalCopy<Result: Sendable>(for trackID: String,
                                        operation: @Sendable (CachedAudio) async throws -> Result) async throws -> Result? {
        try await store.withLocalCopy(for: trackID, allowOpus: configuration.allowOpus, operation: operation)
    }

    // MARK: - Dispatch

    private enum Step { case finished, parked, retryAfter(Duration) }

    private func pump() {
        guard running.count < configuration.maximumConcurrent else { return }
        for item in items where item.state == .queued && running[item.id] == nil && !parked.contains(item.id) {
            guard running.count < configuration.maximumConcurrent else { return }
            let id = item.id
            running[id] = Task { [weak self] in
                await self?.run(id)
            }
        }
    }

    private func run(_ trackID: String) async {
        defer {
            running.removeValue(forKey: trackID)
            pollers.removeValue(forKey: trackID)?.cancel()
            pump()
        }
        while !Task.isCancelled {
            guard let track = items.first(where: { $0.id == trackID })?.track else { return }
            switch await attempt(track) {
            case .finished:
                return
            case .parked:
                parked.insert(trackID)
                return
            case .retryAfter(let delay):
                do { try await Task.sleep(for: delay) } catch { return }
                guard items.first(where: { $0.id == trackID })?.state == .queued else { return }
            }
        }
    }

    private func attempt(_ track: Track) async -> Step {
        let trackID = track.id
        // A complete cached copy is renamed into place; that needs no network and ignores the cellular rule.
        if await store.hasCompleteCopy(of: trackID, allowOpus: configuration.allowOpus) {
            return await promote(trackID)
        }
        guard !Task.isCancelled, items.contains(where: { $0.id == trackID }) else { return .finished }
        if connectivity.isOffline {
            update(trackID, to: .queued)
            return .parked
        }
        if connectivity.isExpensivePath, !allowCellular {
            update(trackID, to: .waitingForWiFi)
            log.info("event=download outcome=skippedCellular")
            return .parked
        }
        update(trackID, to: .downloading(fraction: 0))
        startPoller(trackID)
        defer { pollers.removeValue(forKey: trackID)?.cancel() }
        do {
            _ = try await transfer(track)
            guard !Task.isCancelled, items.contains(where: { $0.id == trackID }) else { return .finished }
            return await promote(trackID)
        } catch is CancellationError {
            // The resolver cancels transfers during cache maintenance; without our own cancellation that is a retry.
            guard !Task.isCancelled, items.contains(where: { $0.id == trackID }) else { return .finished }
            return failAttempt(trackID, reason: "The download was interrupted.")
        } catch {
            guard !Task.isCancelled, items.contains(where: { $0.id == trackID }) else { return .finished }
            if connectivity.isOffline {
                update(trackID, to: .queued)
                return .parked
            }
            return failAttempt(trackID, reason: error.localizedDescription)
        }
    }

    /// Counts one failed attempt: backs off while attempts remain, otherwise the item stays visible as failed.
    private func failAttempt(_ trackID: String, reason: String) -> Step {
        let attempt = (attempts[trackID] ?? 0) + 1
        attempts[trackID] = attempt
        guard attempt < configuration.maximumAttempts else {
            attempts.removeValue(forKey: trackID)
            update(trackID, to: .failed(reason: reason))
            log.notice("event=download outcome=failed attempts=\(attempt)")
            persist()
            return .finished
        }
        log.notice("event=download_retry attempt=\(attempt)")
        update(trackID, to: .queued)
        return .retryAfter(configuration.backoff[min(attempt - 1, configuration.backoff.count - 1)])
    }

    private func promote(_ trackID: String) async -> Step {
        do {
            let change = try await store.promoteToDownloads(trackID)
            guard items.contains(where: { $0.id == trackID }) else { return .finished }
            switch change {
            case .moved(let bytes), .alreadyThere(let bytes):
                items.removeAll { $0.id == trackID }
                attempts.removeValue(forKey: trackID)
                log.info("event=download outcome=ok bytes=\(bytes)")
                persist()
                publish()
                onTierChange?(trackID, true)
                return .finished
            case .notFound:
                // The transfer reported success but nothing complete is on disk; treat it like a failed attempt.
                return failAttempt(trackID, reason: "The downloaded file could not be verified.")
            }
        } catch {
            guard items.contains(where: { $0.id == trackID }) else { return .finished }
            log.notice("event=download_promotion_deferred")
            return failAttempt(trackID, reason: error.localizedDescription)
        }
    }

    private func startPoller(_ trackID: String) {
        pollers[trackID]?.cancel()
        let interval = configuration.progressInterval
        let store = self.store
        pollers[trackID] = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                if let fraction = store.transferProgress(for: trackID) {
                    await self.reportProgress(trackID, fraction: fraction)
                }
            }
        }
    }

    private func reportProgress(_ trackID: String, fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == trackID }), items[index].state.isDownloading else { return }
        items[index].state = .downloading(fraction: fraction)
        publish()
    }

    private func update(_ trackID: String, to state: DownloadState) {
        guard let index = items.firstIndex(where: { $0.id == trackID }), items[index].state != state else { return }
        items[index].state = state
        publish()
    }

    private func publish() {
        onChange?(items)
    }

    /// Pending items only; failed ones are the listener's decision to retry, so a relaunch does not replay them.
    private func persist() {
        guard let queueFile else { return }
        let record = DownloadQueueRecord(trackIDs: items.filter { $0.state.isPending }.map(\.id))
        do {
            if record.trackIDs.isEmpty {
                if FileManager.default.fileExists(atPath: queueFile.path) { try FileManager.default.removeItem(at: queueFile) }
            } else {
                try record.save(to: queueFile)
            }
        } catch {
            log.error("event=download_queue_persist_failed")
        }
    }
}
