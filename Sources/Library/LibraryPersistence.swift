import Foundation

struct LibraryDocument: Codable {
    var version = LibraryPersistence.currentVersion
    var favorites: [Track] = []
    var playlists: [UserPlaylist] = []
    var events: [ListeningEvent] = []
    var recentlyPlayed: [RecentListen] = []
    var recentSearches: [String] = []
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

    init() { }

    private enum CodingKeys: String, CodingKey {
        case version, favorites, playlists, events, recentlyPlayed, playback, preferences, lyricsOffsets
        case followedArtists, releases, mixes, disliked, recentSearches
        case tipTransactions, recordingLanguageOverrides
        case listeningHistoryEpoch, pendingReleaseNotificationIDs
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
    static let currentVersion = 1
    static let fileName = "library.json"
    static let releaseLimit = 60

    private struct VersionHeader: Decodable {
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
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    static func decode(_ data: Data, now: Date) throws -> LibraryDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let version = try decoder.decode(VersionHeader.self, from: data).version
        guard version <= currentVersion else { throw LibraryStorageError.newerVersion }
        guard version == currentVersion else { throw LibraryStorageError.unsupportedVersion }
        let document = try decoder.decode(LibraryDocument.self, from: data)
        try LibraryValidation.validate(document, now: now)
        return document
    }

    static func encode(_ document: LibraryDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    static func write(_ data: Data, to url: URL, replacing expected: Data?) throws {
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

    static func validate(_ document: LibraryDocument, now: Date) throws {
        guard document.version == LibraryPersistence.currentVersion else {
            throw LibraryStorageError.unsupportedVersion
        }
        try validateUniqueTracks(document.favorites)
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
                  !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                      && !SearchHistory.key($0).isEmpty
              }),
              Set(document.recentSearches.map(SearchHistory.key)).count == document.recentSearches.count else {
            throw LibraryStorageError.invalidData("recent searches")
        }
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
    }

    private static func validateUniqueTracks(_ tracks: [Track]) throws {
        guard Set(tracks.map(\.id)).count == tracks.count else {
            throw LibraryStorageError.invalidData("duplicate songs")
        }
        try tracks.forEach(validateTrack)
    }
}
