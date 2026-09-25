import Foundation

typealias LibrarySyncValueProjection = (LibraryDocument) throws -> [LibrarySyncKey: Data]

enum LibrarySyncProjection {
    static func values(_ document: LibraryDocument) throws -> [LibrarySyncKey: Data] {
        var result: [LibrarySyncKey: Data] = [:]
        func put<T: Encodable>(_ collection: LibrarySyncCollection, _ id: String, _ value: T, member: String? = nil) throws {
            guard id.utf8.count <= 16_384, member.map({ $0.utf8.count <= 16_384 }) ?? true else {
                throw LibrarySyncError.invalidData("overly long mutation identifier")
            }
            result[LibrarySyncKey(collection, id, member: member)] = try LibrarySyncCodec.encode(value)
        }
        for (key, value) in try LibrarySyncPreferences.fields(document.preferences) {
            result[LibrarySyncKey(.preference, key)] = value
        }
        for track in document.favorites { try put(.reaction, track.id, LibrarySyncReaction.liked(track)) }
        for song in document.disliked { try put(.reaction, song.id, LibrarySyncReaction.disliked(song)) }
        for playlist in document.playlists {
            let id = playlist.id.uuidString
            try put(.playlist, id, playlist.createdAt)
            try put(.playlistName, id, playlist.name)
            try put(.playlistUpdated, id, playlist.updatedAt)
            for track in playlist.tracks {
                try put(.playlistTrack, id, track, member: track.id)
                try put(.playlistTrackMetadata, id, track, member: track.id)
            }
        }
        for artist in document.followedArtists {
            try put(.follow, artist.id, followIdentity(artist))
            var metadata = artist
            metadata.knownReleaseIDs = Set(artist.knownReleaseIDs).sorted()
            try put(.followMetadata, artist.id, metadata)
        }
        for release in document.releases {
            var metadata = release
            metadata.seen = false
            try put(.release, release.id, metadata)
            try put(.releaseSeen, release.id, release.seen)
        }
        for event in document.events {
            result[LibrarySyncKey(.event, event.id.uuidString)] = try listeningValue(event)
        }
        for recent in document.recentlyPlayed { result[LibrarySyncKey(.recent, recent.id)] = try recentValue(recent) }
        for query in document.recentSearches { try put(.search, SearchHistory.key(query), query) }
        for selection in document.recentSearchSelections { try put(.searchSelection, selection.id, selection) }
        for mix in document.mixes { try put(.mix, mix.id, mix) }
        for (id, code) in document.recordingLanguageOverrides { try put(.language, id, code) }
        for (id, offset) in document.lyricsOffsets { try put(.lyrics, id, offset) }
        return result
    }

    static func listeningValue(_ event: ListeningEvent) throws -> Data {
        var event = event
        let milliseconds = min((event.startedAt.timeIntervalSince1970 * 1000).rounded(), 253_402_300_799_999)
        event.startedAt = Date(timeIntervalSince1970: milliseconds / 1000)
        return try LibrarySyncCodec.encode(event)
    }

    static func recentValue(_ recent: RecentListen) throws -> Data {
        guard recent.id.utf8.count <= 16_384 else { throw LibrarySyncError.invalidData("overly long mutation identifier") }
        return try LibrarySyncCodec.encode(recent)
    }

    static func followIdentity(_ artist: FollowedArtist) -> FollowedArtist {
        var result = artist
        result.knownReleaseIDs = []
        result.lastCheckedAt = nil
        result.hasEstablishedReleaseBaseline = false
        return result
    }

