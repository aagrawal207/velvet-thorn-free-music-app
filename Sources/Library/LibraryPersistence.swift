import Foundation

struct LibraryDocument: Codable, Sendable {
    var version = LibraryPersistence.currentVersion
    var favorites: [Track] = []
    var playlists: [UserPlaylist] = []
    var events: [ListeningEvent] = []
    var recentlyPlayed: [RecentListen] = []
    var recentSearches: [String] = []
    var recentSearchSelections: [SearchSelection] = []
    var playback = PlaybackSnapshot()
    var preferences = UserPreferences()
    var lyricsOffsets: [String: TimeInterval] = [:]
    var followedArtists: [FollowedArtist] = []
    var releases: [ArtistRelease] = []
    var mixes: [GeneratedPlaylist] = []
    var disliked: [DislikedSong] = []
    var tipTransactions: [String: Bool] = [:]
    var recordingLanguageOverrides: [String: String] = [:]
    var listeningHistoryEpoch: UUID?
    var pendingReleaseNotificationIDs: [String] = []
    var syncState: LibrarySyncState?

    init() { }

    private enum CodingKeys: String, CodingKey {
        case version, favorites, playlists, events, recentlyPlayed, playback, preferences, lyricsOffsets
        case followedArtists, releases, mixes, disliked, recentSearches, recentSearchSelections
        case tipTransactions, recordingLanguageOverrides
        case listeningHistoryEpoch, pendingReleaseNotificationIDs
        case syncState
    }

    // Fields added after the first release decode leniently so stores written before them still open.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        favorites = try values.decode([Track].self, forKey: .favorites)
        playlists = try values.decode([UserPlaylist].self, forKey: .playlists)
        events = try values.decode([ListeningEvent].self, forKey: .events)
        recentlyPlayed = try values.decode([RecentListen].self, forKey: .recentlyPlayed)
        recentSearches = try values.decodeIfPresent([String].self, forKey: .recentSearches) ?? []
        recentSearchSelections = try values.decodeIfPresent([SearchSelection].self, forKey: .recentSearchSelections) ?? []
        playback = try values.decode(PlaybackSnapshot.self, forKey: .playback)
        preferences = try values.decode(UserPreferences.self, forKey: .preferences)
        lyricsOffsets = try values.decode([String: TimeInterval].self, forKey: .lyricsOffsets)
        followedArtists = try values.decodeIfPresent([FollowedArtist].self, forKey: .followedArtists) ?? []
        releases = try values.decodeIfPresent([ArtistRelease].self, forKey: .releases) ?? []
        mixes = try values.decodeIfPresent([GeneratedPlaylist].self, forKey: .mixes) ?? []
        disliked = try values.decodeIfPresent([DislikedSong].self, forKey: .disliked) ?? []
        tipTransactions = try values.decodeIfPresent([String: Bool].self, forKey: .tipTransactions) ?? [:]
        recordingLanguageOverrides = try values.decodeIfPresent([String: String].self, forKey: .recordingLanguageOverrides) ?? [:]
        listeningHistoryEpoch = try values.decodeIfPresent(UUID.self, forKey: .listeningHistoryEpoch)
        pendingReleaseNotificationIDs = try values.decodeIfPresent([String].self, forKey: .pendingReleaseNotificationIDs) ?? []
        syncState = try values.decodeIfPresent(LibrarySyncState.self, forKey: .syncState)
    }
}

enum SearchHistory {
    static let limit = 20

