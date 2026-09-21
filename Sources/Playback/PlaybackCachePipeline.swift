import Foundation

/// Downloads the next entry before the current one; download failures never interrupt remote playback.
/// Resolvers without `StreamCaching` leave the pipeline inactive.
@MainActor
final class PlaybackCachePipeline {
    struct Target: Equatable {
        let track: Track
        let entryID: UUID
    }

    private let caching: (any StreamCaching)?
    private var task: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    private var current: Track?
    private var next: Target?
    private var deferredSync: (current: Track, next: Target?)?
    private var policyUpdates: Set<UUID> = []
    private(set) var isClearingStorage = false
    var retainedTrackIDs: (@MainActor () -> Set<String>)?
    var onNextCached: (@MainActor (Target, ResolvedStream) -> Void)?
    var onCurrentCached: (@MainActor (Track, ResolvedStream) -> Void)?

    init(resolver: any StreamResolving) {
        caching = resolver as? any StreamCaching
    }

    var isAvailable: Bool { caching != nil }
    var canManageStorage: Bool { caching is any StreamCacheManaging }

    func isCachedStream(_ stream: ResolvedStream) -> Bool { caching?.isCachedStream(stream) ?? false }

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
        guard let caching else { return }
        if isClearingStorage || !policyUpdates.isEmpty {
            deferredSync = policyUpdates.isEmpty && self.current?.id == current.id && self.next == next ? nil : (current, next)
            return
        }
        if self.current?.id == current.id, self.next == next { return }
        task?.cancel()
        self.current = current
        self.next = next
        task = Task(priority: .utility) { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await self?.retainPlaybackFiles()?.value
            guard !Task.isCancelled else { return }
            if let next {
                do {
                    let stream = try await caching.download(next.track)
                    guard !Task.isCancelled, let self else { return }
                    self.onNextCached?(next, stream)
                } catch {
                    guard !Task.isCancelled else { return }
                }
            }
            do {
                let stream = try await caching.download(current)
                guard !Task.isCancelled, let self else { return }
                self.onCurrentCached?(current, stream)
            } catch { }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        current = nil
        next = nil
        deferredSync = nil
    }

    func storageUsage() async throws -> AudioCache.Usage? {
        try await (caching as? any StreamCacheManaging)?.audioCacheUsage()
    }

    func suspendForPolicyUpdate(_ token: UUID) {
        guard policyUpdates.insert(token).inserted else { return }
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
        await retainPlaybackFiles()?.value
        return try await managing.setAudioCacheLimit(limit, retaining: retaining)
    }

    func clearStorage(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        guard let managing = caching as? any StreamCacheManaging else { return nil }
        guard !isClearingStorage else { throw AudioCache.ManagementError.clearing }
        isClearingStorage = true
        task?.cancel()
        task = nil
        defer {
            isClearingStorage = false
            resumeDeferredSync()
        }
        // Keeping the completed pair prevents a cancelled download from immediately repopulating the cache.
        return try await managing.clearAudioCache(retaining: retaining)
    }

    private func resumeDeferredSync() {
        guard !isClearingStorage, policyUpdates.isEmpty, let deferredSync else { return }
        self.deferredSync = nil
        current = nil
        next = nil
        sync(current: deferredSync.current, next: deferredSync.next)
    }

    /// Removes a copy the player rejected; the caller re-resolves afterwards.
    func discard(_ track: Track, url: URL? = nil) async {
        await caching?.discardCached(track, url: url)
    }
}
