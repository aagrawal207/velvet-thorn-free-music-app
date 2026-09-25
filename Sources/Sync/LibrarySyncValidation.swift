import Foundation

enum LibrarySyncValidation {
    static func validate(_ state: LibrarySyncState, now: Date) throws {
        guard state.version <= LibrarySyncState.currentVersion else { throw LibrarySyncError.newerVersion }
        guard state.version == LibrarySyncState.currentVersion else { throw LibrarySyncError.unsupportedVersion }
        guard state.registers.count <= LibrarySyncCodec.maximumRegisters else { throw LibrarySyncError.tooLarge }
        try state.clock?.validate()
        for boundary in [state.historyReset, state.historyRetirement, state.searchReset,
                         state.searchFloor?.revision, state.searchSelectionFloor?.revision].compactMap({ $0 }) {
            try validateRevision(boundary, clock: state.clock)
        }
        if let floor = state.searchFloor {
            guard LibraryValidation.isValidID(floor.key), SearchHistory.key(floor.key) == floor.key,
                  state.searchReset.map({ floor.revision >= $0 }) ?? true else {
                throw LibrarySyncError.invalidData("search retention boundary")
            }
        }
        if let floor = state.searchSelectionFloor {
            guard LibraryValidation.isValidSearchSelectionID(floor.key),
                  state.searchReset.map({ floor.revision >= $0 }) ?? true else {
                throw LibrarySyncError.invalidData("search selection retention boundary")
            }
        }
        let preferences = try LibrarySyncPreferences.fields(UserPreferences())
        var preferenceValues: [String: Data] = [:]
        for (key, register) in state.registers {
            guard LibraryValidation.isValidID(key.id), key.id.utf8.count <= 16_384 else {
                throw LibrarySyncError.invalidData("mutation key")
            }
            if key.collection == .searchSelection, !LibraryValidation.isValidSearchSelectionID(key.id) {
                throw LibrarySyncError.invalidData("search selection key")
            }
            try validateRevision(register.revision, clock: state.clock)
            if let generation = register.generation {
                try validateRevision(generation, clock: register.revision)
                let boundary = key.collection.isHistory ? state.historyReset : key.collection.isSearchHistory ? state.searchReset : nil
                guard let boundary, generation <= boundary else { throw LibrarySyncError.invalidData("reset generation") }
            }
            let hasMember = key.collection == .playlistTrack || key.collection == .playlistTrackMetadata || key.collection == .playlistPosition
            guard hasMember == (key.member != nil),
                  key.member.map({ LibraryValidation.isValidID($0) && $0.utf8.count <= 16_384 }) ?? true else {
                throw LibrarySyncError.invalidData("playlist member key")
            }
            if key.collection == .playlist || key.collection.isPlaylistChild || key.collection == .event {
                guard UUID(uuidString: key.id)?.uuidString == key.id else { throw LibrarySyncError.invalidData("canonical UUID") }
            }
            if key.collection.isPlaylistChild, state.registers[LibrarySyncKey(.playlist, key.id)] == nil {
                throw LibrarySyncError.invalidData("orphaned playlist field")
            }
            if key.collection == .playlistPosition || key.collection == .playlistTrackMetadata,
               state.registers[LibrarySyncKey(.playlistTrack, key.id, member: key.member)] == nil {
                throw LibrarySyncError.invalidData("orphaned playlist song metadata")
            }
            if key.collection == .preference {
                guard let fallback = preferences[key.id] else { throw LibrarySyncError.newerVersion }
                preferenceValues[key.id] = register.value ?? fallback
            }
            guard let value = register.value else {
                guard key.collection != .event, key.collection != .followMetadata,
                      key.collection != .releaseSeen, key.collection != .playlistUpdated else {
                    throw LibrarySyncError.invalidData("aggregate tombstone")
                }
                continue
            }
            guard value.count <= LibrarySyncCodec.maximumFileBytes else { throw LibrarySyncError.tooLarge }
            try validateValue(value, key: key, now: now)
        }
        _ = try LibrarySyncPreferences.applying(preferenceValues, to: UserPreferences())
        var canonical = state
        LibrarySyncMerge.discardObsoleteGenerations(&canonical)
        let projected = try LibrarySyncProjection.materialize(canonical, onto: LibraryDocument(), now: now, applyRetention: false)
        try LibraryValidation.validate(projected, now: now)
    }

