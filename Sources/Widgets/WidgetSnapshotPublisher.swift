import Foundation
import OSLog

@MainActor
final class WidgetSnapshotPublisher {
    typealias Thumbnail = @MainActor (Track) async -> Data?

    private struct Source {
        let metadata: WidgetLibrarySnapshot
        let thumbnailTracks: [Track]

        func matches(_ other: Self) -> Bool {
            metadata.hasSameContent(as: other.metadata) && thumbnailTracks == other.thumbnailTracks
        }
    }

    private let library: LibraryStore
    private let store: WidgetSnapshotStore
    private let reload: @MainActor () -> Void
    private let thumbnail: Thumbnail
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Widgets")
    private var source: Source?
    private var snapshot: WidgetLibrarySnapshot?
    private var published: WidgetLibrarySnapshot?
    private var publicationNeeded = true
    private var reloadPending = false
    private var isValidatingSource = false
    private var publishedBytes = 0
    private var generation = UUID()
    private var thumbnailTask: Task<Void, Never>?

    convenience init(library: LibraryStore, store: WidgetSnapshotStore, reload: @escaping @MainActor () -> Void) {
        self.init(library: library, store: store, thumbnail: { track in
            guard let url = track.artworkURL else { return nil }
            return await ArtworkLoader.shared.cachedThumbnail(for: url)
        }, reload: reload)
    }

    init(library: LibraryStore, store: WidgetSnapshotStore, thumbnail: @escaping Thumbnail,
         reload: @escaping @MainActor () -> Void) {
        self.library = library
        self.store = store
        self.thumbnail = thumbnail
        self.reload = reload
        library.onWidgetLibraryChange = { [weak self] in
            guard let self, !self.isValidatingSource else { return }
            self.update(refreshArtwork: false)
        }
        refresh()
    }

    isolated deinit { thumbnailTask?.cancel() }

    func refresh() {
        guard !isValidatingSource else { return }
        _ = validateSource()
        update(refreshArtwork: true)
    }

    private func validateSource() -> Bool {
        // This caller publishes after validation; its synchronous transition callback must not publish twice.
        isValidatingSource = true
        defer { isValidatingSource = false }
        return library.validateWidgetLibrarySource()
    }

    private func update(refreshArtwork: Bool) {
        let next = makeSource()
        let changed = source?.matches(next) != true
        if changed {
            let previous = snapshot ?? store.read()
            let retained = retainedArtwork(from: previous, for: next)
            generation = UUID()
            thumbnailTask?.cancel()
            thumbnailTask = nil
            source = next
            snapshot = next.metadata.withArtwork(retained)
            publicationNeeded = true
        }
        guard let snapshot else { return }
        let token = generation
        let retryingPublication = publicationNeeded
        if publicationNeeded || refreshArtwork {
            guard publish(snapshot) else { return }
        } else {
            record(snapshot, success: 0, unchanged: 1, failure: 0, bytes: publishedBytes)
        }
        guard token == generation, source?.matches(next) == true, snapshot.availability == .ready,
              changed || refreshArtwork || retryingPublication, thumbnailTask == nil else { return }
        let requests = next.thumbnailTracks.filter { snapshot.artwork[$0.id] == nil }
        guard !requests.isEmpty else { return }
        let thumbnail = self.thumbnail
        thumbnailTask = Task { @MainActor [weak self] in
            var artwork = snapshot.artwork
            var bytes = artwork.values.reduce(0) { $0 + $1.count }
            for track in requests {
                guard !Task.isCancelled, self?.isCurrent(next, token: token) == true else { return }
                let data = await thumbnail(track)
                guard !Task.isCancelled, self?.isCurrent(next, token: token) == true else { return }
                if let data, WidgetLibrarySnapshot.isValidArtwork(data),
                   data.count <= WidgetLibrarySnapshot.maximumTotalArtworkBytes - bytes {
                    artwork[track.id] = data
                    bytes += data.count
                }
            }
            guard let self, !Task.isCancelled, self.isCurrent(next, token: token) else { return }
            self.thumbnailTask = nil
            // Disk can change while a cache reader is suspended without producing a library callback.
            guard self.validateSource(), self.isCurrent(next, token: token), next.matches(self.makeSource()) else {
                self.update(refreshArtwork: false)
                return
            }
            var enriched = snapshot.withArtwork(artwork)
            enriched.updatedAt = Date()
            self.snapshot = enriched
            if self.published?.hasSameContent(as: enriched) != true {
                self.publicationNeeded = true
                _ = self.publish(enriched)
            } else {
                self.record(enriched, success: 0, unchanged: 1, failure: 0, bytes: self.publishedBytes)
            }
        }
    }

