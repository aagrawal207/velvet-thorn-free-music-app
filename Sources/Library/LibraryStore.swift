import Foundation
import Observation
import OSLog

@MainActor @Observable
final class LibraryStore {
    @ObservationIgnored private var document = LibraryDocument()
    private(set) var historyRevision: UInt64 = 0
    private(set) var lifetimeListeningRevision: UInt64 = 0
    private var historyEpochRevision: UInt64 = 0
    private(set) var recordingLanguageOverridesRevision: UInt64 = 0
    private var favoritesRevision: UInt64 = 0
    private var playlistsRevision: UInt64 = 0
    private var preferencesRevision: UInt64 = 0
    private var playbackRevision: UInt64 = 0
    private var recentsRevision: UInt64 = 0
    private var searchesRevision: UInt64 = 0
    private var searchSelectionsRevision: UInt64 = 0
    private var searchResetRevision: UInt64 = 0
    private var followsRevision: UInt64 = 0
    private var releasesRevision: UInt64 = 0
    private var mixesRevision: UInt64 = 0
    private var dislikesRevision: UInt64 = 0
    private var tipsRevision: UInt64 = 0
    private var lyricsOffsetsRevision: UInt64 = 0
    private var pendingNotificationsRevision: UInt64 = 0
    @ObservationIgnored private var favoriteIDs: Set<String> = []
    @ObservationIgnored private var superLikedIDSet: Set<String> = []
    @ObservationIgnored private var dislikedIDs: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Library")
    @ObservationIgnored private(set) var durableCommitCount: UInt64 = 0
    private(set) var errorMessage: String?
    private(set) var storageBytes: Int64 = 0
    /// A successful load includes a new empty library; failed reloads do not erase an established document.
    private(set) var hasLoadedDocument = false

    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var persistedData: Data?
    // Proves `persistedData` is still on disk without reading it; nil forces the next fence to compare bytes.
    @ObservationIgnored private var persistedStamp: LibraryFileStamp?
    @ObservationIgnored private(set) var contentFenceReadCount: UInt64 = 0
    @ObservationIgnored private(set) var lastPersistFence: LibraryPersistence.Fence?
    private var storageIsBlocked = false
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let syncWriterID: UUID
    @ObservationIgnored private var lifetimeSummary = LifetimeListeningSummary()
    @ObservationIgnored private var hasFutureLifetimeReceipts = false
    @ObservationIgnored private let projectSyncValues: LibrarySyncValueProjection
    @ObservationIgnored private var syncPreparationGeneration = UUID()
    @ObservationIgnored private var checkpointDocumentGeneration = UUID()
    @ObservationIgnored private var checkpointPrivacyGeneration = UUID()
    @ObservationIgnored private var checkpointContextGeneration = UUID()
    @ObservationIgnored private var checkpointPreparationIsRunning = false
    @ObservationIgnored private let beforeListeningCheckpointPreparation: @Sendable () async throws -> Void
    @ObservationIgnored private(set) var lastListeningCheckpointMetrics: LibraryListeningCheckpointMetrics?
    @ObservationIgnored private(set) var listeningCheckpointMainActorMilliseconds: Double = 0
    @ObservationIgnored var onHistoryCleared: (@MainActor () -> Void)?
    @ObservationIgnored var onCloudSyncApplied: (@MainActor (_ previous: UserPreferences, _ recommendationsChanged: Bool) -> Void)?
    @ObservationIgnored var onSyncChange: (@MainActor () -> Void)?
    @ObservationIgnored var onWidgetLibraryChange: (@MainActor () -> Void)?
    @ObservationIgnored private(set) var widgetLibrarySourceIsAvailable = false

    var syncDeviceConfigurationURL: URL? {
        fileURL?.deletingLastPathComponent().appendingPathComponent("LibrarySyncDevice/device.json")
    }

    var favorites: [Track] { _ = favoritesRevision; return document.favorites }
    /// Super liked songs in Liked Songs order; every one of them is also in `favorites`.
    var superLikes: [Track] { _ = favoritesRevision; return document.favorites.filter { superLikedIDSet.contains($0.id) } }
    var superLikedIDs: Set<String> { _ = favoritesRevision; return superLikedIDSet }
    var playlists: [UserPlaylist] { _ = playlistsRevision; return document.playlists }
    var events: [ListeningEvent] { _ = historyRevision; return document.events }
    var lifetimeListeningSummary: LifetimeListeningSummary {
        _ = lifetimeListeningRevision
        return hasFutureLifetimeReceipts ? document.lifetimeListening.summary(through: now()) : lifetimeSummary
    }
    var listeningHistoryEpoch: UUID? { _ = historyEpochRevision; return document.listeningHistoryEpoch }
    var recentlyPlayed: [RecentListen] { _ = recentsRevision; return document.recentlyPlayed }
    var recentSearches: [String] { _ = searchesRevision; return document.recentSearches }
    var recentSearchSelections: [SearchSelection] { _ = searchSelectionsRevision; return document.recentSearchSelections }
    var searchHistoryResetRevision: LibrarySyncRevision? { _ = searchResetRevision; return document.syncState?.searchReset }
    var playback: PlaybackSnapshot { _ = playbackRevision; return document.playback }
    var followedArtists: [FollowedArtist] { _ = followsRevision; return document.followedArtists }
    var releases: [ArtistRelease] { _ = releasesRevision; return document.releases }
    var mixes: [GeneratedPlaylist] { _ = mixesRevision; return document.mixes }
    var unseenReleaseCount: Int { releases.filter { !$0.seen }.count }
    var disliked: [DislikedSong] { _ = dislikesRevision; return document.disliked }
    var dislikedTrackIDs: Set<String> { _ = dislikesRevision; return dislikedIDs }
    var tipCount: Int { _ = tipsRevision; return document.tipTransactions.values.filter { $0 }.count }
    var recordingLanguageOverrides: [String: String] { _ = recordingLanguageOverridesRevision; return document.recordingLanguageOverrides }
    var requiresReload: Bool { storageIsBlocked }
    var pendingReleaseNotifications: [ArtistRelease] {
        guard preferences.newReleaseAlerts else { return [] }
        _ = pendingNotificationsRevision
        let releases = Dictionary(uniqueKeysWithValues: self.releases.map { ($0.id, $0) })
        return document.pendingReleaseNotificationIDs.compactMap { id in
            guard let release = releases[id], isFollowing(artistID: release.artistID) else { return nil }
            return release
        }
    }

    var preferences: UserPreferences {
        get { _ = preferencesRevision; return document.preferences }
        set {
            guard newValue != document.preferences else { return }
            commit {
                if $0.preferences.saveListeningHistory, !newValue.saveListeningHistory {
                    $0.listeningHistoryEpoch = UUID()
                }
                if !$0.preferences.newReleaseAlerts || !newValue.newReleaseAlerts {
                    $0.pendingReleaseNotificationIDs.removeAll()
                }
                $0.preferences = newValue
            }
        }
    }

