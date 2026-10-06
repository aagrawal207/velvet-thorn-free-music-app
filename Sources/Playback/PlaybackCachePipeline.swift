import Foundation

/// Downloads the current entry, then the next once requested; download failures never interrupt remote playback.
/// Resolvers without `StreamCaching` leave the pipeline inactive.
@MainActor
final class PlaybackCachePipeline {
    struct Target: Equatable {
        let track: Track
        let entryID: UUID
    }

    private let caching: (any StreamCaching)?
    private var task: Task<Void, Never>?
    private enum WorkState: Equatable { case idle, running, completed, incomplete, connectivityInterrupted, suppressed }
    private var workState = WorkState.idle
    private var workGeneration = UUID()
    private var retentionTask: Task<Void, Never>?
    private var current: Track?
    private var next: Target?
    /// The current song's copy already landed in this run; adding a next song later must not ask for it again.
    private var cachedCurrentID: String?
    /// The next target the running task is downloading; a different target restarts the task instead of waiting.
    private var downloadingNext: Target?
    private var deferredSync: (current: Track, next: Target?)?
    private var policyUpdates: Set<UUID> = []
    private var networkOffline = false
    private(set) var isClearingStorage = false
    var retainedTrackIDs: (@MainActor () -> Set<String>)?
    var onNextCached: (@MainActor (Target, ResolvedStream) -> Void)?
    var onCurrentCached: (@MainActor (Track, ResolvedStream) -> Void)?

    init(resolver: any StreamResolving) {
        caching = resolver as? any StreamCaching
    }

    var isAvailable: Bool { caching != nil }
    var canManageStorage: Bool { caching is any StreamCacheManaging }

    /// The resolver only knows its temporary directory; a file in the download tier is equally a complete local copy.
    func isCachedStream(_ stream: ResolvedStream) -> Bool {
        (caching?.isCachedStream(stream) ?? false) || (caching != nil && AudioCache.isDownloadedMediaURL(stream.url))
    }

    /// Reading the live owners inside one serial barrier prevents a delayed download from restoring stale pins.
    func retainPlaybackFiles() -> Task<Void, Never>? {
        guard let caching else { return nil }
        let previous = retentionTask
        let work = Task { @MainActor [weak self] in
            await previous?.value
            let fallback = Set([self?.current?.id, self?.next?.track.id].compactMap { $0 })
            let live = self?.retainedTrackIDs?() ?? fallback
            await caching.retainCached(live)
        }
        retentionTask = work
        return work
    }

    /// Idempotent for an unchanged (current, next) pair, including after both downloads finished.
    func sync(current: Track, next: Target?) {
        guard let caching, !networkOffline else { return }
        if isClearingStorage || !policyUpdates.isEmpty {
            deferredSync = policyUpdates.isEmpty && self.current?.id == current.id && self.next == next ? nil : (current, next)
            return
        }
        deferredSync = nil
        // Restarting would abandon the current song's transfer; the running task reads `next` when it gets there.
        // An obsolete next transfer is cancelled instead, since `cachedCurrentID` spares the current song.
        if self.current?.id == current.id, workState == .running, downloadingNext == nil || downloadingNext == next {
            self.next = next
            return
        }
        if self.current?.id == current.id, self.next == next,
           workState != .idle, workState != .connectivityInterrupted { return }
        task?.cancel()
        downloadingNext = nil
        let token = UUID()
        workGeneration = token
        workState = .running
        self.current = current
        self.next = next
        task = Task(priority: .utility) { @MainActor [weak self] in
            var complete = true
            defer {
                if self?.workGeneration == token {
                    self?.task = nil
                    self?.workState = complete ? .completed : .incomplete
                }
            }
            guard !Task.isCancelled else { return }
            await self?.retainPlaybackFiles()?.value
            guard !Task.isCancelled, self?.workGeneration == token else { return }
            // The song being heard comes first; the player adds `next` only once the listener has settled.
            if self?.cachedCurrentID != current.id {
                do {
                    let stream = try await caching.download(current)
                    guard !Task.isCancelled, let self, self.workGeneration == token else { return }
                    self.cachedCurrentID = current.id
                    self.onCurrentCached?(current, stream)
                } catch {
                    complete = false
                    guard !Task.isCancelled else { return }
                }
            }
            var downloaded: Target?
            while !Task.isCancelled, let self, self.workGeneration == token, let next = self.next, next != downloaded {
                self.downloadingNext = next
                defer { if self.workGeneration == token { self.downloadingNext = nil } }
                do {
                    let stream = try await caching.download(next.track)
                    guard !Task.isCancelled, self.workGeneration == token else { return }
                    self.onNextCached?(next, stream)
                } catch {
                    complete = false
                    return
                }
                downloaded = next
            }
        }
    }

