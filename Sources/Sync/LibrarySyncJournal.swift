import Foundation

struct LibrarySyncMutation {
    var clearHistory = false
    var clearSearches = false
    var searchKey: String?
    var searchSelectionKey: String?
}

enum LibrarySyncCheckpoint {
    case listening(ListeningEvent)
    case recent(RecentListen)

    var key: LibrarySyncKey {
        switch self {
        case .listening(let event): LibrarySyncKey(.event, event.id.uuidString)
        case .recent(let recent): LibrarySyncKey(.recent, recent.id)
        }
    }

    func isRetained(in document: LibraryDocument) -> Bool {
        switch self {
        case .listening(let event): document.events.contains { $0.id == event.id }
        case .recent(let recent): document.recentlyPlayed.contains { $0.id == recent.id }
        }
    }

    func encodedValue() throws -> Data {
        switch self {
        case .listening(let event): try LibrarySyncProjection.listeningValue(event)
        case .recent(let recent): try LibrarySyncProjection.recentValue(recent)
        }
    }
}

struct LibrarySyncDifference {
    let before: [LibrarySyncKey: Data]
    let after: [LibrarySyncKey: Data]
    let changedKeys: [LibrarySyncKey]
    let hasChanges: Bool

    init(previous: LibraryDocument, candidate: LibraryDocument, mutation: LibrarySyncMutation,
         projectValues: LibrarySyncValueProjection = LibrarySyncProjection.values) throws {
        let before = try projectValues(previous)
        let after = try projectValues(candidate)
        let changed = Set(before.keys).union(after.keys).filter { key in
            before[key] != after[key] || (key.collection == .search && key.id == mutation.searchKey)
                || (key.collection == .searchSelection && key.id == mutation.searchSelectionKey)
        }.sorted()
        self.before = before
        self.after = after
        changedKeys = changed
        hasChanges = !changed.isEmpty || mutation.clearHistory || mutation.clearSearches
            || previous.playlists.map(\.tracks) != candidate.playlists.map(\.tracks)
            || previous.recentSearches != candidate.recentSearches
            || previous.recentSearchSelections != candidate.recentSearchSelections
    }
}

enum LibrarySyncJournal {
    static func seed(_ document: LibraryDocument, now: Date, writer: UUID,
                     projectValues: LibrarySyncValueProjection = LibrarySyncProjection.values) throws -> LibrarySyncState {
        var retained = document
        LibraryHistoryRetention.apply(to: &retained, now: now)
        let values = try projectValues(retained)
        let defaults = try LibrarySyncPreferences.fields(UserPreferences())
        var state = LibrarySyncState()
        for key in values.keys.sorted() {
            if key.collection == .preference, values[key] == defaults[key.id] { continue }
            let revision = try state.nextRevision(now: now, writer: writer)
            state.put(key, value: values[key], revision: revision)
        }
        // Legacy display order has no timestamps for likes or searches; seed it once, oldest first.
        for track in retained.favorites.reversed() {
            let key = LibrarySyncKey(.reaction, track.id)
            let revision = try state.nextRevision(now: now, writer: writer)
            state.put(key, value: values[key], revision: revision)
        }
        for query in retained.recentSearches.reversed() {
            let key = LibrarySyncKey(.search, SearchHistory.key(query))
            let revision = try state.nextRevision(now: now, writer: writer)
            state.put(key, value: values[key], revision: revision)
        }
        for selection in retained.recentSearchSelections.reversed() {
            let key = LibrarySyncKey(.searchSelection, selection.id)
            let revision = try state.nextRevision(now: now, writer: writer)
            state.put(key, value: values[key], revision: revision)
        }
        for playlist in retained.playlists.reversed() {
            let key = LibrarySyncKey(.playlist, playlist.id.uuidString)
            let revision = try state.nextRevision(now: now, writer: writer)
            state.put(key, value: values[key], revision: revision)
        }
        for artist in retained.followedArtists.reversed() {
            let key = LibrarySyncKey(.follow, artist.id)
            let revision = try state.nextRevision(now: now, writer: writer)
            state.put(key, value: values[key], revision: revision)
        }
        for song in retained.disliked.reversed() {
            let key = LibrarySyncKey(.reaction, song.id)
            let revision = try state.nextRevision(now: now, writer: writer)
            state.put(key, value: values[key], revision: revision)
        }
        if retained.listeningHistoryEpoch != nil {
            state.historyRetirement = try state.nextRevision(now: now, writer: writer)
        }
        try positionPlaylists(previous: [], candidate: retained.playlists, state: &state, now: now, writer: writer)
        guard state.registers.count <= LibrarySyncCodec.maximumRegisters else { throw LibrarySyncError.tooLarge }
        return state
    }

