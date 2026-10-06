import Foundation

struct LibraryDocument: Codable, Sendable {
    var version = LibraryPersistence.currentVersion
    var favorites: [Track] = []
    /// Super liked recordings, a subset of `favorites` kept in `favorites` order; a super like is still a like.
    var superLikedIDs: [String] = []
    var playlists: [UserPlaylist] = []
    var events: [ListeningEvent] = []
    var lifetimeListening = LifetimeListeningRollup()
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
        case syncState, lifetimeListening, superLikedIDs
    }

    // Fields added after the first release decode leniently so stores written before them still open.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        favorites = try values.decode([Track].self, forKey: .favorites)
        if version >= 5 {
            superLikedIDs = try values.decodeIfPresent([String].self, forKey: .superLikedIDs) ?? []
        } else if values.contains(.superLikedIDs) {
            throw LibraryStorageError.invalidData("super like format version")
        }
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
        if version >= 4 {
            lifetimeListening = try values.decode(LifetimeListeningRollup.self, forKey: .lifetimeListening)
        } else if values.contains(.lifetimeListening) {
            throw LibraryStorageError.invalidData("lifetime format version")
        }
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
    static let currentVersion = 5
    static let fileName = "library.json"
    static let releaseLimit = 60
    // The local file also carries device-only data and the materialized library beside its sync journal.
    static let maximumFileBytes = 128 * 1024 * 1024

    struct VersionHeader: Decodable {
        var version: Int
    }

    // One parse checks the version before any field decoding, with the same errors as a separate header pass.
    private struct VersionedDocument: Decodable {
        let version: Int
        let document: LibraryDocument

        init(from decoder: any Decoder) throws {
            version = try VersionHeader(from: decoder).version
            guard version <= LibraryPersistence.currentVersion else { throw LibraryStorageError.newerVersion }
            guard (1...LibraryPersistence.currentVersion).contains(version) else { throw LibraryStorageError.unsupportedVersion }
            document = try LibraryDocument(from: decoder)
        }
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

    /// Reads bytes with the stamp they were read under; nil when the file changed during the read.
    static func readStamped(_ url: URL) throws -> (data: Data?, stamp: LibraryFileStamp?) {
        let before = LibraryFileStamp(url)
        guard let data = try read(url) else { return (nil, nil) }
        let after = LibraryFileStamp(url)
        return (data, before != nil && before == after ? after : nil)
    }

    enum Fence: String, Sendable {
        case metadata, content
    }

    /// Throws `changedOnDisk` unless the file still holds `expected`. Unchanged metadata proves it without a read;
    /// any metadata difference or an unavailable stamp falls back to the exact byte comparison.
    static func verify(_ url: URL, expected: Data?, stamp: inout LibraryFileStamp?) throws -> Fence {
        if let recorded = stamp, LibraryFileStamp(url) == recorded { return .metadata }
        stamp = nil
        let current = try readStamped(url)
        guard current.data == expected else { throw LibraryStorageError.changedOnDisk }
        stamp = current.stamp
        return .content
    }

    /// Atomically installs `data` through a same-directory temporary file. The returned stamp is nil unless the
    /// installed inode is provably the one written here, so a racing writer can only cost a later content read.
    static func replace(_ data: Data, at url: URL) throws -> LibraryFileStamp? {
        guard data.count <= maximumFileBytes else { throw LibraryStorageError.tooLarge }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            #if os(iOS)
            try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: temporary, options: .withoutOverwriting)
            #endif
            let written = LibraryFileStamp(temporary)
            let failure = temporary.withUnsafeFileSystemRepresentation { source -> Int32? in
                url.withUnsafeFileSystemRepresentation { destination -> Int32? in
                    guard let source, let destination else { return EINVAL }
                    return rename(source, destination) == 0 ? nil : errno
                }
            }
            if let failure { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
            guard let written, let installed = LibraryFileStamp(url), installed.isSameWrite(as: written) else { return nil }
            return installed
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func decode(_ data: Data, now: Date) throws -> LibraryDocument {
        guard data.count <= maximumFileBytes else { throw LibraryStorageError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let versioned = try decoder.decode(VersionedDocument.self, from: data)
        let version = versioned.version
        var document = versioned.document
        if version < 3, !document.recentSearchSelections.isEmpty {
            throw LibraryStorageError.invalidData("search selection format version")
        }
        // Migration is committed with the next real edit or sync preparation, never over an unvalidated file.
        document.version = currentVersion
        try LibraryValidation.validate(document, now: now)
        var rawObject: [String: Any]?? = nil
        func raw() throws -> [String: Any]? {
            if let rawObject { return rawObject }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            rawObject = .some(object)
            return object
        }
        if !document.recentSearchSelections.isEmpty {
            guard let object = try raw(), let payload = object["recentSearchSelections"] else {
                throw LibraryStorageError.invalidData("search selection payload")
            }
            try LibraryValidation.validateSearchSelectionPayload(payload, matching: document.recentSearchSelections)
        }
        if version >= 4 {
            guard let object = try raw(), let payload = object["lifetimeListening"] else {
                throw LibraryStorageError.invalidData("lifetime payload")
            }
            try LibraryValidation.validateCanonicalPayload(payload, matching: document.lifetimeListening, context: "lifetime payload")
        }
        if let state = document.syncState { try LibrarySyncValidation.validate(state, now: now) }
        for event in document.events { try document.lifetimeListening.include(event) }
        if var state = document.syncState {
            try LibraryLifetimeSync.migrateLegacy(&state)
            document.syncState = state
        }
        try document.lifetimeListening.validate()
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
        _ = try replace(data, at: url)
    }
}

/// File identity and change times; ctime cannot be set by other writers, so equal stamps mean untouched bytes.
struct LibraryFileStamp: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    /// Nil for a missing, non-regular or unreadable entry; callers then compare content.
    init?(_ url: URL) {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        guard status == 0, mode_t(info.st_mode) & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = Int(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int(info.st_mtimespec.tv_nsec)
        changedSeconds = Int(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int(info.st_ctimespec.tv_nsec)
    }

    // Rename may update ctime, so the installed file is matched to the written one without it.
    func isSameWrite(as written: Self) -> Bool {
        device == written.device && inode == written.inode && size == written.size
            && modifiedSeconds == written.modifiedSeconds && modifiedNanoseconds == written.modifiedNanoseconds
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
            "Velvet Thorn couldn’t open its local storage folder. Your saved library has not been changed."
        case .newerVersion:
            "This library was saved by a newer version of Velvet Thorn. Update the app to open it. Your saved file has been kept."
        case .unsupportedVersion:
            "This library uses an unsupported format. Your saved file has been kept and has not been replaced."
        case .invalidData(let detail):
            "The library contains invalid \(detail). Your saved file has not been changed."
        case .changedOnDisk:
            "Your saved library changed outside this session. Reload the saved library to use those changes. The saved file has not been replaced."
        case .missingFile:
            "The saved library couldn’t be found. Restore the file before reloading it. No replacement file has been created."
        case .tooLarge:
            "The saved library exceeds Velvet Thorn’s safe storage size limit. The original file has been kept."
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
        try validateCanonicalPayload(raw, matching: value, context: "search selection payload")
    }

    static func validateCanonicalPayload<Value: Encodable>(_ raw: Any, matching value: Value, context: String) throws {
        let expected = try JSONSerialization.jsonObject(with: LibrarySyncCodec.encode(value))
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        // Unknown metadata must not survive in journal bytes while the typed projection silently discards it.
        guard JSONSerialization.isValidJSONObject(raw),
              try JSONSerialization.data(withJSONObject: raw, options: options)
                == JSONSerialization.data(withJSONObject: expected, options: options) else {
            throw LibraryStorageError.invalidData(context)
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
        try document.lifetimeListening.validate()
        try validateUniqueTracks(document.favorites)
        guard Set(document.favorites.map(\.id)).isDisjoint(with: document.disliked.map(\.id)) else {
            throw LibraryStorageError.invalidData("conflicting song reactions")
        }
        try validateSuperLikes(document.superLikedIDs, favorites: document.favorites)
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

    /// The ids stay a subset of favorites in favorites order so one favorites array remains the single like list.
    static func validateSuperLikes(_ ids: [String], favorites: [Track]) throws {
        let superLiked = Set(ids)
        guard superLiked.count == ids.count, superLiked.isSubset(of: favorites.map(\.id)) else {
            throw LibraryStorageError.invalidData("super liked songs")
        }
        guard favorites.map(\.id).filter(superLiked.contains) == ids else {
            throw LibraryStorageError.invalidData("super liked song order")
        }
    }
}