    // History preserves punctuation because distinct queries can have the same catalog relevance key.
    static func key(_ query: String) -> String {
        query.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum LibraryPersistence {
    static let currentVersion = 3
    static let fileName = "library.json"
    static let releaseLimit = 60
    // The local file also carries device-only data and the materialized library beside its sync journal.
    static let maximumFileBytes = 128 * 1024 * 1024

    struct VersionHeader: Decodable {
        var version: Int
    }

    static func directory(_ supplied: URL?) throws -> URL {
        if let supplied {
            guard supplied.isFileURL else { throw LibraryStorageError.invalidDirectory }
            return supplied
        }
        return try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("GanaBajana", isDirectory: true)
    }

    static func read(_ url: URL) throws -> Data? {
        var url = url
        url.removeAllCachedResourceValues()
        do {
            let resources = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard resources.isRegularFile == true, resources.isSymbolicLink != true else {
                throw LibraryStorageError.invalidData("library file type")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while let chunk = try handle.read(upToCount: min(1024 * 1024, maximumFileBytes - data.count + 1)), !chunk.isEmpty {
                guard chunk.count <= maximumFileBytes - data.count else { throw LibraryStorageError.tooLarge }
                data.append(chunk)
            }
            return data
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        }
    }

    static func decode(_ data: Data, now: Date) throws -> LibraryDocument {
        guard data.count <= maximumFileBytes else { throw LibraryStorageError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let version = try decoder.decode(VersionHeader.self, from: data).version
        guard version <= currentVersion else { throw LibraryStorageError.newerVersion }
        guard (1...currentVersion).contains(version) else { throw LibraryStorageError.unsupportedVersion }
        var document = try decoder.decode(LibraryDocument.self, from: data)
        if version < 3, !document.recentSearchSelections.isEmpty {
            throw LibraryStorageError.invalidData("search selection format version")
        }
        // Migration is committed with the next real edit or sync preparation, never over an unvalidated file.
        document.version = currentVersion
        try LibraryValidation.validate(document, now: now)
        if !document.recentSearchSelections.isEmpty {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["recentSearchSelections"] else {
                throw LibraryStorageError.invalidData("search selection payload")
            }
            try LibraryValidation.validateSearchSelectionPayload(payload, matching: document.recentSearchSelections)
        }
        try LibrarySyncValidation.validateLocal(document, now: now)
        return document
    }

    static func encode(_ document: LibraryDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    static func write(_ data: Data, to url: URL, replacing expected: Data?) throws {
        guard data.count <= maximumFileBytes else { throw LibraryStorageError.tooLarge }
        // A stale store must not replace another session's library or an externally recovered file.
        guard try read(url) == expected else { throw LibraryStorageError.changedOnDisk }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}

enum LibraryStorageError: LocalizedError {
    case invalidDirectory
    case newerVersion
    case unsupportedVersion
    case invalidData(String)
    case changedOnDisk
    case missingFile
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "Breezy couldn’t open its local storage folder. Your saved library has not been changed."
        case .newerVersion:
            "This library was saved by a newer version of Breezy. Update the app to open it. Your saved file has been kept."
        case .unsupportedVersion:
            "This library uses an unsupported format. Your saved file has been kept and has not been replaced."
        case .invalidData(let detail):
            "The library contains invalid \(detail). Your saved file has not been changed."
        case .changedOnDisk:
            "Your saved library changed outside this session. Reload the saved library to use those changes. The saved file has not been replaced."
        case .missingFile:
            "The saved library couldn’t be found. Restore the file before reloading it. No replacement file has been created."
        case .tooLarge:
            "The saved library exceeds Breezy’s safe storage size limit. The original file has been kept."
        }
    }
}

enum LibraryValidation {
    static func isValidID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isValidDate(_ value: Date) -> Bool {
        let timestamp = value.timeIntervalSince1970
        // Wall clocks can move backwards; stored timestamps need only fit calendar years 1970...9999.
        return timestamp.isFinite && timestamp >= 0 && timestamp < 253_402_300_800
    }

    static func isValidListeningSeconds(_ value: TimeInterval, now: Date) -> Bool {
        // Listening dates start at the Unix epoch; a session cannot exceed that entire date range.
        value.isFinite && value > 0 && value <= now.timeIntervalSince1970
    }

    static func validateTrack(_ track: Track) throws {
        guard isValidID(track.id), isValidID(track.title) else {
            throw LibraryStorageError.invalidData("song details")
        }
        if let duration = track.duration, !duration.isFinite || duration <= 0 {
            throw LibraryStorageError.invalidData("song duration")
        }
    }

    static func isValidSearchSelectionID(_ id: String) -> Bool {
        guard id.utf8.count <= 16_384 else { return false }
        let rawID: Substring
        if id.hasPrefix("track:") {
            rawID = id.dropFirst("track:".count)
        } else if id.hasPrefix("collection:") {
            let parts = id.dropFirst("collection:".count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, CollectionKind(rawValue: String(parts[0])) != nil else { return false }
            rawID = parts[1]
        } else {
            return false
        }
        let providerID = String(rawID)
        return isValidID(providerID) && providerID == providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            && providerID.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func validateSearchSelection(_ selection: SearchSelection) throws {
        guard isValidSearchSelectionID(selection.id), isValidID(selection.title) else {
            throw LibraryStorageError.invalidData("search selection identity")
        }
        switch selection {
        case .track(let track): try validateTrack(track)
        case .collection(let collection):
            guard collection.tracks.isEmpty else { throw LibraryStorageError.invalidData("search selection song snapshot") }
        }
        if let url = selection.artworkURL {
            let host = url.host?.lowercased() ?? ""
            guard url.scheme?.lowercased() == "https", !host.isEmpty, url.user == nil, url.password == nil,
                  host != "googlevideo.com", !host.hasSuffix(".googlevideo.com"), url.path != "/videoplayback" else {
                throw LibraryStorageError.invalidData("search selection artwork")
            }
        }
    }

    static func validateSearchSelectionPayload<Value: Encodable>(_ raw: Any, matching value: Value) throws {
        let expected = try JSONSerialization.jsonObject(with: LibrarySyncCodec.encode(value))
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        // Unknown metadata must not survive in journal bytes while the typed projection silently discards it.
        guard JSONSerialization.isValidJSONObject(raw),
              try JSONSerialization.data(withJSONObject: raw, options: options)
                == JSONSerialization.data(withJSONObject: expected, options: options) else {
            throw LibraryStorageError.invalidData("search selection payload")
        }
    }

    static func validatePosition(_ position: TimeInterval) throws {
        // Catalog duration is not the resolved recording's duration; it must not truncate resume state.
        guard position.isFinite, position >= 0, PlaybackTiming.position(position) == position else {
            throw LibraryStorageError.invalidData("playback position")
        }
    }

    static func validatePlayback(_ snapshot: PlaybackSnapshot) throws {
        try snapshot.queue.forEach(validateTrack)
        if let original = snapshot.originalQueue {
            try original.forEach(validateTrack)
            let currentCounts = snapshot.queue.reduce(into: [String: Int]()) { $0[$1.id, default: 0] += 1 }
            let originalCounts = original.reduce(into: [String: Int]()) { $0[$1.id, default: 0] += 1 }
            guard originalCounts == currentCounts else {
                throw LibraryStorageError.invalidData("original queue contents")
            }
        }
        try validateOriginalQueueIndices(snapshot)
        if snapshot.queue.isEmpty {
            guard snapshot.currentIndex == 0, snapshot.position == 0 else {
                throw LibraryStorageError.invalidData("empty queue position")
            }
        } else {
            guard snapshot.queue.indices.contains(snapshot.currentIndex) else {
                throw LibraryStorageError.invalidData("queue selection")
            }
            try validatePosition(snapshot.position)
        }
    }

    static func validateOriginalQueueIndices(_ snapshot: PlaybackSnapshot) throws {
        guard let indices = snapshot.originalQueueIndices else { return }
        guard let original = snapshot.originalQueue, original.count == snapshot.queue.count,
              indices.count == snapshot.queue.count else {
            throw LibraryStorageError.invalidData("original queue occurrence mapping")
        }
        var seen = Set<Int>()
        for (queueIndex, originalIndex) in indices.enumerated() {
            // An unshuffled snapshot is already in original occurrence order, even when Track values are identical.
            guard original.indices.contains(originalIndex), seen.insert(originalIndex).inserted,
                  snapshot.queue[queueIndex].id == original[originalIndex].id,
                  snapshot.shuffleEnabled || queueIndex == originalIndex else {
                throw LibraryStorageError.invalidData("original queue occurrence mapping")
            }
        }
    }

    static func validate(_ document: LibraryDocument, now: Date) throws {
        guard document.version == LibraryPersistence.currentVersion else {
            throw LibraryStorageError.unsupportedVersion
        }
        try validateUniqueTracks(document.favorites)
        guard Set(document.favorites.map(\.id)).isDisjoint(with: document.disliked.map(\.id)) else {
            throw LibraryStorageError.invalidData("conflicting song reactions")
        }
        guard Set(document.playlists.map(\.id)).count == document.playlists.count else {
            throw LibraryStorageError.invalidData("duplicate playlists")
        }
        for playlist in document.playlists {
            guard isValidID(playlist.name),
                  isValidDate(playlist.createdAt),
                  isValidDate(playlist.updatedAt),
                  playlist.updatedAt >= playlist.createdAt else {
                throw LibraryStorageError.invalidData("playlist details")
            }
            try validateUniqueTracks(playlist.tracks)
        }
        guard Set(document.events.map(\.id)).count == document.events.count else {
            throw LibraryStorageError.invalidData("duplicate listening sessions")
        }
        for event in document.events {
            try validateTrack(event.track)
            guard isValidDate(event.startedAt),
                  isValidListeningSeconds(event.listenedSeconds, now: now) else {
                throw LibraryStorageError.invalidData("listening history")
            }
        }
        guard Set(document.recentlyPlayed.map(\.id)).count == document.recentlyPlayed.count else {
            throw LibraryStorageError.invalidData("duplicate recent songs")
        }
        for recent in document.recentlyPlayed {
            try validateTrack(recent.track)
            try validatePosition(recent.position)
            guard isValidDate(recent.playedAt) else {
                throw LibraryStorageError.invalidData("recent listening dates")
            }
        }
        guard document.recentSearches.count <= SearchHistory.limit,
              document.recentSearches.allSatisfy({
                  isValidID($0) && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                      && isValidID(SearchHistory.key($0)) && SearchHistory.key($0).utf8.count <= 16_384
              }),
              Set(document.recentSearches.map(SearchHistory.key)).count == document.recentSearches.count else {
            throw LibraryStorageError.invalidData("recent searches")
        }
        guard document.recentSearchSelections.count <= SearchHistory.limit,
              Set(document.recentSearchSelections.map(\.id)).count == document.recentSearchSelections.count else {
            throw LibraryStorageError.invalidData("recent search selections")
        }
        try document.recentSearchSelections.forEach(validateSearchSelection)
        try validatePlayback(document.playback)
        for (trackID, offset) in document.lyricsOffsets {
            guard isValidID(trackID), offset.isFinite, PlaybackTiming.position(abs(offset)) == abs(offset) else {
                throw LibraryStorageError.invalidData("lyrics timing")
            }
        }
        guard Set(document.followedArtists.map(\.id)).count == document.followedArtists.count else {
            throw LibraryStorageError.invalidData("duplicate followed artists")
        }
        for artist in document.followedArtists {
            guard isValidID(artist.id), isValidID(artist.name), isValidDate(artist.followedAt),
                  artist.lastCheckedAt.map(isValidDate) ?? true,
                  artist.knownReleaseIDs.allSatisfy(isValidID) else {
                throw LibraryStorageError.invalidData("followed artist details")
            }
        }
        guard Set(document.releases.map(\.id)).count == document.releases.count else {
            throw LibraryStorageError.invalidData("duplicate releases")
        }
        for release in document.releases {
            guard isValidID(release.id), isValidID(release.title), isValidID(release.artistID),
                  isValidDate(release.discoveredAt) else {
                throw LibraryStorageError.invalidData("release details")
            }
        }
        let releaseIDs = Set(document.releases.map(\.id))
        guard document.pendingReleaseNotificationIDs.count <= LibraryPersistence.releaseLimit,
              Set(document.pendingReleaseNotificationIDs).count == document.pendingReleaseNotificationIDs.count,
              document.pendingReleaseNotificationIDs.allSatisfy({ isValidID($0) && releaseIDs.contains($0) }) else {
            throw LibraryStorageError.invalidData("pending release notifications")
        }
        guard Set(document.mixes.map(\.kind)).count == document.mixes.count else {
            throw LibraryStorageError.invalidData("duplicate mixes")
        }
        for mix in document.mixes {
            guard isValidDate(mix.generatedAt), isValidID(mix.periodKey) else {
                throw LibraryStorageError.invalidData("mix details")
            }
            try validateUniqueTracks(mix.tracks)
        }
        guard Set(document.disliked.map(\.id)).count == document.disliked.count else {
            throw LibraryStorageError.invalidData("duplicate disliked songs")
        }
        for song in document.disliked {
            guard isValidID(song.id), isValidID(song.title), isValidDate(song.dislikedAt) else {
                throw LibraryStorageError.invalidData("disliked song details")
            }
        }
        for id in document.tipTransactions.keys {
            // Canonical decimal keys prevent multiple spellings from crediting the same transaction twice.
            guard !id.isEmpty, let transactionID = UInt64(id), String(transactionID) == id else {
                throw LibraryStorageError.invalidData("tip transaction identifiers")
            }
        }
        for (id, code) in document.recordingLanguageOverrides {
            guard isValidID(id), !code.isEmpty, code.utf8.count <= 64 else {
                throw LibraryStorageError.invalidData("recording language corrections")
            }
        }
    }

    private static func validateUniqueTracks(_ tracks: [Track]) throws {
        guard Set(tracks.map(\.id)).count == tracks.count else {
            throw LibraryStorageError.invalidData("duplicate songs")
        }
        try tracks.forEach(validateTrack)
    }
}
