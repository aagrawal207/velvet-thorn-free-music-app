import Foundation
import Observation

@MainActor @Observable
final class LibraryStore {
    private var document = LibraryDocument()
    private(set) var errorMessage: String?
    private(set) var storageBytes: Int64 = 0
    /// A successful load includes a new empty library; failed reloads do not erase an established document.
    private(set) var hasLoadedDocument = false

    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var persistedData: Data?
    private var storageIsBlocked = false
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let syncWriterID: UUID
    @ObservationIgnored private let projectSyncValues: LibrarySyncValueProjection
    @ObservationIgnored private var syncPreparationGeneration = UUID()
    @ObservationIgnored var onHistoryCleared: (@MainActor () -> Void)?
    @ObservationIgnored var onCloudSyncApplied: (@MainActor (_ previous: UserPreferences, _ recommendationsChanged: Bool) -> Void)?
    @ObservationIgnored var onSyncChange: (@MainActor () -> Void)?
    @ObservationIgnored var onWidgetLibraryChange: (@MainActor () -> Void)?
    @ObservationIgnored private(set) var widgetLibrarySourceIsAvailable = false

    var syncDeviceConfigurationURL: URL? {
        fileURL?.deletingLastPathComponent().appendingPathComponent("LibrarySyncDevice/device.json")
    }

    var favorites: [Track] { document.favorites }
    var playlists: [UserPlaylist] { document.playlists }
    var events: [ListeningEvent] { document.events }
    var recentlyPlayed: [RecentListen] { document.recentlyPlayed }
    var recentSearches: [String] { document.recentSearches }
    var recentSearchSelections: [SearchSelection] { document.recentSearchSelections }
    var searchHistoryResetRevision: LibrarySyncRevision? { document.syncState?.searchReset }
    var playback: PlaybackSnapshot { document.playback }
    var followedArtists: [FollowedArtist] { document.followedArtists }
    var releases: [ArtistRelease] { document.releases }
    var mixes: [GeneratedPlaylist] { document.mixes }
    var unseenReleaseCount: Int { document.releases.filter { !$0.seen }.count }
    var disliked: [DislikedSong] { document.disliked }
    var dislikedTrackIDs: Set<String> { Set(document.disliked.map(\.id)) }
    var tipCount: Int { document.tipTransactions.values.filter { $0 }.count }
    var recordingLanguageOverrides: [String: String] { document.recordingLanguageOverrides }
    var requiresReload: Bool { storageIsBlocked }
    var pendingReleaseNotifications: [ArtistRelease] {
        guard preferences.newReleaseAlerts else { return [] }
        let releases = Dictionary(uniqueKeysWithValues: document.releases.map { ($0.id, $0) })
        return document.pendingReleaseNotificationIDs.compactMap { id in
            guard let release = releases[id], isFollowing(artistID: release.artistID) else { return nil }
            return release
        }
    }

    var preferences: UserPreferences {
        get { document.preferences }
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
         projectSyncValues: @escaping LibrarySyncValueProjection = LibrarySyncProjection.values) {
        self.now = now
        self.syncWriterID = writerID
        self.projectSyncValues = projectSyncValues
        do {
            let directory = try LibraryPersistence.directory(directory)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            fileURL = url
            if let data = try LibraryPersistence.read(url) {
                let now = self.now()
                persistedData = data
                storageBytes = Int64(data.count)
                document = try LibraryPersistence.decode(data, now: now)
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
                errorMessage = "Breezy couldn’t read your saved library. The file has been kept and won’t be overwritten. \(error.localizedDescription)"
            }
        }
    }

    /// Reloads validated bytes without replacing the store or writing the file; ordinary conflicts keep pending listening.
    /// Call outside listening callbacks: privacy boundaries invoke onHistoryCleared, retiring their captured checkpoints.
    func reloadFromDisk() -> LibraryReloadResult {
        guard let fileURL else { return .failed }
        do {
            guard let data = try LibraryPersistence.read(fileURL) else { throw LibraryStorageError.missingFile }
            let now = self.now()
            let reloaded = try LibraryPersistence.decode(data, now: now)
            let historyBoundary = LibraryRecovery.crossesHistoryBoundary(from: document, to: reloaded, now: now)
            guard try LibraryPersistence.read(fileURL) == data else { throw LibraryStorageError.changedOnDisk }
            storageIsBlocked = true
            syncPreparationGeneration = UUID()
            document = reloaded
            persistedData = data
            storageBytes = Int64(data.count)
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
            errorMessage = "Breezy couldn’t reload your saved library. \(error.localizedDescription)"
            widgetStorageFailed()
            return .failed
        }
    }

