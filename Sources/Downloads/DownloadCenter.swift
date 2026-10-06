import Foundation
import Observation
import OSLog

/// Main-actor face of `DownloadManager` for views: queue state, derived collection state and the tier calls.
/// `isAvailable` is false when the playback provider has no local audio store; the UI then hides download rows.
@MainActor @Observable
final class DownloadCenter {
    private(set) var items: [DownloadItem] = []
    private(set) var queueError: String?
    /// Songs whose promotion finished before the inventory refresh confirmed them.
    private(set) var recentlyDownloadedIDs: Set<String> = []
    @ObservationIgnored let manager: DownloadManager?
    @ObservationIgnored var onTierChange: (@MainActor (_ trackID: String, _ downloaded: Bool) -> Void)?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Downloads")

    init(manager: DownloadManager?) {
        self.manager = manager
        guard let manager else { return }
        let box = WeakCenter(center: self)
        Task {
            await manager.setObservers(onChange: { items in
                Task { @MainActor in box.center?.items = items }
            }, onTierChange: { trackID, downloaded in
                Task { @MainActor in box.center?.tierChanged(trackID, downloaded: downloaded) }
            }, onQueueError: { error in
                Task { @MainActor in box.center?.queueError = error }
            })
        }
    }

    /// The manager outlives no center, but its callbacks must not keep the center alive either.
    private struct WeakCenter: Sendable {
        weak var center: DownloadCenter?
    }

    static let unavailable = DownloadCenter(manager: nil)

    var isAvailable: Bool { manager != nil }
    var pendingItems: [DownloadItem] { items.filter { $0.state.isPending } }
    var failedItems: [DownloadItem] { items.filter { if case .failed = $0.state { return true } else { return false } } }
    var hasActivity: Bool { !items.isEmpty }

    func state(for trackID: String) -> DownloadState? {
        items.first { $0.id == trackID }?.state
    }

    func statusTitle(for trackID: String) -> String? { items.first { $0.id == trackID }?.statusTitle }

    func waitingReason(for trackID: String) -> DownloadWaitingReason? { items.first { $0.id == trackID }?.waitingReason }

    func setForeground(_ active: Bool) {
        guard let manager else { return }
        Task { await manager.setForeground(active) }
    }

    func isQueued(_ trackID: String) -> Bool {
        state(for: trackID)?.isPending == true
    }

    /// Downloaded, then queued/downloading, then plain: one label for menus and collection buttons.
    func collectionState(for tracks: [Track], downloadedIDs: Set<String>) -> CollectionDownloadState {
        let ids = Array(Set(tracks.map(\.id)))
        guard !ids.isEmpty else { return .none }
        let downloaded = ids.filter { downloadedIDs.contains($0) || recentlyDownloadedIDs.contains($0) }.count
        if downloaded == ids.count { return .downloaded }
        let pending = ids.filter { isQueued($0) }.count
        return pending > 0 ? .downloading(done: downloaded, total: ids.count) : .none
    }

    func download(_ tracks: [Track]) {
        guard let manager else { return }
        let wanted = tracks.filter { !recentlyDownloadedIDs.contains($0.id) }
        guard !wanted.isEmpty else { return }
        Task {
            await restoreTask?.value
            await manager.enqueue(wanted)
        }
    }

    func cancel(_ trackID: String) {
        guard let manager else { return }
        Task { await manager.cancel(trackID) }
    }

    func cancelAll() {
        guard let manager else { return }
        Task { await manager.cancelAll() }
    }

    func retry(_ trackID: String) {
        guard let manager else { return }
        Task { await manager.retry(trackID) }
    }

    func setAllowCellular(_ allowed: Bool) {
        guard let manager else { return }
        Task { await manager.setAllowCellular(allowed) }
    }

    func connectivityChanged() {
        guard let manager else { return }
        Task { await manager.connectivityChanged() }
    }

    func restoreQueue(resolvingTracks lookup: @escaping DownloadManager.TrackLookup) {
        guard let manager, restoreTask == nil else { return }
        restoreTask = Task { [weak self] in
            await manager.restore(resolvingTracks: lookup)
            self?.restoreTask = nil
        }
    }

    func removeDownload(_ trackID: String) async throws -> AudioCache.DownloadTierChange? {
        guard let manager else { return nil }
        recentlyDownloadedIDs.remove(trackID)
        return try await manager.removeDownload(trackID)
    }

    func deleteDownload(_ trackID: String) async throws -> AudioCache.DownloadDeletion? {
        guard let manager else { return nil }
        recentlyDownloadedIDs.remove(trackID)
        return try await manager.deleteDownload(trackID)
    }

    func localCopy(for trackID: String) async -> CachedAudio? {
        await manager?.localCopy(for: trackID)
    }

    func withLocalCopy<Result: Sendable>(for trackID: String,
                                        operation: @Sendable (CachedAudio) async throws -> Result) async throws -> Result? {
        try Task.checkCancellation()
        guard let manager else { return nil }
        return try await manager.withLocalCopy(for: trackID, operation: operation)
    }

    /// Called once the inventory has been re-read; confirmed IDs no longer need the interim set.
    func inventoryRefreshed(downloadedIDs: Set<String>) {
        recentlyDownloadedIDs.subtract(downloadedIDs)
    }

    private func tierChanged(_ trackID: String, downloaded: Bool) {
        if downloaded { recentlyDownloadedIDs.insert(trackID) } else { recentlyDownloadedIDs.remove(trackID) }
        onTierChange?(trackID, downloaded)
    }
}