    static func materialize(_ state: LibrarySyncState, onto local: LibraryDocument, now: Date,
                            applyRetention: Bool = true) throws -> LibraryDocument {
        var result = local
        let defaults = try LibrarySyncPreferences.fields(UserPreferences())
        var fields: [String: Data] = [:]
        for (key, register) in state.registers where key.collection == .preference {
            guard let fallback = defaults[key.id] else { throw LibrarySyncError.newerVersion }
            fields[key.id] = register.value ?? fallback
        }
        result.preferences = try LibrarySyncPreferences.applying(fields, to: local.preferences)
        result.favorites = []
        result.disliked = []
        for (_, register) in entries(.reaction, in: state) {
            guard let data = register.value else { continue }
            switch try LibrarySyncCodec.decode(LibrarySyncReaction.self, from: data) {
            case .liked(let track): result.favorites.append(track)
            case .disliked(let song): result.disliked.append(song)
            }
        }
        result.playlists = []
        let trackEntries = Dictionary(grouping: entries(.playlistTrack, in: state), by: { $0.0.id })
        for (key, register) in entries(.playlist, in: state) {
            guard let data = register.value else { continue }
            guard let id = UUID(uuidString: key.id),
                  let nameData = state.registers[LibrarySyncKey(.playlistName, key.id)]?.value,
                  let updatedData = state.registers[LibrarySyncKey(.playlistUpdated, key.id)]?.value else {
                throw LibrarySyncError.invalidData("incomplete playlist")
            }
            var positioned: [(Track, LibrarySyncPosition)] = []
            for (trackKey, trackRegister) in trackEntries[key.id] ?? [] {
                guard let trackData = trackRegister.value else { continue }
                guard let positionData = state.registers[LibrarySyncKey(.playlistPosition, key.id, member: trackKey.member)]?.value else {
                    throw LibrarySyncError.invalidData("missing playlist position")
                }
                let metadata = state.registers[LibrarySyncKey(.playlistTrackMetadata, key.id, member: trackKey.member)]?.value ?? trackData
                positioned.append((try LibrarySyncCodec.decode(Track.self, from: metadata),
                                   try LibrarySyncCodec.decode(LibrarySyncPosition.self, from: positionData)))
            }
            guard Set(positioned.map(\.1)).count == positioned.count else { throw LibrarySyncError.invalidData("duplicate playlist positions") }
            positioned.sort { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 < $1.1 }
            let createdAt = try LibrarySyncCodec.decode(Date.self, from: data)
            result.playlists.append(UserPlaylist(
                id: id, name: try LibrarySyncCodec.decode(String.self, from: nameData), tracks: positioned.map(\.0),
                createdAt: createdAt, updatedAt: max(createdAt, try LibrarySyncCodec.decode(Date.self, from: updatedData))
            ))
        }
        result.followedArtists = []
        for (key, register) in entries(.follow, in: state) {
            guard let data = register.value else { continue }
            var artist = try LibrarySyncCodec.decode(FollowedArtist.self, from: data)
            if let metadata = state.registers[LibrarySyncKey(.followMetadata, key.id)]?.value {
                let check = try LibrarySyncCodec.decode(FollowedArtist.self, from: metadata)
                artist.knownReleaseIDs = check.knownReleaseIDs
                artist.lastCheckedAt = check.lastCheckedAt
                artist.hasEstablishedReleaseBaseline = check.hasEstablishedReleaseBaseline
            }
            result.followedArtists.append(artist)
        }
        result.releases = []
        for (key, register) in entries(.release, in: state) {
            guard let data = register.value else { continue }
            var release = try LibrarySyncCodec.decode(ArtistRelease.self, from: data)
            if let seen = state.registers[LibrarySyncKey(.releaseSeen, key.id)]?.value {
                release.seen = try LibrarySyncCodec.decode(Bool.self, from: seen)
            }
            let membership = state.registers[LibrarySyncKey(.follow, release.artistID)]
            if membership == nil || membership?.value != nil { result.releases.append(release) }
        }
        result.releases.sort { $0.discoveredAt == $1.discoveredAt ? $0.id < $1.id : $0.discoveredAt > $1.discoveredAt }
        result.releases = Array(result.releases.prefix(LibraryPersistence.releaseLimit))
        result.events = try decodedEntries(.event, in: state, as: ListeningEvent.self)
        result.events.sort { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt }
        result.recentlyPlayed = try decodedEntries(.recent, in: state, as: RecentListen.self)
        result.recentlyPlayed.sort { $0.playedAt == $1.playedAt ? $0.id < $1.id : $0.playedAt > $1.playedAt }
        result.recentSearches = Array(try decodedEntries(.search, in: state, as: String.self).prefix(SearchHistory.limit))
        result.recentSearchSelections = Array(try decodedEntries(.searchSelection, in: state, as: SearchSelection.self).prefix(SearchHistory.limit))
        result.mixes = try generatedMixes(in: state, excluding: Set(result.disliked.map(\.id)))
        result.recordingLanguageOverrides = [:]
        for (key, register) in entries(.language, in: state) {
            if let data = register.value { result.recordingLanguageOverrides[key.id] = try LibrarySyncCodec.decode(String.self, from: data) }
        }
        result.lyricsOffsets = [:]
        for (key, register) in entries(.lyrics, in: state) {
            if let data = register.value { result.lyricsOffsets[key.id] = try LibrarySyncCodec.decode(Double.self, from: data) }
        }
        prunePendingNotifications(in: &result)
        if applyRetention { LibraryHistoryRetention.apply(to: &result, now: now) }
        result.syncState = state
        return result
    }

    static func prunePendingNotifications(in document: inout LibraryDocument) {
        let followed = Set(document.followedArtists.map(\.id))
        let eligible = Set(document.releases.filter { followed.contains($0.artistID) }.map(\.id))
        let alertsEnabled = document.preferences.newReleaseAlerts
        document.pendingReleaseNotificationIDs.removeAll { !alertsEnabled || !eligible.contains($0) }
    }

    static func generatedMixes(in state: LibrarySyncState, excluding disliked: Set<String>) throws -> [GeneratedPlaylist] {
        try decodedEntries(.mix, in: state, as: GeneratedPlaylist.self).compactMap { mix in
            var mix = mix
            let hadTracks = !mix.tracks.isEmpty
            mix.tracks.removeAll { disliked.contains($0.id) }
            return hadTracks && mix.tracks.isEmpty ? nil : mix
        }
    }

    static func entries(_ collection: LibrarySyncCollection, in state: LibrarySyncState) -> [(LibrarySyncKey, LibrarySyncRegister)] {
        state.registers.filter { key, register in
            guard key.collection == collection else { return false }
            if collection.isHistory { return register.generation == state.historyReset }
            if collection.isSearchHistory {
                let rank = LibrarySyncSearchBoundary(revision: register.revision, key: key.id)
                let floor = collection == .search ? state.searchFloor : state.searchSelectionFloor
                return register.generation == state.searchReset && (floor.map { rank > $0 } ?? true)
            }
            return true
        }.sorted {
            if $0.value.revision != $1.value.revision { return $0.value.revision > $1.value.revision }
            return $0.key < $1.key
        }.map { ($0.key, $0.value) }
    }

    private static func decodedEntries<T: Decodable>(_ collection: LibrarySyncCollection, in state: LibrarySyncState,
                                                      as type: T.Type) throws -> [T] {
        try entries(collection, in: state).compactMap { _, register in
            try register.value.map { try LibrarySyncCodec.decode(type, from: $0) }
        }
    }
}