    func cancel() {
        workGeneration = UUID()
        workState = .idle
        task?.cancel()
        task = nil
        cachedCurrentID = nil
        downloadingNext = nil
        current = nil
        next = nil
        deferredSync = nil
    }

    func storageUsage() async throws -> AudioCache.Usage? {
        try await (caching as? any StreamCacheManaging)?.audioCacheUsage()
    }

    func storageSnapshot() async throws -> AudioCacheSnapshot? {
        try await (caching as? any StreamCacheManaging)?.audioCacheSnapshot()
    }

    func updateListeningHistory(_ events: [ListeningEvent], now: Date) async {
        await (caching as? any StreamCacheManaging)?.updateCacheListeningHistory(events, now: now)
    }

    func setNetworkOffline(_ offline: Bool) {
        networkOffline = offline
        deferredSync = nil
        if offline {
            if workState == .running || workState == .incomplete { workState = .connectivityInterrupted }
            workGeneration = UUID()
            task?.cancel()
            task = nil
        }
    }

    func suspendForPolicyUpdate(_ token: UUID) {
        guard policyUpdates.insert(token).inserted else { return }
        cachedCurrentID = nil
        workGeneration = UUID()
        workState = .idle
        task?.cancel()
        task = nil
        if deferredSync == nil, let current { deferredSync = (current, next) }
    }

    func finishPolicyUpdate(_ token: UUID) {
        policyUpdates.remove(token)
        resumeDeferredSync()
    }

    func setAudioCacheLimit(_ limit: AudioCacheLimit,
                           retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        guard let managing = caching as? any StreamCacheManaging else { return nil }
        cachedCurrentID = nil
        await retainPlaybackFiles()?.value
        return try await managing.setAudioCacheLimit(limit, retaining: retaining)
    }

    func clearStorage(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        guard let managing = caching as? any StreamCacheManaging else { return nil }
        guard !isClearingStorage else { throw AudioCache.ManagementError.clearing }
        isClearingStorage = true
        workGeneration = UUID()
        workState = .suppressed
        cachedCurrentID = nil
        task?.cancel()
        task = nil
        defer {
            isClearingStorage = false
            resumeDeferredSync()
        }
        // Keeping the completed pair prevents a cancelled download from immediately repopulating the cache.
        return try await managing.clearAudioCache(retaining: retaining)
    }

    func removeCachedSong(id: String, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCacheRemoval? {
        guard let managing = caching as? any StreamCacheManaging else { return nil }
        guard !isClearingStorage else { throw AudioCache.ManagementError.clearing }
        isClearingStorage = true
        workGeneration = UUID()
        workState = .suppressed
        cachedCurrentID = nil
        task?.cancel()
        task = nil
        defer {
            isClearingStorage = false
            resumeDeferredSync()
        }
        return try await managing.removeCachedSong(id: id, retaining: retaining)
    }

    private func resumeDeferredSync() {
        guard !networkOffline, !isClearingStorage, policyUpdates.isEmpty, let deferredSync else { return }
        self.deferredSync = nil
        current = nil
        next = nil
        sync(current: deferredSync.current, next: deferredSync.next)
    }

    /// Removes a copy the player rejected; the caller re-resolves afterwards.
    func discard(_ track: Track, url: URL? = nil) async {
        if cachedCurrentID == track.id { cachedCurrentID = nil }
        await caching?.discardCached(track, url: url)
    }
}