    /// Activation and delayed artwork must verify the saved source; ordinary checkpoints already passed persist's check.
    @discardableResult
    func validateWidgetLibrarySource() -> Bool {
        let available: Bool
        if hasLoadedDocument, !storageIsBlocked, let fileURL {
            do { available = try LibraryPersistence.read(fileURL) == persistedData }
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
        favorites.contains { $0.id == track.id }
    }

    func toggleFavorite(_ track: Track) {
        commit {
            if $0.favorites.contains(where: { $0.id == track.id }) {
                $0.favorites.removeAll { $0.id == track.id }
            } else {
                $0.favorites.insert(track, at: 0)
                // Liking is the stronger, more recent signal; it lifts an earlier dislike.
                $0.disliked.removeAll { $0.id == track.id }
            }
        }
    }

    func isDisliked(_ track: Track) -> Bool {
        document.disliked.contains { $0.id == track.id }
    }

    /// Disliking also removes a like and drops the song from generated mixes so it stops surfacing immediately.
    func toggleDislike(_ track: Track) {
        commit {
            if $0.disliked.contains(where: { $0.id == track.id }) {
                $0.disliked.removeAll { $0.id == track.id }
            } else {
                $0.disliked.insert(DislikedSong(id: track.id, title: track.title, artists: track.artists, dislikedAt: now()), at: 0)
                $0.favorites.removeAll { $0.id == track.id }
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
    func recordListening(track: Track, sessionID: UUID, startedAt: Date, seconds: TimeInterval) -> Bool {
        guard preferences.saveListeningHistory, seconds != 0 else { return true }
        let now = self.now()
        guard LibraryValidation.isValidDate(startedAt),
              LibraryValidation.isValidListeningSeconds(seconds, now: now) else {
            reject("This listening update has an invalid date or elapsed time and wasn’t saved.")
            return false
        }
        if let index = events.firstIndex(where: { $0.id == sessionID }) {
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
            var event = existing
            event.listenedSeconds = total
            event.track = track
            return commit(syncCheckpoint: .listening(event)) { $0.events[index] = event }
        } else {
            let event = ListeningEvent(id: sessionID, track: track, startedAt: startedAt, listenedSeconds: seconds)
            return commit(syncCheckpoint: .listening(event)) {
                $0.events.append(event)
                $0.events.sort {
                    if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            }
        }
    }

    func updatePlayback(_ snapshot: PlaybackSnapshot) {
        let saved = playback
        guard snapshot.currentIndex != saved.currentIndex || snapshot.position != saved.position
                || snapshot.shuffleEnabled != saved.shuffleEnabled || snapshot.repeatMode != saved.repeatMode
                || snapshot.queue != saved.queue || snapshot.originalQueue != saved.originalQueue
                || snapshot.originalQueueIndices != saved.originalQueueIndices else { return }
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
                guard try LibraryPersistence.read(fileURL) == persistedData else { throw LibraryStorageError.changedOnDisk }
                return true
            } catch {
                if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
                errorMessage = "Breezy couldn’t remove this recent search selection. \(error.localizedDescription)"
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
        guard !storageIsBlocked, let fileURL, preferences.newReleaseAlerts,
              isFollowing(artistID: release.artistID),
              document.pendingReleaseNotificationIDs.contains(release.id),
              releases.contains(where: { $0.id == release.id && $0.artistID == release.artistID }) else { return false }
        do {
            guard try LibraryPersistence.read(fileURL) == persistedData else { throw LibraryStorageError.changedOnDisk }
            return true
        } catch {
            if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
            errorMessage = "Breezy couldn’t verify this release alert’s saved state. \(error.localizedDescription)"
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

    func summary(for window: ListeningWindow, now: Date = Date()) -> ListeningSummary {
        ListeningAnalytics.summary(events: events, for: window, now: now)
    }

    func languageSummary(for window: ListeningWindow, now: Date = Date(),
                         evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [:]) -> ListeningLanguageSummary {
        ListeningAnalytics.languageSummary(events: events, for: window, now: now,
                                           evidence: evidence, overrides: recordingLanguageOverrides)
    }

    func lyricsOffset(for trackID: String) -> TimeInterval {
        document.lyricsOffsets[trackID, default: 0]
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
        document.tipTransactions[String(transactionID)]
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
                guard try LibraryPersistence.read(fileURL) == persistedData else { throw LibraryStorageError.changedOnDisk }
            } catch {
                if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
                errorMessage = "Breezy couldn’t save this tip record. \(error.localizedDescription)"
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
                _ = try persist(prepared.candidate, encoded: prepared.encoded)
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
            _ = try persist(candidate, encoded: encoded)
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
        guard try LibraryPersistence.read(fileURL) == persistedData else { throw LibraryStorageError.changedOnDisk }
    }

    private func cloudStorageFailed(_ error: any Error) {
        if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
        if !storageIsBlocked { errorMessage = "Breezy couldn’t sync your library. \(error.localizedDescription)" }
        else if case LibraryStorageError.changedOnDisk = error { errorMessage = error.localizedDescription }
        widgetStorageFailed()
    }

    private func persist(_ candidate: LibraryDocument, encoded: Data? = nil, syncChanged: Bool? = nil) throws -> Bool {
        guard let fileURL else { throw LibraryStorageError.invalidDirectory }
        let data = try encoded ?? LibraryPersistence.encode(candidate)
        guard data != persistedData else { return false }
        try LibraryPersistence.write(data, to: fileURL, replacing: persistedData)
        persistedData = data
        storageBytes = Int64(data.count)
        if syncChanged ?? (candidate.syncState != document.syncState) { syncPreparationGeneration = UUID() }
        document = candidate
        widgetLibrarySourceIsAvailable = true
        onWidgetLibraryChange?()
        return true
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
            let written = try persist(candidate, syncChanged: syncChanged)
            errorMessage = nil
            if written, syncChanged { onSyncChange?() }
            return true
        } catch {
            if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
            errorMessage = "Breezy couldn’t save this change. \(error.localizedDescription)"
            widgetStorageFailed()
            return false
        }
    }
}
