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
    @ObservationIgnored var onHistoryCleared: (@MainActor () -> Void)?

    var favorites: [Track] { document.favorites }
    var playlists: [UserPlaylist] { document.playlists }
    var events: [ListeningEvent] { document.events }
    var recentlyPlayed: [RecentListen] { document.recentlyPlayed }
    var recentSearches: [String] { document.recentSearches }
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

    init(directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
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
                    commit { $0 = retained }
                }
            }
            hasLoadedDocument = true
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
            document = reloaded
            persistedData = data
            storageBytes = Int64(data.count)
            hasLoadedDocument = true
            if historyBoundary { onHistoryCleared?() }
            storageIsBlocked = false
            errorMessage = nil
            return historyBoundary ? .historyBoundary : .reloaded
        } catch {
            storageIsBlocked = true
            errorMessage = "Breezy couldn’t reload your saved library. \(error.localizedDescription)"
            return .failed
        }
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
    func createPlaylist(name: String) -> UUID {
        let now = self.now()
        let playlist = UserPlaylist(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
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
            return commit {
                $0.events[index].listenedSeconds = total
                $0.events[index].track = track
            }
        } else {
            let event = ListeningEvent(id: sessionID, track: track, startedAt: startedAt, listenedSeconds: seconds)
            return commit {
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
                || snapshot.queue != saved.queue || snapshot.originalQueue != saved.originalQueue else { return }
        // Queue checkpoints carry resume state, never listening time or a counted play.
        commit { $0.playback = snapshot }
    }

    func recordRecent(track: Track, position: TimeInterval) {
        guard preferences.saveListeningHistory else { return }
        guard position.isFinite, position >= 0 else {
            reject("This song’s resume position is invalid and wasn’t saved.")
            return
        }
        let recent = RecentListen(track: track, playedAt: now(), position: position)
        commit {
            $0.recentlyPlayed.removeAll { $0.id == track.id }
            $0.recentlyPlayed.insert(recent, at: 0)
        }
    }

    func clearHistory() {
        if commit({
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
        commit { $0.recentSearches = searches }
    }

    func removeRecentSearch(_ query: String) {
        let key = SearchHistory.key(query)
        guard recentSearches.contains(where: { SearchHistory.key($0) == key }) else { return }
        commit { $0.recentSearches.removeAll { SearchHistory.key($0) == key } }
    }

    func clearRecentSearches() {
        guard !recentSearches.isEmpty else { return }
        commit { $0.recentSearches.removeAll() }
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
            return false
        }
    }

    @discardableResult
    func acknowledgeReleaseNotification(id: String) -> Bool {
        guard document.pendingReleaseNotificationIDs.contains(id) else { return true }
        return commit { $0.pendingReleaseNotificationIDs.removeAll { $0 == id } }
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
        let languages = preferences.languages
        let overrides = recordingLanguageOverrides
        let isEligible: (Track) -> Bool = { track in
            guard !dislikedIDs.contains(track.id) else { return false }
            guard !languages.isEmpty,
                  let language = ArtistSpotlight.languageResult(for: track, in: [:], overrides: overrides)?.language else { return true }
            switch language {
            case .hindi: return languages.contains(.hindi)
            case .english: return languages.contains(.english)
            default: return false
            }
        }
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
                return false
            }
        }
        return commit { $0.tipTransactions[id] = credit }
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

    @discardableResult
    private func commit(_ change: (inout LibraryDocument) -> Void) -> Bool {
        guard !storageIsBlocked, let fileURL else { return false }
        var candidate = document
        change(&candidate)
        do {
            let now = self.now()
            // Validate before expiry so malformed old records cannot be silently discarded as maintenance.
            try LibraryValidation.validate(candidate, now: now)
            LibraryHistoryRetention.apply(to: &candidate, now: now)
            let data = try LibraryPersistence.encode(candidate)
            if data != persistedData {
                try LibraryPersistence.write(data, to: fileURL, replacing: persistedData)
                persistedData = data
                storageBytes = Int64(data.count)
                document = candidate
            }
            errorMessage = nil
            return true
        } catch {
            if case LibraryStorageError.changedOnDisk = error { storageIsBlocked = true }
            errorMessage = "Breezy couldn’t save this change. \(error.localizedDescription)"
            return false
        }
    }
}
