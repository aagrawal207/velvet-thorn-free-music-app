import Foundation

enum WidgetSnapshotError: Error, Equatable, Sendable {
    case unavailableDirectory, invalidFile, unsupportedVersion, invalidSnapshot, tooLarge, changedOnDisk
}

struct WidgetSnapshotStore: Sendable {
    struct FileSystem: Sendable {
        let excludeFromBackup: @Sendable (URL) throws -> Void

        static let live = FileSystem(excludeFromBackup: { url in
            var file = url
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try file.setResourceValues(resources)
        })
    }

    static let appGroupIdentifier = "group.com.agraabhi.ganabajana"
    static let fileName = "widget-library.json"
    static let maximumFileBytes = 1024 * 1024

    let directory: URL?
    private let fileSystem: FileSystem
    var fileURL: URL? { directory?.appendingPathComponent(Self.fileName) }

    init(directory: URL?) {
        self.init(directory: directory, fileSystem: .live)
    }

    init(directory: URL?, fileSystem: FileSystem) {
        self.directory = directory?.isFileURL == true ? directory?.standardizedFileURL : directory
        self.fileSystem = fileSystem
    }

    static func sharedDirectory() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Library/Caches/BreezyWidgets", isDirectory: true)
    }

    func read() -> WidgetLibrarySnapshot {
        do {
            guard let data = try readData() else { return .empty }
            return try Self.decode(data)
        } catch {
            return .unavailable
        }
    }

    @discardableResult
    func write(_ snapshot: WidgetLibrarySnapshot) throws -> Bool {
        let data = try Self.encode(snapshot)
        let url = try validatedFileURL()
        let expected = try readData()
        // A derived cache is still somebody else's file if its version or contents cannot be understood.
        let previous = try expected.map(Self.decode)
        let canonical = try Self.decode(data)
        let equal = previous?.hasSameContent(as: canonical) == true
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileSystem.excludeFromBackup(directory)
        guard try readData() == expected else { throw WidgetSnapshotError.changedOnDisk }
        if !equal {
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        }
        try fileSystem.excludeFromBackup(url)
        return !equal
    }

    static func encode(_ snapshot: WidgetLibrarySnapshot) throws -> Data {
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumFileBytes else { throw WidgetSnapshotError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> WidgetLibrarySnapshot {
        guard data.count <= maximumFileBytes else { throw WidgetSnapshotError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        struct Header: Decodable { let version: Int }
        guard try decoder.decode(Header.self, from: data).version == WidgetLibrarySnapshot.currentVersion else {
            throw WidgetSnapshotError.unsupportedVersion
        }
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == ["version", "updatedAt", "availability", "historyEnabled", "accent", "recentlyPlayed",
                                "likedSongs", "likedSongCount", "mixes", "mixSongCounts", "artwork"],
              let recent = raw["recentlyPlayed"] as? [Any], let liked = raw["likedSongs"] as? [Any],
              let mixes = raw["mixes"] as? [[String: Any]], let artwork = raw["artwork"] as? [String: String],
              validTrackPayload(recent), validTrackPayload(liked), mixes.count <= WidgetLibrarySnapshot.maximumMixes,
              let counts = raw["mixSongCounts"] as? [String: Any], counts.count <= WidgetLibrarySnapshot.maximumMixes,
              artwork.count <= WidgetLibrarySnapshot.maximumArtworkCount,
              artwork.values.allSatisfy({ $0.utf8.count <= (WidgetLibrarySnapshot.maximumArtworkBytes + 2) / 3 * 4 }) else {
            throw WidgetSnapshotError.invalidSnapshot
        }
        for mix in mixes {
            guard Set(mix.keys) == ["kind", "tracks", "generatedAt", "periodKey", "seedArtists"],
                  let tracks = mix["tracks"] as? [Any], validTrackPayload(tracks),
                  let seeds = mix["seedArtists"] as? [Any], seeds.isEmpty else {
                throw WidgetSnapshotError.invalidSnapshot
            }
        }
        let snapshot = try decoder.decode(WidgetLibrarySnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }

    // Track's library decoder accepts legacy fields and defaults; widget payloads require an exact shape.
    private static func validTrackPayload(_ tracks: [Any]) -> Bool {
        guard tracks.count <= WidgetLibrarySnapshot.maximumTracksPerList else { return false }
        return tracks.allSatisfy { item in
            guard let track = item as? [String: Any], Set(track.keys) == ["id", "title", "credits", "isExplicit"],
                  let id = track["id"] as? String, id.utf8.count <= WidgetLibrarySnapshot.maximumIdentifierBytes,
                  let title = track["title"] as? String, title.utf8.count <= WidgetLibrarySnapshot.maximumTextBytes,
                  let credits = track["credits"] as? [[String: Any]], credits.count <= WidgetLibrarySnapshot.maximumCredits else { return false }
            return credits.allSatisfy { credit in
                guard Set(credit.keys) == ["name"], let name = credit["name"] as? String else { return false }
                return name.utf8.count <= WidgetLibrarySnapshot.maximumCreditNameBytes
            }
        }
    }

    private func validatedFileURL() throws -> URL {
        guard var directory, directory.isFileURL, let fileURL else { throw WidgetSnapshotError.unavailableDirectory }
        directory.removeAllCachedResourceValues()
        do {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey])
            guard values.isDirectory == true, values.isSymbolicLink != true, values.isUbiquitousItem != true else {
                throw WidgetSnapshotError.unavailableDirectory
            }
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { }
        return fileURL
    }

    private func readData() throws -> Data? {
        var url = try validatedFileURL()
        url.removeAllCachedResourceValues()
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.isUbiquitousItem != true else {
                throw WidgetSnapshotError.invalidFile
            }
            guard let size = values.fileSize, size >= 0, size <= Self.maximumFileBytes else { throw WidgetSnapshotError.tooLarge }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.seekToEnd() <= UInt64(Self.maximumFileBytes) else { throw WidgetSnapshotError.tooLarge }
            try handle.seek(toOffset: 0)
            var data = Data()
            data.reserveCapacity(size)
            while let chunk = try handle.read(upToCount: min(64 * 1024, Self.maximumFileBytes - data.count + 1)), !chunk.isEmpty {
                guard chunk.count <= Self.maximumFileBytes - data.count else { throw WidgetSnapshotError.tooLarge }
                data.append(chunk)
            }
            return data
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        }
    }
}