    init(directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }, writerID: UUID = UUID(),
         projectSyncValues: @escaping LibrarySyncValueProjection = LibrarySyncProjection.values,
         beforeListeningCheckpointPreparation: @escaping @Sendable () async throws -> Void = {}) {
        self.now = now
        self.syncWriterID = writerID
        self.projectSyncValues = projectSyncValues
        self.beforeListeningCheckpointPreparation = beforeListeningCheckpointPreparation
        do {
            let directory = try LibraryPersistence.directory(directory)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            fileURL = url
            let saved = try LibraryPersistence.readStamped(url)
            if let data = saved.data {
                let now = self.now()
                persistedData = data
                persistedStamp = saved.stamp
                storageBytes = Int64(data.count)
                publish(try LibraryPersistence.decode(data, now: now))
                var retained = document
                if LibraryHistoryRetention.apply(to: &retained, now: now) {
                    commit(syncSharedChanges: false) { $0 = retained }
                }
            }
            hasLoadedDocument = true
            widgetLibrarySourceIsAvailable = !storageIsBlocked
        } catch {
            storageIsBlocked = true
            if let error = error as? LibraryStorageError {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = "Velvet Thorn couldn’t read your saved library. The file has been kept and won’t be overwritten. \(error.localizedDescription)"
            }
        }
    }

    /// Reloads validated bytes without replacing the store or writing the file; ordinary conflicts keep pending listening.
    /// Call outside listening callbacks: privacy boundaries invoke onHistoryCleared, retiring their captured checkpoints.
    func reloadFromDisk() -> LibraryReloadResult {
        invalidateListeningCheckpointPreparations()
        guard let fileURL else { return .failed }
        do {
            let saved = try LibraryPersistence.readStamped(fileURL)
            guard let data = saved.data else { throw LibraryStorageError.missingFile }
            let now = self.now()
            let reloaded = try LibraryPersistence.decode(data, now: now)
            let historyBoundary = LibraryRecovery.crossesHistoryBoundary(from: document, to: reloaded, now: now)
            var stamp = saved.stamp
            if try LibraryPersistence.verify(fileURL, expected: data, stamp: &stamp) == .content { contentFenceReadCount &+= 1 }
            storageIsBlocked = true
            syncPreparationGeneration = UUID()
            checkpointDocumentGeneration = UUID()
            persistedData = data
            persistedStamp = stamp
            storageBytes = Int64(data.count)
            publish(reloaded)
            hasLoadedDocument = true
            if historyBoundary { onHistoryCleared?() }
            storageIsBlocked = false
            errorMessage = nil
            widgetLibrarySourceIsAvailable = true
            onWidgetLibraryChange?()
            onSyncChange?()
            return historyBoundary ? .historyBoundary : .reloaded
        } catch {
            storageIsBlocked = true
            errorMessage = "Velvet Thorn couldn’t reload your saved library. \(error.localizedDescription)"
            widgetStorageFailed()
            return .failed
        }
    }

    /// Activation and delayed artwork must verify the saved source; ordinary checkpoints already passed persist's check.
    @discardableResult
    func validateWidgetLibrarySource() -> Bool {
        let available: Bool
        if hasLoadedDocument, !storageIsBlocked, let fileURL {
            do { _ = try verifyDiskBaseline(fileURL); available = true }
            catch { available = false }
        } else {
            available = false
        }
        if available != widgetLibrarySourceIsAvailable {
            // Reentrant validation must observe the transition before notifying any publication or route caller.
            widgetLibrarySourceIsAvailable = available
            onWidgetLibraryChange?()
        }
        return widgetLibrarySourceIsAvailable
    }

    private func widgetStorageFailed() {
        validateWidgetLibrarySource()
    }

    func isFavorite(_ track: Track) -> Bool {
        _ = favoritesRevision
        return favoriteIDs.contains(track.id)
    }

    func toggleFavorite(_ track: Track) {
        commit {
            if $0.favorites.contains(where: { $0.id == track.id }) {
                $0.favorites.removeAll { $0.id == track.id }
                $0.superLikedIDs.removeAll { $0 == track.id }
            } else {
                $0.favorites.insert(track, at: 0)
                // Liking is the stronger, more recent signal; it lifts an earlier dislike.
                $0.disliked.removeAll { $0.id == track.id }
            }
        }
    }

    func isSuperLiked(_ track: Track) -> Bool {
        _ = favoritesRevision
        return superLikedIDSet.contains(track.id)
    }

    /// Promotion likes the song if needed and lifts a dislike; demotion keeps the like. Either is a new reaction,
    /// so the song moves to the top of Liked Songs, matching the newest-first order sync materializes.
    func setSuperLiked(_ track: Track, _ superLiked: Bool) {
        guard superLikedIDSet.contains(track.id) != superLiked else { return }
        commit {
            let existing = $0.favorites.first { $0.id == track.id }
            $0.favorites.removeAll { $0.id == track.id }
            $0.favorites.insert(existing ?? track, at: 0)
            $0.disliked.removeAll { $0.id == track.id }
            var ids = Set($0.superLikedIDs)
            if superLiked { ids.insert(track.id) } else { ids.remove(track.id) }
            $0.superLikedIDs = $0.favorites.map(\.id).filter(ids.contains)
        }
    }

    func isDisliked(_ track: Track) -> Bool {
        _ = dislikesRevision
        return dislikedIDs.contains(track.id)
    }

    /// Likes every song not yet liked in one write; a local dislike is a deliberate choice and is left standing.
    /// Returns how many songs became liked. Nothing is unliked.
    @discardableResult
    func addFavorites(_ tracks: [Track]) -> Int {
        let liked = Set(favorites.map(\.id))
        let disliked = dislikedTrackIDs
        var seen = liked.union(disliked)
        let additions = tracks.filter { seen.insert($0.id).inserted }
        guard !additions.isEmpty else { return 0 }
        let written = commit { $0.favorites.insert(contentsOf: additions, at: 0) }
        return written ? additions.count : 0
    }

    /// Disliking also removes a like and drops the song from generated mixes so it stops surfacing immediately.
    func toggleDislike(_ track: Track) {
        commit {
            if $0.disliked.contains(where: { $0.id == track.id }) {
                $0.disliked.removeAll { $0.id == track.id }
            } else {
                $0.disliked.insert(DislikedSong(id: track.id, title: track.title, artists: track.artists, dislikedAt: now()), at: 0)
                $0.favorites.removeAll { $0.id == track.id }
                $0.superLikedIDs.removeAll { $0 == track.id }
                for index in $0.mixes.indices { $0.mixes[index].tracks.removeAll { $0.id == track.id } }
                $0.mixes.removeAll { $0.tracks.isEmpty }
            }
        }
    }

    @discardableResult
    func createPlaylist(name: String, tracks: [Track] = []) -> UUID {
        let now = self.now()
        var ids = Set<String>()
        let playlist = UserPlaylist(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            tracks: tracks.filter { ids.insert($0.id).inserted },
            createdAt: now, updatedAt: now
        )
        guard LibraryValidation.isValidID(playlist.name) else {
            reject("Give your playlist a name before saving it.")
            return playlist.id
        }
        commit { $0.playlists.insert(playlist, at: 0) }
        return playlist.id
    }

    func renamePlaylist(id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LibraryValidation.isValidID(name) else {
            reject("Give your playlist a name before saving it.")
            return
        }
        guard let index = playlistIndex(id) else { return }
        commit {
            $0.playlists[index].name = name
            $0.playlists[index].updatedAt = max($0.playlists[index].updatedAt, now())
        }
    }

    func deletePlaylist(id: UUID) {
        guard playlistIndex(id) != nil else { return }
        commit { $0.playlists.removeAll { $0.id == id } }
    }

    func add(_ track: Track, to playlistID: UUID) {
        guard let index = playlistIndex(playlistID) else { return }
        guard !playlists[index].tracks.contains(where: { $0.id == track.id }) else { return }
        commit {
            $0.playlists[index].tracks.append(track)
            $0.playlists[index].updatedAt = max($0.playlists[index].updatedAt, now())
        }
    }

    /// Adds the songs missing from the playlist in one write and returns how many joined. `leading` puts `tracks`
    /// first in their given order (imports keep newest plays on top); otherwise new songs append. Nothing is removed.
    @discardableResult
    func merge(_ tracks: [Track], into playlistID: UUID, leading: Bool = false) -> Int {
        guard let index = playlistIndex(playlistID) else { return 0 }
        let existing = playlists[index].tracks
        var seen = Set<String>()
        let incoming = tracks.filter { seen.insert($0.id).inserted }
        let known = Set(existing.map(\.id))
        let added = incoming.filter { !known.contains($0.id) }.count
        let merged = leading ? incoming + existing.filter { !seen.contains($0.id) }
            : existing + incoming.filter { !known.contains($0.id) }
        guard merged.map(\.id) != existing.map(\.id) else { return 0 }
        let written = commit {
            $0.playlists[index].tracks = merged
            $0.playlists[index].updatedAt = max($0.playlists[index].updatedAt, now())
        }
        return written ? added : 0
    }

    func remove(trackID: String, from playlistID: UUID) {
        guard let index = playlistIndex(playlistID) else { return }
        guard playlists[index].tracks.contains(where: { $0.id == trackID }) else { return }
        commit {
            $0.playlists[index].tracks.removeAll { $0.id == trackID }
            $0.playlists[index].updatedAt = max($0.playlists[index].updatedAt, now())
        }
    }

    func moveTracks(in playlistID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let index = playlistIndex(playlistID) else { return }
        let tracks = playlists[index].tracks
        guard !offsets.isEmpty else { return }
        guard offsets.allSatisfy({ tracks.indices.contains($0) }), (0...tracks.count).contains(destination) else {
            reject("Those songs couldn’t be reordered. Open the playlist and try again.")
            return
        }
        let moved = offsets.map { tracks[$0] }
        var remaining = tracks.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moved, at: insertion)
        guard remaining.map(\.id) != tracks.map(\.id) else { return }
        commit {
            $0.playlists[index].tracks = remaining
            $0.playlists[index].updatedAt = max($0.playlists[index].updatedAt, now())
        }
    }

    /// False leaves the delta with the player for retry; disabled history and zero time are acknowledged no-ops.
    @discardableResult
    func recordListening(track: Track, sessionID: UUID, startedAt: Date, seconds: TimeInterval,
                         recentPosition: TimeInterval? = nil) -> Bool {
        let began = ContinuousClock.now
        var outcome = "rejected"
        defer {
            log.info("event=listening_checkpoint outcome=\(outcome, privacy: .public) duration_ms=\(Int(began.duration(to: .now) / .milliseconds(1))) lifetime_sessions=\(self.document.lifetimeListening.sessions.count)")
        }
        guard preferences.saveListeningHistory else { outcome = "history_disabled"; return true }
        guard seconds != 0 else { outcome = "zero_delta"; return true }
        let now = self.now()
        guard LibraryValidation.isValidDate(startedAt),
              LibraryValidation.isValidListeningSeconds(seconds, now: now) else {
            reject("This listening update has an invalid date or elapsed time and wasn’t saved.")
            return false
        }
        if let recentPosition, !recentPosition.isFinite || recentPosition < 0 {
            reject("This song’s resume position is invalid and wasn’t saved.")
            return false
        }
        let index = events.firstIndex(where: { $0.id == sessionID })
        var event: ListeningEvent
        if let index {
            let existing = events[index]
            guard existing.track.id == track.id, abs(existing.startedAt.timeIntervalSince(startedAt)) < 0.001 else {
                reject("This listening session doesn’t match its saved song or start time and wasn’t changed.")
                return false
            }
            let total = existing.listenedSeconds + seconds
            guard LibraryValidation.isValidListeningSeconds(total, now: now) else {
                reject("This listening update has an invalid elapsed time and wasn’t saved.")
                return false
            }
            // The player owns checkpoint idempotency. Equal-sized deltas are separate listening time.
            event = existing
            event.listenedSeconds = total
            event.track = track
        } else {
            event = ListeningEvent(id: sessionID, track: track, startedAt: startedAt, listenedSeconds: seconds)
        }
        var lifetime = document.lifetimeListening
        do {
            let cumulative = try lifetime.cumulativeEvent(for: ListeningEvent(id: sessionID, track: track,
                startedAt: event.startedAt, listenedSeconds: seconds))
            event.listenedSeconds = max(event.listenedSeconds, cumulative.listenedSeconds)
            try lifetime.include(event)
        } catch {
            reject("This listening update couldn’t be saved. \(error.localizedDescription)")
            return false
        }
        let recent = recentPosition.map { RecentListen(track: track, playedAt: now, position: $0) }
        let commitsBefore = durableCommitCount
        let acknowledged = commit(syncCheckpoint: .listening(event, recent: recent)) {
            $0.lifetimeListening = lifetime
            if let index { $0.events[index] = event }
            else {
                $0.events.append(event)
                $0.events.sort {
                    if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            }
            if let recent {
                $0.recentlyPlayed.removeAll { $0.id == track.id }
                $0.recentlyPlayed.insert(recent, at: 0)
            }
        }
        if acknowledged { outcome = durableCommitCount == commitsBefore ? "no_change" : "committed" }
        return acknowledged
    }

    // A context boundary retires captured work, but ordinary account/reload fences keep the player's unsaved deltas.
    func invalidateListeningCheckpointPreparations() {
        checkpointContextGeneration = UUID()
    }

    func prepareListeningCheckpoint(events: [ListeningEvent], recent: RecentListen? = nil,
                                    snapshot: PlaybackSnapshot? = nil) async throws -> LibraryListeningCheckpointPreparation {
        let began = ContinuousClock.now
        guard !checkpointPreparationIsRunning else { throw LibraryListeningCheckpointError.busy }
        guard !storageIsBlocked, hasLoadedDocument, fileURL != nil else { throw LibraryStorageError.invalidDirectory }
        checkpointPreparationIsRunning = true
        defer { checkpointPreparationIsRunning = false }
        let document = document
        let documentGeneration = checkpointDocumentGeneration
        let privacyGeneration = checkpointPrivacyGeneration
        let contextGeneration = checkpointContextGeneration
        let time = now()
        let writer = syncWriterID
        let hook = beforeListeningCheckpointPreparation
        let log = log
        let captureMS = began.duration(to: .now) / .milliseconds(1)
        listeningCheckpointMainActorMilliseconds += captureMS
        let worker = Task.detached(priority: .utility) {
            let began = ContinuousClock.now
            var outcome = "rejected"
            defer {
                let result = Task.isCancelled ? "cancelled" : outcome
                log.info("event=listening_checkpoint_preparation outcome=\(result, privacy: .public) duration_ms=\(began.duration(to: .now) / .milliseconds(1))")
            }
            try await hook()
            try Task.checkCancellation()
            let prepared = try LibraryListeningCheckpointPreparation.make(events: events, recent: recent, snapshot: snapshot,
                document: document, documentGeneration: documentGeneration, privacyGeneration: privacyGeneration,
                 contextGeneration: contextGeneration, now: time, writer: writer, captureMilliseconds: captureMS)
            outcome = "prepared"
            return prepared
        }
        return try await withTaskCancellationHandler {
            let prepared = try await worker.value
            try Task.checkCancellation()
            return prepared
        } onCancel: {
            worker.cancel()
        }
    }

    /// False means unchanged durable bytes; stale or retired captures never enter persistence or notify observers.
    @discardableResult
    func applyListeningCheckpoint(_ preparation: LibraryListeningCheckpointPreparation) throws -> Bool {
        let began = ContinuousClock.now
        var outcome = "rejected"
        defer {
            let metrics = LibraryListeningCheckpointMetrics(preparationMilliseconds: preparation.preparationMilliseconds,
                captureMilliseconds: preparation.captureMilliseconds, applyMilliseconds: began.duration(to: .now) / .milliseconds(1),
                outcome: outcome)
            lastListeningCheckpointMetrics = metrics
            listeningCheckpointMainActorMilliseconds += metrics.applyMilliseconds
            log.info("event=listening_checkpoint_async outcome=\(outcome, privacy: .public) preparation_ms=\(metrics.preparationMilliseconds) capture_ms=\(metrics.captureMilliseconds) apply_ms=\(metrics.applyMilliseconds) lifetime_sessions=\(self.document.lifetimeListening.sessions.count)")
        }
        try Task.checkCancellation()
        guard preparation.privacyGeneration == checkpointPrivacyGeneration,
              preparation.contextGeneration == checkpointContextGeneration else {
            outcome = "retired"
            throw LibraryListeningCheckpointError.retired
        }
        guard preparation.documentGeneration == checkpointDocumentGeneration else {
            outcome = "stale"
            throw LibraryListeningCheckpointError.stale
        }
        guard !storageIsBlocked, hasLoadedDocument else { throw LibraryStorageError.invalidDirectory }
        // Even an unchanged checkpoint must verify its disk baseline before acknowledging captured listening.
        if preparation.encoded == persistedData {
            guard let fileURL else { throw LibraryStorageError.changedOnDisk }
            let fenceBegan = ContinuousClock.now
            do {
                let fence = try verifyDiskBaseline(fileURL)
                logPersist(.checkpoint, fence: fence, outcome: "unchanged", bytes: 0, began: fenceBegan)
            } catch {
                logPersist(.checkpoint, fence: .content, outcome: Self.persistFailureOutcome(error), bytes: 0, began: fenceBegan)
                throw error
            }
            errorMessage = nil
            outcome = "no_change"
            return false
        }
        let written = try persist(preparation.candidate, path: .checkpoint, encoded: preparation.encoded,
                                  syncChanged: preparation.syncChanged,
                                  historyChanged: preparation.historyChanged, lifetimeChanged: preparation.lifetimeChanged,
                                  lifetimePublication: preparation.lifetimePublication)
        errorMessage = nil
        if written, preparation.syncChanged { onSyncChange?() }
        outcome = "committed"
        return written
    }

    /// Rebase at most three preparations. Privacy/context changes reject the capture; they never replay it into a new epoch.
    func recordListeningCheckpoint(events: [ListeningEvent], recent: RecentListen? = nil, snapshot: PlaybackSnapshot? = nil,
                                   isCurrentIntent: @escaping @MainActor () -> Bool = { true },
                                   isCurrentContext: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        let privacy = checkpointPrivacyGeneration
        let context = checkpointContextGeneration
        let playbackFence = playbackRevision
        let recentFence = recentsRevision
        var recent = recent
        var snapshot = snapshot
        for _ in 0..<3 {
            guard !Task.isCancelled, privacy == checkpointPrivacyGeneration, context == checkpointContextGeneration,
                  isCurrentContext() else { return false }
            if !isCurrentIntent() { recent = nil; snapshot = nil }
            if playbackFence != playbackRevision { snapshot = nil }
            if recentFence != recentsRevision { recent = nil }
            guard !events.isEmpty || recent != nil || snapshot != nil else { return true }
            if !document.preferences.saveListeningHistory, snapshot == nil { return true }
            // An unchanged resume snapshot must not make a legacy migration or an empty startup document durable.
            if events.isEmpty || !document.preferences.saveListeningHistory,
               recent == nil || !document.preferences.saveListeningHistory,
               let snapshot, Self.playbackMatches(snapshot, document.playback) { return true }
            guard !storageIsBlocked, hasLoadedDocument, fileURL != nil else { return false }
            do {
                let prepared = try await prepareListeningCheckpoint(events: events, recent: recent, snapshot: snapshot)
                guard !Task.isCancelled, privacy == checkpointPrivacyGeneration, context == checkpointContextGeneration,
                      isCurrentContext() else { return false }
                if (recent != nil || snapshot != nil), !isCurrentIntent() {
                    recent = nil
                    snapshot = nil
                    continue
                }
                if (snapshot != nil && playbackFence != playbackRevision) || (recent != nil && recentFence != recentsRevision) {
                    if playbackFence != playbackRevision { snapshot = nil }
                    if recentFence != recentsRevision { recent = nil }
                    continue
                }
                _ = try applyListeningCheckpoint(prepared)
                return true
            } catch LibraryListeningCheckpointError.stale {
                continue
            } catch is LibraryListeningCheckpointError {
                return false
            } catch is CancellationError {
                return false
            } catch {
                if case LibraryStorageError.changedOnDisk = error {
                    storageIsBlocked = true
                    errorMessage = error.localizedDescription
                } else if !storageIsBlocked {
                    errorMessage = "Velvet Thorn couldn’t save this listening checkpoint. \(error.localizedDescription)"
                }
                widgetStorageFailed()
                return false
            }
        }
        return false
    }

    func updatePlayback(_ snapshot: PlaybackSnapshot) {
        guard !Self.playbackMatches(snapshot, playback) else { return }
        // Queue checkpoints carry resume state, never listening time or a counted play.
        commit(syncSharedChanges: false) { $0.playback = snapshot }
    }

    func recordRecent(track: Track, position: TimeInterval) {
        guard preferences.saveListeningHistory else { return }
        guard position.isFinite, position >= 0 else {
            reject("This song’s resume position is invalid and wasn’t saved.")
            return
        }
        let recent = RecentListen(track: track, playedAt: now(), position: position)
        commit(syncCheckpoint: .recent(recent)) {
            $0.recentlyPlayed.removeAll { $0.id == track.id }
            $0.recentlyPlayed.insert(recent, at: 0)
        }
    }

    func clearHistory() {
        if commit(syncMutation: LibrarySyncMutation(clearHistory: true), {
            $0.listeningHistoryEpoch = UUID()
            $0.events.removeAll()
            $0.lifetimeListening = LifetimeListeningRollup()
            $0.recentlyPlayed.removeAll()
            // Mixes are derived from history, so they go with it. Follows and likes are explicit choices and stay.
            $0.mixes.removeAll()
        }) { onHistoryCleared?() }
    }

    func recordSearch(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SearchHistory.key(query)
        guard !key.isEmpty else { return }
        let searches = Array(([query] + recentSearches.filter { SearchHistory.key($0) != key }).prefix(SearchHistory.limit))
        guard searches != recentSearches else { return }
        commit(syncMutation: LibrarySyncMutation(searchKey: key)) { $0.recentSearches = searches }
    }

    func removeRecentSearch(_ query: String) {
        let key = SearchHistory.key(query)
        guard recentSearches.contains(where: { SearchHistory.key($0) == key }) else { return }
        commit { $0.recentSearches.removeAll { SearchHistory.key($0) == key } }
    }

    @discardableResult
    func recordSearchSelection(_ selection: SearchSelection) -> Bool {
        let saved: SearchSelection
        switch selection {
        case .track: saved = selection
        case .collection(var collection):
            // A recent opens the provider destination, not the songs visible during an earlier visit.
            collection.tracks = []
            saved = .collection(collection)
        }
        return commit(syncMutation: LibrarySyncMutation(searchSelectionKey: saved.id)) {
            $0.recentSearchSelections.removeAll { $0.id == saved.id }
            $0.recentSearchSelections.insert(saved, at: 0)
            $0.recentSearchSelections = Array($0.recentSearchSelections.prefix(SearchHistory.limit))
        }
    }

    @discardableResult
    func removeRecentSearchSelection(id: String) -> Bool {
        guard !storageIsBlocked, let fileURL else { return false }
        guard LibraryValidation.isValidSearchSelectionID(id) else {
            reject("That recent search selection has an invalid identifier.")
            return false
        }
        guard recentSearchSelections.contains(where: { $0.id == id }) else {
            do {
                _ = try verifyDiskBaseline(fileURL)
                return true
            } catch {
                if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
                errorMessage = "Velvet Thorn couldn’t remove this recent search selection. \(error.localizedDescription)"
                widgetStorageFailed()
                return false
            }
        }
        return commit { $0.recentSearchSelections.removeAll { $0.id == id } }
    }

    @discardableResult
    func clearRecentSearches() -> Bool {
        commit(syncMutation: LibrarySyncMutation(clearSearches: true)) {
            $0.recentSearches.removeAll()
            $0.recentSearchSelections.removeAll()
        }
    }

    func isFollowing(artistID: String) -> Bool {
        followedArtists.contains { $0.id == artistID }
    }

    /// Callers mark successful empty catalog reads explicitly; supplied known IDs also establish a baseline.
    func follow(_ artist: FollowedArtist) {
        guard LibraryValidation.isValidID(artist.id), LibraryValidation.isValidID(artist.name) else {
            reject("This artist has no usable identifier and couldn’t be followed.")
            return
        }
        guard !isFollowing(artistID: artist.id) else { return }
        var artist = artist
        artist.hasEstablishedReleaseBaseline = artist.hasEstablishedReleaseBaseline || !artist.knownReleaseIDs.isEmpty
        commit { $0.followedArtists.insert(artist, at: 0) }
    }

    func unfollow(artistID: String) {
        guard isFollowing(artistID: artistID) else { return }
        commit {
            let removedIDs = Set($0.releases.filter { $0.artistID == artistID }.map(\.id))
            $0.pendingReleaseNotificationIDs.removeAll { removedIDs.contains($0) }
            $0.followedArtists.removeAll { $0.id == artistID }
            $0.releases.removeAll { $0.artistID == artistID }
        }
    }

    /// Failed catalog reads update attempt time without inventing a baseline. True acknowledges durable storage.
    /// New releases are kept newest first, bounded to the most recent 60.
    @discardableResult
    func recordReleaseCheck(artistID: String, knownReleaseIDs: [String], newReleases: [ArtistRelease],
                            checkedAt: Date = Date(), catalogReadSucceeded: Bool = true) -> Bool {
        guard let index = followedArtists.firstIndex(where: { $0.id == artistID }) else { return false }
        let additions = newReleases.filter { release in
            release.artistID == artistID && !releases.contains { $0.id == release.id }
        }
        var known = Set(followedArtists[index].knownReleaseIDs)
        knownReleaseIDs.forEach { known.insert($0) }
        additions.forEach { known.insert($0.id) }
        return commit {
            $0.followedArtists[index].lastCheckedAt = checkedAt
            if catalogReadSucceeded {
                $0.followedArtists[index].hasEstablishedReleaseBaseline = true
                $0.followedArtists[index].knownReleaseIDs = known.sorted()
                $0.releases = Array((additions + $0.releases).prefix(LibraryPersistence.releaseLimit))
                let retainedIDs = Set($0.releases.map(\.id))
                $0.pendingReleaseNotificationIDs.removeAll { !retainedIDs.contains($0) }
                if $0.preferences.newReleaseAlerts {
                    let pendingIDs = Set($0.pendingReleaseNotificationIDs)
                    $0.pendingReleaseNotificationIDs += additions.map(\.id).filter {
                        retainedIDs.contains($0) && !pendingIDs.contains($0)
                    }
                }
            }
        }
    }

    func canDeliverReleaseNotification(_ release: ArtistRelease) -> Bool {
        _ = pendingNotificationsRevision
        guard !storageIsBlocked, let fileURL, preferences.newReleaseAlerts,
              isFollowing(artistID: release.artistID),
              document.pendingReleaseNotificationIDs.contains(release.id),
              releases.contains(where: { $0.id == release.id && $0.artistID == release.artistID }) else { return false }
        do {
            _ = try verifyDiskBaseline(fileURL)
            return true
        } catch {
            if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
            errorMessage = "Velvet Thorn couldn’t verify this release alert’s saved state. \(error.localizedDescription)"
            widgetStorageFailed()
            return false
        }
    }

    @discardableResult
    func acknowledgeReleaseNotification(id: String) -> Bool {
        guard document.pendingReleaseNotificationIDs.contains(id) else { return true }
        return commit(syncSharedChanges: false) { $0.pendingReleaseNotificationIDs.removeAll { $0 == id } }
    }

    func markReleasesSeen() {
        guard releases.contains(where: { !$0.seen }) else { return }
        commit { for index in $0.releases.indices { $0.releases[index].seen = true } }
    }

    func mix(_ kind: GeneratedPlaylistKind) -> GeneratedPlaylist? {
        mixes.first { $0.kind == kind }
    }

    func saveMix(_ mix: GeneratedPlaylist) {
        let dislikedIDs = dislikedTrackIDs
        let isEligible: (Track) -> Bool = { !dislikedIDs.contains($0.id) }
        if let saved = self.mix(mix.kind), saved.periodKey == mix.periodKey,
           !saved.tracks.isEmpty, saved.tracks.allSatisfy(isEligible) { return }
        var mix = mix
        mix.tracks = mix.tracks.filter(isEligible)
        guard !mix.tracks.isEmpty else { return }
        commit {
            $0.mixes.removeAll { $0.kind == mix.kind }
            $0.mixes.append(mix)
        }
    }

    /// Saves one period's Daily Mixes in a single write, replacing every Daily Mix kind so a thinner day
    /// cannot leave yesterday's Daily Mix 2 or 3 beside today's first mix. A saved current period is kept.
    func saveDailyMixes(_ mixes: [GeneratedPlaylist]) {
        guard let period = mixes.first?.periodKey, mixes.allSatisfy({ $0.kind.isDailyMix && $0.periodKey == period }) else { return }
        let dislikedIDs = dislikedTrackIDs
        if let saved = mix(.dailyMix), saved.periodKey == period, !saved.tracks.isEmpty,
           saved.tracks.allSatisfy({ !dislikedIDs.contains($0.id) }) { return }
        var kept: [GeneratedPlaylist] = []
        for var mix in mixes {
            mix.tracks = mix.tracks.filter { !dislikedIDs.contains($0.id) }
            guard !mix.tracks.isEmpty, kept.count < GeneratedPlaylistKind.dailyMixes.count else { continue }
            mix.kind = GeneratedPlaylistKind.dailyMixes[kept.count]
            kept.append(mix)
        }
        guard !kept.isEmpty else { return }
        commit {
            $0.mixes.removeAll { $0.kind.isDailyMix }
            $0.mixes += kept
        }
    }

    /// Changes whenever any input of the taste profile changes: history, likes and super likes, playlists, recents
    /// and dislikes. Process-local like the slice revisions it combines.
    var tasteInputsRevision: [UInt64] {
        [historyRevision, favoritesRevision, playlistsRevision, recentsRevision, dislikesRevision]
    }

    func summary(for window: ListeningWindow, now: Date = Date()) -> ListeningSummary {
        ListeningAnalytics.summary(events: events, for: window, now: now)
    }

    func languageSummary(for window: ListeningWindow, now: Date = Date(),
                         evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [:]) -> ListeningLanguageSummary {
        ListeningAnalytics.languageSummary(events: events, for: window, now: now,
                                           evidence: evidence, overrides: recordingLanguageOverrides)
    }

    func lyricsOffset(for trackID: String) -> TimeInterval {
        _ = lyricsOffsetsRevision
        return document.lyricsOffsets[trackID, default: 0]
    }

    @discardableResult
    func setRecordingLanguageOverride(_ code: String?, for trackID: String) -> Bool {
        guard LibraryValidation.isValidID(trackID), code.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true else {
            reject("That song language couldn't be saved.")
            return false
        }
        return commit {
            if let code { $0.recordingLanguageOverrides[trackID] = code }
            else { $0.recordingLanguageOverrides.removeValue(forKey: trackID) }
        }
    }

    func tipCredit(for transactionID: UInt64) -> Bool? {
        _ = tipsRevision
        return document.tipTransactions[String(transactionID)]
    }

    /// Success means the record is durable, including an already-saved duplicate.
    @discardableResult
    func recordTip(transactionID: UInt64, credited: Bool) -> Bool {
        guard !storageIsBlocked, let fileURL else { return false }
        let id = String(transactionID)
        // A refund tombstone must survive older StoreKit deliveries and unrelated library edits.
        let credit = document.tipTransactions[id] == false ? false : credited
        if document.tipTransactions[id] == credit {
            // No-op commits skip disk I/O; a StoreKit acknowledgement still needs a durable record.
            do {
                _ = try verifyDiskBaseline(fileURL)
            } catch {
                if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
                errorMessage = "Velvet Thorn couldn’t save this tip record. \(error.localizedDescription)"
                widgetStorageFailed()
                return false
            }
        }
        return commit(syncSharedChanges: false) { $0.tipTransactions[id] = credit }
    }

    func setLyricsOffset(_ value: TimeInterval, for trackID: String) {
        guard value.isFinite, LibraryValidation.isValidID(trackID) else {
            reject("This lyrics timing adjustment is invalid and wasn’t saved.")
            return
        }
        commit {
            if value == 0 { $0.lyricsOffsets.removeValue(forKey: trackID) }
            else { $0.lyricsOffsets[trackID] = value }
        }
    }

    private func playlistIndex(_ id: UUID) -> Int? {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else {
            reject("That playlist is no longer in your library.")
            return nil
        }
        return index
    }

    private func reject(_ message: String) {
        guard !storageIsBlocked else { return }
        errorMessage = message
    }

    /// Preparation never acknowledges an in-memory placeholder or an externally replaced library.
    func cloudReplica(replicaID: UUID) throws -> LibrarySyncReplica {
        do {
            try verifyCloudStorage()
            if document.syncState == nil {
                let prepared = try makeCloudPreparation(LibrarySyncState())
                _ = try persist(prepared.candidate, path: .sync, encoded: prepared.encoded, lifetimeChanged: prepared.lifetimeChanged,
                                lifetimePublication: prepared.lifetimePublication)
            }
            return LibrarySyncReplica(replicaID: replicaID, state: document.syncState!)
        } catch {
            cloudStorageFailed(error)
            throw error
        }
    }

    /// Incoming revisions are adopted, never restamped. Playback and device-only records come from this store.
    @discardableResult
    func mergeCloudState(_ incoming: LibrarySyncState) throws -> Bool {
        try applyCloudMerge(makeCloudPreparation(incoming))
    }

    func prepareCloudMerge(_ incoming: LibrarySyncState) async throws -> LibraryCloudMergePreparation {
        do { try verifyCloudStorage() } catch { cloudStorageFailed(error); throw error }
        let document = document
        let data = persistedData
        let generation = syncPreparationGeneration
        let time = now()
        let writer = syncWriterID
        let preparation = Task.detached(priority: .utility) {
            try LibraryCloudMergePreparation.make(incoming: incoming, document: document, baselineData: data,
                                                  generation: generation, now: time, writer: writer)
        }
        return try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
    }

    private func makeCloudPreparation(_ incoming: LibrarySyncState) throws -> LibraryCloudMergePreparation {
        do { try verifyCloudStorage() } catch { cloudStorageFailed(error); throw error }
        return try LibraryCloudMergePreparation.make(incoming: incoming, document: document, baselineData: persistedData,
                                                     generation: syncPreparationGeneration, now: now(), writer: syncWriterID)
    }

    @discardableResult
    func applyCloudMerge(_ preparation: LibraryCloudMergePreparation) throws -> Bool {
        do {
            try verifyCloudStorage()
            guard preparation.generation == syncPreparationGeneration else { throw LibrarySyncError.localChangedDuringSync }
            guard var encoded = preparation.encoded else { return false }
            var candidate = preparation.candidate
            let previousPreferences = document.preferences
            if preparation.baselineData != persistedData {
                candidate.playback = document.playback
                candidate.tipTransactions = document.tipTransactions
                candidate.pendingReleaseNotificationIDs = document.pendingReleaseNotificationIDs
                if !preparation.historyBoundary { candidate.listeningHistoryEpoch = document.listeningHistoryEpoch }
                LibrarySyncProjection.prunePendingNotifications(in: &candidate)
                encoded = try LibraryPersistence.encode(candidate)
            }
            _ = try persist(candidate, path: .sync, encoded: encoded, lifetimeChanged: preparation.lifetimeChanged,
                            lifetimePublication: preparation.lifetimePublication)
            errorMessage = nil
            if preparation.historyBoundary { onHistoryCleared?() }
            if preparation.remoteChanged { onCloudSyncApplied?(previousPreferences, preparation.recommendationsChanged) }
            return preparation.remoteChanged
        } catch {
            cloudStorageFailed(error)
            throw error
        }
    }

    private func verifyCloudStorage() throws {
        guard !storageIsBlocked, hasLoadedDocument, let fileURL else {
            throw LibrarySyncError.localStorage(errorMessage ?? "Reload the saved library before retrying.")
        }
        _ = try verifyDiskBaseline(fileURL)
    }

    private func cloudStorageFailed(_ error: any Error) {
        if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
        if !storageIsBlocked { errorMessage = "Velvet Thorn couldn’t sync your library. \(error.localizedDescription)" }
        else if case LibraryStorageError.changedOnDisk = error { errorMessage = error.localizedDescription }
        widgetStorageFailed()
    }

    private enum PersistPath: String {
        case checkpoint, manual, sync
    }

    // A throwing verify has always read content, so failures count as content reads.
    private func verifyDiskBaseline(_ fileURL: URL) throws -> LibraryPersistence.Fence {
        do {
            let fence = try LibraryPersistence.verify(fileURL, expected: persistedData, stamp: &persistedStamp)
            if fence == .content { contentFenceReadCount &+= 1 }
            return fence
        } catch {
            contentFenceReadCount &+= 1
            throw error
        }
    }

    private func logPersist(_ path: PersistPath, fence: LibraryPersistence.Fence?, outcome: String, bytes: Int,
                            began: ContinuousClock.Instant) {
        lastPersistFence = fence
        let fenceName = fence?.rawValue ?? "none"
        let wrote = outcome == "written" ? 1 : 0
        log.info("event=library_persist path=\(path.rawValue, privacy: .public) fence=\(fenceName, privacy: .public) outcome=\(outcome, privacy: .public) wrote=\(wrote) bytes=\(bytes) duration_ms=\(began.duration(to: .now) / .milliseconds(1))")
    }

    private static func persistFailureOutcome(_ error: any Error) -> String {
        if case LibraryStorageError.changedOnDisk = error { return "changed_on_disk" }
        return "failed"
    }

    private func persist(_ candidate: LibraryDocument, path: PersistPath, encoded: Data? = nil, syncChanged: Bool? = nil,
                         historyChanged: Bool? = nil, lifetimeChanged: Bool? = nil,
                         lifetimePublication: LifetimeListeningPublication? = nil) throws -> Bool {
        guard let fileURL else { throw LibraryStorageError.invalidDirectory }
        let began = ContinuousClock.now
        var fence: LibraryPersistence.Fence?
        var outcome = "failed"
        var bytes = 0
        defer { logPersist(path, fence: fence, outcome: outcome, bytes: bytes, began: began) }
        let data = try encoded ?? LibraryPersistence.encode(candidate)
        guard data != persistedData else { outcome = "unchanged"; return false }
        guard data.count <= LibraryPersistence.maximumFileBytes else { throw LibraryStorageError.tooLarge }
        // A throwing fence has always fallen back to comparing content.
        fence = .content
        do { fence = try verifyDiskBaseline(fileURL) }
        catch { outcome = Self.persistFailureOutcome(error); throw error }
        // An unknown stamp after a failed replace makes the next fence compare bytes instead of trusting stale metadata.
        persistedStamp = nil
        persistedStamp = try LibraryPersistence.replace(data, at: fileURL)
        outcome = "written"
        bytes = data.count
        checkpointDocumentGeneration = UUID()
        persistedData = data
        storageBytes = Int64(data.count)
        if syncChanged ?? (candidate.syncState != document.syncState) { syncPreparationGeneration = UUID() }
        durableCommitCount &+= 1
        publish(candidate, historyChanged: historyChanged, lifetimeChanged: lifetimeChanged, lifetimePublication: lifetimePublication)
        widgetLibrarySourceIsAvailable = true
        onWidgetLibraryChange?()
        return true
    }

    // All readers see the authoritative, durable document before any slice invalidation is delivered.
    // Revisions are process-local cache identities and never enter the library or sync journal.
    private func publish(_ candidate: LibraryDocument, historyChanged: Bool? = nil, lifetimeChanged: Bool? = nil,
                         lifetimePublication: LifetimeListeningPublication? = nil) {
        let previous = document
        if previous.listeningHistoryEpoch != candidate.listeningHistoryEpoch
            || previous.preferences.saveListeningHistory != candidate.preferences.saveListeningHistory
            || previous.syncState?.historyReset != candidate.syncState?.historyReset
            || previous.syncState?.historyRetirement != candidate.syncState?.historyRetirement {
            checkpointPrivacyGeneration = UUID()
        }
        document = candidate
        if previous.listeningHistoryEpoch != candidate.listeningHistoryEpoch { historyEpochRevision &+= 1 }
        if lifetimeChanged ?? (previous.lifetimeListening != candidate.lifetimeListening) {
            // Prepared projections share the document fence; no receipt scan is needed in the durable async apply turn.
            let publication = lifetimePublication ?? LifetimeListeningPublication(candidate.lifetimeListening, now: now())
            lifetimeSummary = publication.summary
            hasFutureLifetimeReceipts = publication.hasFutureReceipts
            lifetimeListeningRevision &+= 1
        }
        let favoritesChanged = previous.favorites != candidate.favorites || previous.superLikedIDs != candidate.superLikedIDs
        let dislikesChanged = previous.disliked != candidate.disliked
        if favoritesChanged {
            favoriteIDs = Set(candidate.favorites.map(\.id))
            superLikedIDSet = Set(candidate.superLikedIDs)
        }
        if dislikesChanged { dislikedIDs = Set(candidate.disliked.map(\.id)) }
        if favoritesChanged { favoritesRevision &+= 1 }
        if dislikesChanged { dislikesRevision &+= 1 }
        if previous.playlists != candidate.playlists { playlistsRevision &+= 1 }
        if previous.preferences != candidate.preferences { preferencesRevision &+= 1 }
        // Unchanged copy-on-write history shares its buffer, so playback publication need not scan every session.
        let sameHistoryStorage = previous.events.withUnsafeBufferPointer { before in
            candidate.events.withUnsafeBufferPointer { after in
                before.count == after.count && before.baseAddress == after.baseAddress
            }
        }
        if historyChanged ?? (!sameHistoryStorage && !previous.events.elementsEqual(candidate.events, by: {
            $0.id == $1.id && $0.startedAt == $1.startedAt && $0.listenedSeconds == $1.listenedSeconds && $0.track == $1.track
        })) { historyRevision &+= 1 }
        if !previous.recentlyPlayed.elementsEqual(candidate.recentlyPlayed, by: {
            $0.track == $1.track && $0.playedAt == $1.playedAt && $0.position == $1.position
        }) { recentsRevision &+= 1 }
        if !Self.playbackMatches(previous.playback, candidate.playback) { playbackRevision &+= 1 }
        if previous.recentSearches != candidate.recentSearches { searchesRevision &+= 1 }
        if previous.recentSearchSelections != candidate.recentSearchSelections { searchSelectionsRevision &+= 1 }
        if previous.syncState?.searchReset != candidate.syncState?.searchReset { searchResetRevision &+= 1 }
        if previous.followedArtists != candidate.followedArtists { followsRevision &+= 1 }
        if previous.releases != candidate.releases { releasesRevision &+= 1 }
        if previous.mixes != candidate.mixes { mixesRevision &+= 1 }
        if previous.tipTransactions != candidate.tipTransactions { tipsRevision &+= 1 }
        if previous.lyricsOffsets != candidate.lyricsOffsets { lyricsOffsetsRevision &+= 1 }
        if previous.pendingReleaseNotificationIDs != candidate.pendingReleaseNotificationIDs { pendingNotificationsRevision &+= 1 }
        if previous.recordingLanguageOverrides != candidate.recordingLanguageOverrides { recordingLanguageOverridesRevision &+= 1 }
    }

    private static func playbackMatches(_ lhs: PlaybackSnapshot, _ rhs: PlaybackSnapshot) -> Bool {
        lhs.currentIndex == rhs.currentIndex && lhs.position == rhs.position && lhs.shuffleEnabled == rhs.shuffleEnabled
            && lhs.repeatMode == rhs.repeatMode && lhs.queue == rhs.queue && lhs.originalQueue == rhs.originalQueue
            && lhs.originalQueueIndices == rhs.originalQueueIndices
    }

    @discardableResult
    private func commit(syncMutation: LibrarySyncMutation = LibrarySyncMutation(), syncSharedChanges: Bool = true,
                        syncCheckpoint: LibrarySyncCheckpoint? = nil,
                        _ change: (inout LibraryDocument) -> Void) -> Bool {
        guard !storageIsBlocked, fileURL != nil else { return false }
        var candidate = document
        change(&candidate)
        do {
            let now = self.now()
            // Validate before expiry so malformed old records cannot be silently discarded as maintenance.
            try LibraryValidation.validate(candidate, now: now)
            if candidate.preferences != document.preferences {
                _ = try LibrarySyncPreferences.applying(LibrarySyncPreferences.fields(candidate.preferences), to: candidate.preferences)
            }
            let expired = LibraryHistoryRetention.apply(to: &candidate, now: now)
            let historyWasPruned = expired || candidate.events.count < document.events.count
                || candidate.recentlyPlayed.count < document.recentlyPlayed.count
            var syncChanged = historyWasPruned
            if let syncCheckpoint {
                if var state = try LibrarySyncJournal.recordingCheckpoint(
                    syncCheckpoint, previous: document, candidate: candidate, historyWasPruned: historyWasPruned,
                    now: now, writer: syncWriterID, projectValues: projectSyncValues
                ) {
                    if document.syncState == nil {
                        try LibrarySyncJournal.restoreAggregates(in: &candidate, from: state)
                        LibrarySyncMerge.compact(&state, retaining: candidate)
                    }
                    syncChanged = syncChanged || document.syncState == nil || state.clock != document.syncState?.clock
                        || state.registers.count != (document.syncState?.registers.count ?? 0)
                    candidate.syncState = state
                }
            } else if syncSharedChanges {
                let difference = try LibrarySyncDifference(previous: document, candidate: candidate, mutation: syncMutation,
                                                           projectValues: projectSyncValues)
                if difference.hasChanges {
                    var state = try LibrarySyncJournal.recording(
                        previous: document, candidate: candidate, mutation: syncMutation, now: now, writer: syncWriterID,
                        difference: difference, projectValues: projectSyncValues
                    )
                    try LibrarySyncJournal.restoreAggregates(in: &candidate, from: state)
                    LibrarySyncMerge.compact(&state, retaining: candidate)
                    candidate.syncState = state
                    syncChanged = syncChanged || candidate.syncState != document.syncState
                } else if historyWasPruned, var state = candidate.syncState {
                    LibrarySyncMerge.compactHistory(&state, retaining: candidate)
                    candidate.syncState = state
                }
            } else if historyWasPruned, var state = candidate.syncState {
                LibrarySyncMerge.compactHistory(&state, retaining: candidate)
                candidate.syncState = state
            }
            let written = try persist(candidate, path: .manual, syncChanged: syncChanged)
            errorMessage = nil
            if written, syncChanged { onSyncChange?() }
            return true
        } catch {
            if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
            errorMessage = "Velvet Thorn couldn’t save this change. \(error.localizedDescription)"
            widgetStorageFailed()
            return false
        }
    }
}