    static func recording(previous: LibraryDocument, candidate: LibraryDocument, mutation: LibrarySyncMutation,
                          now: Date, writer: UUID, difference: LibrarySyncDifference? = nil,
                          projectValues: LibrarySyncValueProjection = LibrarySyncProjection.values) throws -> LibrarySyncState {
        let difference = try difference ?? LibrarySyncDifference(previous: previous, candidate: candidate, mutation: mutation,
                                                                 projectValues: projectValues)
        var state = try previous.syncState ?? seed(previous, now: now, writer: writer, projectValues: projectValues)
        let before = difference.before
        let after = difference.after
        if mutation.clearHistory {
            state.historyReset = try state.nextRevision(now: now, writer: writer)
        }
        if previous.preferences.saveListeningHistory && !candidate.preferences.saveListeningHistory {
            state.historyRetirement = try state.nextRevision(now: now, writer: writer)
        }
        if mutation.clearSearches {
            state.searchReset = try state.nextRevision(now: now, writer: writer)
            state.searchFloor = nil
            state.searchSelectionFloor = nil
        }
        for key in difference.changedKeys {
            if key.collection.isHistory, mutation.clearHistory { continue }
            if key.collection.isSearchHistory, mutation.clearSearches { continue }
            // Expired listening has a time-based retention rule, not an ever-growing tombstone per session.
            if (key.collection == .event || key.collection == .recent), after[key] == nil { continue }
            if (key.collection == .followMetadata || key.collection == .releaseSeen || key.collection == .playlistUpdated), after[key] == nil { continue }
            if key.collection == .playlist || key.collection == .playlistTrack, before[key] != nil, after[key] != nil { continue }
            let revision = try state.nextRevision(now: now, writer: writer)
            let existing = state.registers[key]
            state.put(key, value: after[key], revision: revision)
            if let existing, key.collection == .followMetadata || key.collection == .releaseSeen || key.collection == .playlistUpdated {
                state.registers[key] = try LibrarySyncMerge.joinRegister(existing, state.registers[key]!, key: key)
            }
        }
        try positionPlaylists(previous: previous.playlists, candidate: candidate.playlists, state: &state, now: now, writer: writer)
        LibrarySyncMerge.compact(&state, retaining: candidate)
        guard state.registers.count <= LibrarySyncCodec.maximumRegisters else { throw LibrarySyncError.tooLarge }
        return state
    }

    static func recordingCheckpoint(_ checkpoint: LibrarySyncCheckpoint, previous: LibraryDocument,
                                    candidate: LibraryDocument, historyWasPruned: Bool, now: Date, writer: UUID,
                                    projectValues: LibrarySyncValueProjection = LibrarySyncProjection.values) throws -> LibrarySyncState? {
        let retained = checkpoint.isRetained(in: candidate)
        guard previous.syncState != nil || retained else { return nil }
        var state = try previous.syncState ?? seed(previous, now: now, writer: writer, projectValues: projectValues)
        if retained {
            let value = try checkpoint.encodedValue()
            let existing = state.registers[checkpoint.key]
            if existing?.value != value || existing?.generation != state.historyReset {
                let revision = try state.nextRevision(now: now, writer: writer)
                state.put(checkpoint.key, value: value, revision: revision)
            }
        }
        if historyWasPruned { LibrarySyncMerge.compactHistory(&state, retaining: candidate) }
        guard state.registers.count <= LibrarySyncCodec.maximumRegisters else { throw LibrarySyncError.tooLarge }
        return state
    }

