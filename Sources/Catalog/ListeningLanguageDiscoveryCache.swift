import Foundation
import OSLog

actor ListeningLanguageDiscoveryCache {
    static let fileName = "listening-language-cache.json"
    static let maximumFileBytes = 2 * 1024 * 1024
    static let maximumEntries = 512
    static let positiveLifetime: TimeInterval = 12 * 60 * 60
    static let negativeLifetime: TimeInterval = 5 * 60

    enum Status: Int, Sendable {
        case memoryOnly, notLoaded, missing, loaded, saved, ignored, failed, cleared, superseded
    }

    struct Entry: Codable, Equatable, Sendable {
        let key: LyricsRequestKey
        let result: ArtistSongLanguageResult
        let checkedAt: Date
        let expiresAt: Date

        func isReusable(at now: Date) -> Bool { checkedAt <= now && now < expiresAt }
    }

    struct Load: Sendable {
        let entries: [Entry]
        let status: Status
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let entries: [Entry]

        init(entries: [Entry]) {
            schemaVersion = 1
            self.entries = entries
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, entries }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == 1 else { throw CacheError.invalidData }
            var items = try values.nestedUnkeyedContainer(forKey: .entries)
            guard (items.count ?? 0) <= maximumEntries else { throw CacheError.invalidData }
            var decoded: [Entry] = []
            while !items.isAtEnd {
                guard decoded.count < maximumEntries else { throw CacheError.invalidData }
                decoded.append(try items.decode(Entry.self))
            }
            entries = decoded
        }
    }

    private enum CacheError: Error { case invalidData }

    private let url: URL
    private var latestRevision: UInt64 = 0
    private var loaded: Load?
    private var expected: Data?
    private var writable = false

    init(url: URL) { self.url = url.isFileURL ? url.standardizedFileURL : url }

    func load() -> Load {
        if let loaded { return loaded }
        let data: Data?
        do { data = try read() }
        catch {
            let status: Status = error is LibrarySyncError || error is CacheError ? .ignored : .failed
            return finishLoad([], status: status)
        }
        guard let data else {
            writable = true
            return finishLoad([], status: .missing)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let document = try decoder.decode(Document.self, from: data)
            guard Self.validEntries(document.entries) else { throw CacheError.invalidData }
            expected = data
            writable = true
            return finishLoad(document.entries, status: .loaded)
        } catch {
            // An unreadable or future cache is not permission to replace somebody else's bytes.
            return finishLoad([], status: .ignored)
        }
    }

    func save(_ entries: [Entry], revision: UInt64) -> Status {
        guard revision > latestRevision else { return record(.superseded, write: 1) }
        latestRevision = revision
        guard !Task.isCancelled else { return record(.superseded, write: 1) }
        let initial = load()
        guard writable else { return record(initial.status, write: 1) }
        guard Self.validEntries(entries) else { return record(.failed, write: 1) }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(entries: entries))
            guard data.count <= Self.maximumFileBytes else { return record(.failed, write: 1) }
            guard try read() == expected else {
                writable = false
                loaded = Load(entries: [], status: .ignored)
                return record(.ignored, write: 1)
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            expected = data
            loaded = Load(entries: entries, status: .loaded)
            var localURL = url
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try localURL.setResourceValues(resources)
            return record(.saved, write: 1, count: entries.count)
        } catch is CancellationError {
            return record(.superseded, write: 1)
        } catch {
            return record(.failed, write: 1)
        }
    }

    func reset(revision: UInt64) -> Status {
        guard revision > latestRevision else { return record(.superseded, reset: 1) }
        latestRevision = revision
        loaded = Load(entries: [], status: .failed)
        writable = false
        do {
            try validateURL()
            var file = url
            file.removeAllCachedResourceValues()
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      values.isUbiquitousItem != true else { throw CacheError.invalidData }
                try FileManager.default.removeItem(at: file)
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { }
            expected = nil
            writable = true
            loaded = Load(entries: [], status: .missing)
            return record(.cleared, reset: 1)
        } catch {
            return record(.failed, reset: 1)
        }
    }

    nonisolated static func accepts(_ key: LyricsRequestKey) -> Bool {
        let recording = key.recording
        guard validString(key.id, maximum: 512), validString(recording.title, maximum: 2_048),
              (recording.album.isEmpty || validString(recording.album, maximum: 2_048)), recording.artists.count <= 32,
              recording.artists.allSatisfy({ validString($0, maximum: 512) }),
              recording.duration.map({ LyricsMatcher.validDuration($0) == $0 }) ?? true else { return false }
        let bytes = key.id.utf8.count + recording.title.utf8.count + recording.album.utf8.count
            + recording.artists.reduce(0) { $0 + $1.utf8.count }
        return bytes <= 3_072
    }

    nonisolated static func accepts(_ result: ArtistSongLanguageResult) -> Bool {
        switch result {
        case .identified(_, .matchedLyrics), .identified(_, .linkedLyrics), .identified(_, .youTubeAudioLanguage),
             .likely(_, .lyricsScript), .likely(_, .titleLabel), .likely(_, .titleScript): true
        case .identified(_, .musicBrainzWork(let recordingID, let workID)):
            UUID(uuidString: recordingID) != nil && UUID(uuidString: workID) != nil
        case .unclassified(let reason): reason != .userOverride
        default: false
        }
    }

    private nonisolated static func validEntries(_ entries: [Entry]) -> Bool {
        guard entries.count <= maximumEntries, Set(entries.map(\.key)).count == entries.count else { return false }
        return entries.allSatisfy { entry in
            let lifetime = entry.expiresAt.timeIntervalSince(entry.checkedAt)
            let maximum = entry.result.language == nil ? negativeLifetime : positiveLifetime
            return accepts(entry.key) && accepts(entry.result)
                && (entry.result.source != .youTubeAudioLanguage || CatalogText.videoID(entry.key.id) != nil)
                && LibraryValidation.isValidDate(entry.checkedAt) && LibraryValidation.isValidDate(entry.expiresAt)
                && lifetime > 0 && lifetime <= maximum + 0.001
        }
    }

    private nonisolated static func validString(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum && LibraryValidation.isValidID(value)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func validateURL() throws {
        guard url.isFileURL, !url.hasDirectoryPath,
              url.lastPathComponent.caseInsensitiveCompare(LibraryPersistence.fileName) != .orderedSame else {
            throw CacheError.invalidData
        }
    }

    private func read() throws -> Data? {
        try validateURL()
        do {
            var file = url
            file.removeAllCachedResourceValues()
            let values = try file.resourceValues(forKeys: [.isUbiquitousItemKey])
            guard values.isUbiquitousItem != true else { throw CacheError.invalidData }
            return try LibrarySyncFileIO.readBounded(file, maximumBytes: Self.maximumFileBytes)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        }
    }

    private func finishLoad(_ entries: [Entry], status: Status) -> Load {
        let result = Load(entries: entries, status: status)
        loaded = result
        _ = record(status, read: 1, count: entries.count)
        return result
    }

    private func record(_ status: Status, read: Int = 0, write: Int = 0, reset: Int = 0, count: Int = 0) -> Status {
        ArtistSpotlightDiagnostics.logger.info("listeningCacheRead=\(read) listeningCacheWrite=\(write) listeningCacheReset=\(reset) cacheOutcome=\(status.rawValue) cacheEntries=\(count)")
        return status
    }
}