    private func makeSource() -> Source {
        guard library.widgetLibrarySourceIsAvailable, library.hasLoadedDocument, !library.requiresReload else {
            return Source(metadata: WidgetLibrarySnapshot(availability: .unavailable, historyEnabled: false), thumbnailTracks: [])
        }
        let history = library.preferences.saveListeningHistory
        let recent = history ? library.recentlyPlayed.map(\.track) : []
        let metadata = WidgetLibrarySnapshot.projection(recentlyPlayed: recent, likedSongs: library.favorites,
                                                       mixes: library.mixes, historyEnabled: history, accent: library.preferences.accent)
        let displayed = metadata.displayedTracks
        var urls: [String: URL] = [:]
        var lists = [(recent, metadata.recentlyPlayed), (library.favorites, metadata.likedSongs)]
        for projected in metadata.mixes {
            if let saved = library.mixes.first(where: { $0.kind == projected.kind && $0.periodKey == projected.periodKey }) {
                lists.append((saved.tracks, projected.tracks))
            }
        }
        for (tracks, rows) in lists {
            var remaining = Set(rows.map(\.id))
            for track in tracks {
                guard !remaining.isEmpty else { break }
                guard remaining.remove(track.id) != nil, urls[track.id] == nil,
                      let url = track.artworkURL, url.absoluteString.utf8.prefix(2049).count <= 2048,
                      url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
                      url.user == nil, url.password == nil else { continue }
                urls[track.id] = url
            }
        }
        let thumbnails = displayed.compactMap { track -> Track? in
            guard let url = urls[track.id] else { return nil }
            var request = track
            request.artworkURL = url
            return request
        }
        return Source(metadata: metadata, thumbnailTracks: thumbnails)
    }

    private func retainedArtwork(from previous: WidgetLibrarySnapshot, for next: Source) -> [String: Data] {
        let previousTracks = Dictionary(uniqueKeysWithValues: previous.displayedTracks.map { ($0.id, $0) })
        let previousURLs = source.map { value in
            Dictionary(uniqueKeysWithValues: value.thumbnailTracks.compactMap { track in track.artworkURL.map { (track.id, $0) } })
        }
        let nextURLs = Dictionary(uniqueKeysWithValues: next.thumbnailTracks.compactMap { track in track.artworkURL.map { (track.id, $0) } })
        return next.metadata.displayedTracks.reduce(into: [:]) { artwork, track in
            guard previousTracks[track.id] == track,
                  previousURLs == nil || previousURLs?[track.id] == nextURLs[track.id],
                  let data = previous.artwork[track.id] else { return }
            artwork[track.id] = data
        }
    }

    private func isCurrent(_ expected: Source, token: UUID) -> Bool {
        token == generation && source?.matches(expected) == true
    }

    private func publish(_ snapshot: WidgetLibrarySnapshot) -> Bool {
        do {
            let changed = try store.write(snapshot)
            let shouldReload = changed || reloadPending
            published = snapshot
            publicationNeeded = false
            reloadPending = false
            if var file = store.fileURL {
                file.removeAllCachedResourceValues()
                publishedBytes = min(WidgetSnapshotStore.maximumFileBytes, max(0, (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            } else {
                publishedBytes = 0
            }
            record(snapshot, success: shouldReload ? 1 : 0, unchanged: shouldReload ? 0 : 1, failure: 0, bytes: publishedBytes)
            if shouldReload { reload() }
            return true
        } catch {
            publicationNeeded = true
            // Atomic replacement can succeed before file metadata fails, so an identical retry still owes a reload.
            reloadPending = true
            record(snapshot, success: 0, unchanged: 0, failure: 1, bytes: 0, storageUnavailable: true)
            return false
        }
    }

    private func record(_ snapshot: WidgetLibrarySnapshot, success: Int, unchanged: Int, failure: Int,
                        bytes: Int, storageUnavailable: Bool = false) {
        let unavailable = storageUnavailable || snapshot.availability != .ready ? 1 : 0
        log.info("event=widget_snapshot success=\(success) unchanged=\(unchanged) failure=\(failure) unavailable=\(unavailable) recent=\(snapshot.recentlyPlayed.count) liked=\(snapshot.likedSongs.count) mixes=\(snapshot.mixes.count) artwork=\(snapshot.artwork.count) bytes=\(bytes)")
    }
}