    static func restoreAggregates(in document: inout LibraryDocument, from state: LibrarySyncState) throws {
        document.releases = Array(document.releases.prefix(LibraryPersistence.releaseLimit))
        LibrarySyncProjection.prunePendingNotifications(in: &document)
        for index in document.followedArtists.indices {
            let id = document.followedArtists[index].id
            if let data = state.registers[LibrarySyncKey(.followMetadata, id)]?.value {
                let metadata = try LibrarySyncCodec.decode(FollowedArtist.self, from: data)
                document.followedArtists[index].knownReleaseIDs = metadata.knownReleaseIDs
                document.followedArtists[index].lastCheckedAt = metadata.lastCheckedAt
                document.followedArtists[index].hasEstablishedReleaseBaseline = metadata.hasEstablishedReleaseBaseline
            }
        }
        for index in document.releases.indices {
            if let data = state.registers[LibrarySyncKey(.releaseSeen, document.releases[index].id)]?.value {
                document.releases[index].seen = try LibrarySyncCodec.decode(Bool.self, from: data)
            }
        }
        document.recentSearches = try LibrarySyncProjection.entries(.search, in: state).compactMap { _, register in
            try register.value.map { try LibrarySyncCodec.decode(String.self, from: $0) }
        }.prefix(SearchHistory.limit).map { $0 }
        document.recentSearchSelections = try LibrarySyncProjection.entries(.searchSelection, in: state).compactMap { _, register in
            try register.value.map { try LibrarySyncCodec.decode(SearchSelection.self, from: $0) }
        }.prefix(SearchHistory.limit).map { $0 }
        let mixOrder = Dictionary(uniqueKeysWithValues: document.mixes.enumerated().map { ($0.element.id, $0.offset) })
        document.mixes = try LibrarySyncProjection.generatedMixes(in: state, excluding: Set(document.disliked.map(\.id))).sorted {
            let a = mixOrder[$0.id, default: Int.max]
            let b = mixOrder[$1.id, default: Int.max]
            return a == b ? $0.id < $1.id : a < b
        }
    }

    private static func positionPlaylists(previous: [UserPlaylist], candidate: [UserPlaylist],
                                          state: inout LibrarySyncState, now: Date, writer: UUID) throws {
        // Membership hides removed songs; retaining their positions keeps concurrent re-adds renderable.
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.tracks.map(\.id)) })
        for playlist in candidate {
            let before = old[playlist.id] ?? []
            let after = playlist.tracks.map(\.id)
            guard before != after else { continue }
            let id = playlist.id.uuidString
            let stable = LibrarySyncPosition.stableIDs(previous: before, candidate: after)
            var positions: [String: LibrarySyncPosition] = [:]
            for trackID in stable {
                guard let data = state.registers[LibrarySyncKey(.playlistPosition, id, member: trackID)]?.value else {
                    throw LibrarySyncError.invalidData("missing saved playlist order")
                }
                positions[trackID] = try LibrarySyncCodec.decode(LibrarySyncPosition.self, from: data)
            }
            var nextStablePositions = Array<LibrarySyncPosition?>(repeating: nil, count: after.count)
            var nextStable: LibrarySyncPosition?
            for index in after.indices.reversed() {
                nextStablePositions[index] = nextStable
                if stable.contains(after[index]) { nextStable = positions[after[index]] }
            }
            var previousPosition: LibrarySyncPosition?
            for (index, trackID) in after.enumerated() {
                if stable.contains(trackID) { previousPosition = positions[trackID]; continue }
                let nextPosition = nextStablePositions[index]
                let revision = try state.nextRevision(now: now, writer: writer)
                let position = try LibrarySyncPosition.between(previousPosition, nextPosition, revision: revision)
                state.put(LibrarySyncKey(.playlistPosition, id, member: trackID), value: try LibrarySyncCodec.encode(position), revision: revision)
                previousPosition = position
            }
        }
    }
}