    static func validateLocal(_ document: LibraryDocument, now: Date) throws {
        guard let state = document.syncState else { return }
        try validate(state, now: now)
        let projected = try LibrarySyncProjection.materialize(state, onto: document, now: now, applyRetention: false)
        guard try LibrarySyncProjection.values(projected) == LibrarySyncProjection.values(document),
              Dictionary(uniqueKeysWithValues: projected.playlists.map { ($0.id, $0.tracks.map(\.id)) })
                == Dictionary(uniqueKeysWithValues: document.playlists.map { ($0.id, $0.tracks.map(\.id)) }),
              projected.recentSearches == document.recentSearches,
              projected.recentSearchSelections == document.recentSearchSelections else {
            throw LibraryStorageError.invalidData("sync journal and saved library consistency")
        }
    }

    private static func validateRevision(_ revision: LibrarySyncRevision, clock: LibrarySyncRevision?) throws {
        try revision.validate()
        guard let clock, revision <= clock else { throw LibrarySyncError.invalidData("mutation clock") }
    }

    private static func validateValue(_ value: Data, key: LibrarySyncKey, now: Date) throws {
        var document = LibraryDocument()
        switch key.collection {
        case .preference: return
        case .reaction:
            switch try LibrarySyncCodec.decode(LibrarySyncReaction.self, from: value) {
            case .liked(let track):
                guard track.id == key.id else { throw LibrarySyncError.invalidData("liked song identity") }
                document.favorites = [track]
            case .disliked(let song):
                guard song.id == key.id else { throw LibrarySyncError.invalidData("disliked song identity") }
                document.disliked = [song]
            }
        case .playlist, .playlistUpdated:
            guard LibraryValidation.isValidDate(try LibrarySyncCodec.decode(Date.self, from: value)) else {
                throw LibrarySyncError.invalidData("playlist date")
            }
        case .playlistName:
            guard LibraryValidation.isValidID(try LibrarySyncCodec.decode(String.self, from: value)) else {
                throw LibrarySyncError.invalidData("playlist name")
            }
        case .playlistTrack, .playlistTrackMetadata:
            let track = try LibrarySyncCodec.decode(Track.self, from: value)
            guard track.id == key.member else { throw LibrarySyncError.invalidData("playlist song identity") }
            try LibraryValidation.validateTrack(track)
        case .playlistPosition:
            let position = try LibrarySyncCodec.decode(LibrarySyncPosition.self, from: value)
            guard !position.digits.isEmpty, position.digits.count <= LibrarySyncPosition.maximumDepth,
                  position.digits.last != 0 else { throw LibrarySyncError.invalidData("playlist position") }
        case .follow, .followMetadata:
            let artist = try LibrarySyncCodec.decode(FollowedArtist.self, from: value)
            guard artist.id == key.id else { throw LibrarySyncError.invalidData("followed artist identity") }
            document.followedArtists = [artist]
        case .release:
            let release = try LibrarySyncCodec.decode(ArtistRelease.self, from: value)
            guard release.id == key.id else { throw LibrarySyncError.invalidData("release identity") }
            document.releases = [release]
        case .releaseSeen:
            _ = try LibrarySyncCodec.decode(Bool.self, from: value)
        case .event:
            let event = try LibrarySyncCodec.decode(ListeningEvent.self, from: value)
            guard event.id.uuidString == key.id else { throw LibrarySyncError.invalidData("listening session identity") }
            document.events = [event]
        case .recent:
            let recent = try LibrarySyncCodec.decode(RecentListen.self, from: value)
            guard recent.id == key.id else { throw LibrarySyncError.invalidData("recent song identity") }
            document.recentlyPlayed = [recent]
        case .search:
            let query = try LibrarySyncCodec.decode(String.self, from: value)
            guard SearchHistory.key(query) == key.id else { throw LibrarySyncError.invalidData("search identity") }
            document.recentSearches = [query]
        case .searchSelection:
            let selection = try LibrarySyncCodec.decode(SearchSelection.self, from: value)
            guard selection.id == key.id else { throw LibrarySyncError.invalidData("search selection identity") }
            try LibraryValidation.validateSearchSelectionPayload(JSONSerialization.jsonObject(with: value), matching: selection)
            document.recentSearchSelections = [selection]
        case .mix:
            let mix = try LibrarySyncCodec.decode(GeneratedPlaylist.self, from: value)
            guard mix.id == key.id else { throw LibrarySyncError.invalidData("generated mix identity") }
            document.mixes = [mix]
        case .language:
            document.recordingLanguageOverrides = [key.id: try LibrarySyncCodec.decode(String.self, from: value)]
        case .lyrics:
            document.lyricsOffsets = [key.id: try LibrarySyncCodec.decode(Double.self, from: value)]
        }
        try LibraryValidation.validate(document, now: now)
    }
}
