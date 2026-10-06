import Foundation

struct WidgetLibrarySnapshot: Codable, Equatable, Sendable {
    enum Availability: String, Codable, Sendable {
        case ready, needsApp, unavailable
    }

    static let currentVersion = 1
    static let maximumTracksPerList = 6
    /// Discover Weekly plus Daily Mix 1 to 3.
    static let maximumMixes = 4
    static let maximumIdentifierBytes = 256
    static let maximumTextBytes = 384
    static let maximumCreditNameBytes = 192
    static let maximumCredits = 4
    static let maximumSongCount = 1_000_000
    static let maximumArtworkCount = 24
    static let maximumArtworkBytes = 24 * 1024
    static let maximumTotalArtworkBytes = 512 * 1024
    static let maximumArtworkPixels = 240

    static let empty = WidgetLibrarySnapshot(updatedAt: Date(timeIntervalSince1970: 0), availability: .needsApp)
    static let unavailable = WidgetLibrarySnapshot(updatedAt: Date(timeIntervalSince1970: 0),
                                                    availability: .unavailable, historyEnabled: false)

    var version: Int
    var updatedAt: Date
    var availability: Availability
    var historyEnabled: Bool
    var accent: AppAccent
    var recentlyPlayed: [Track]
    var likedSongs: [Track]
    var likedSongCount: Int
    var mixes: [GeneratedPlaylist]
    var mixSongCounts: [String: Int]
    var artwork: [String: Data]

    init(version: Int = WidgetLibrarySnapshot.currentVersion, updatedAt: Date = Date(), availability: Availability = .ready,
         historyEnabled: Bool = true, accent: AppAccent = .coral, recentlyPlayed: [Track] = [],
         likedSongs: [Track] = [], likedSongCount: Int? = nil, mixes: [GeneratedPlaylist] = [],
         mixSongCounts: [String: Int]? = nil, artwork: [String: Data] = [:]) {
        self.version = version
        self.updatedAt = updatedAt
        self.availability = availability
        self.historyEnabled = historyEnabled
        self.accent = accent
        self.recentlyPlayed = recentlyPlayed
        self.likedSongs = likedSongs
        self.likedSongCount = likedSongCount ?? likedSongs.count
        self.mixes = mixes
        self.mixSongCounts = mixSongCounts ?? mixes.reduce(into: [:]) { $0[$1.id] = $1.tracks.count }
        self.artwork = artwork
    }

    static func projection(recentlyPlayed: [Track], likedSongs: [Track], mixes: [GeneratedPlaylist],
                           historyEnabled: Bool = true, accent: AppAccent = .coral,
                           updatedAt: Date = Date()) -> Self {
        var kinds = Set<GeneratedPlaylistKind>()
        var savedMixes: [GeneratedPlaylist] = []
        var counts: [String: Int] = [:]
        for mix in mixes {
            guard savedMixes.count < maximumMixes else { break }
            guard isValidIdentifier(mix.periodKey), isValidDate(mix.generatedAt), kinds.insert(mix.kind).inserted else { continue }
            let tracks = projectedTracks(mix.tracks)
            guard !tracks.isEmpty else { continue }
            savedMixes.append(GeneratedPlaylist(kind: mix.kind, tracks: tracks, generatedAt: mix.generatedAt,
                                                periodKey: mix.periodKey, seedArtists: []))
            counts[mix.id] = min(mix.tracks.count, maximumSongCount)
        }
        return Self(updatedAt: updatedAt, historyEnabled: historyEnabled, accent: accent,
                    recentlyPlayed: historyEnabled ? projectedTracks(recentlyPlayed) : [],
                    likedSongs: projectedTracks(likedSongs), likedSongCount: min(likedSongs.count, maximumSongCount),
                    mixes: savedMixes, mixSongCounts: counts)
    }

    var displayedTracks: [Track] {
        var seen = Set<String>()
        return (recentlyPlayed + likedSongs + mixes.flatMap(\.tracks)).filter { seen.insert($0.id).inserted }
    }

    func hasSameContent(as other: Self) -> Bool {
        var left = self
        var right = other
        left.updatedAt = .distantPast
        right.updatedAt = .distantPast
        return left == right
    }

    func withArtwork(_ candidates: [String: Data]) -> Self {
        var result = self
        result.artwork = [:]
        var bytes = 0
        for track in displayedTracks.prefix(Self.maximumArtworkCount) {
            guard let data = candidates[track.id], Self.isValidArtwork(data),
                  data.count <= Self.maximumTotalArtworkBytes - bytes else { continue }
            result.artwork[track.id] = data
            bytes += data.count
        }
        return result
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw WidgetSnapshotError.unsupportedVersion }
        guard Self.isValidDate(updatedAt), recentlyPlayed.count <= Self.maximumTracksPerList,
              likedSongs.count <= Self.maximumTracksPerList, mixes.count <= Self.maximumMixes,
              likedSongCount >= likedSongs.count, likedSongCount <= Self.maximumSongCount,
              historyEnabled || recentlyPlayed.isEmpty,
              Set(mixes.map(\.kind)).count == mixes.count,
              Set(mixSongCounts.keys) == Set(mixes.map(\.id)) else { throw WidgetSnapshotError.invalidSnapshot }
        if availability != .ready {
            guard recentlyPlayed.isEmpty, likedSongs.isEmpty, likedSongCount == 0, mixes.isEmpty,
                  mixSongCounts.isEmpty, artwork.isEmpty else { throw WidgetSnapshotError.invalidSnapshot }
        }
        try Self.validateTracks(recentlyPlayed)
        try Self.validateTracks(likedSongs)
        for mix in mixes {
            guard Self.isValidIdentifier(mix.periodKey), Self.isValidDate(mix.generatedAt), mix.seedArtists.isEmpty,
                  let count = mixSongCounts[mix.id], count >= mix.tracks.count, count <= Self.maximumSongCount else {
                throw WidgetSnapshotError.invalidSnapshot
            }
            try Self.validateTracks(mix.tracks)
        }
        let displayedIDs = Set(displayedTracks.map(\.id))
        guard artwork.count <= Self.maximumArtworkCount, Set(artwork.keys).isSubset(of: displayedIDs) else {
            throw WidgetSnapshotError.invalidSnapshot
        }
        var bytes = 0
        for data in artwork.values {
            guard Self.isValidArtwork(data), data.count <= Self.maximumTotalArtworkBytes - bytes else {
                throw WidgetSnapshotError.invalidSnapshot
            }
            bytes += data.count
        }
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.prefix(maximumIdentifierBytes + 1).count <= maximumIdentifierBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    // The extension can check the JPEG frame bounds before asking an image decoder to allocate a bitmap.
    // Entropy decoding remains the image framework's job; malformed image content renders as a placeholder.
    static func isValidArtwork(_ data: Data) -> Bool {
        guard (4...maximumArtworkBytes).contains(data.count) else { return false }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            guard bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
            var offset = 2
            var frame = false
            var scan = false
            while offset < bytes.count {
                if scan, bytes[offset] != 0xFF { offset += 1; continue }
                guard bytes[offset] == 0xFF else { return false }
                while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
                guard offset < bytes.count else { return false }
                let marker = bytes[offset]
                offset += 1
                if scan, marker == 0 || (0xD0...0xD7).contains(marker) { continue }
                if marker == 0xD9 { return frame && scan && offset == bytes.count }
                guard marker != 0, marker != 0xD8, marker != 1, !(0xD0...0xD7).contains(marker),
                      offset + 2 <= bytes.count else { return false }
                let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
                guard length >= 2, length <= bytes.count - offset else { return false }
                if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                    guard !frame, [0xC0, 0xC1, 0xC2].contains(marker), length >= 8, bytes[offset + 2] == 8 else { return false }
                    let height = Int(bytes[offset + 3]) * 256 + Int(bytes[offset + 4])
                    let width = Int(bytes[offset + 5]) * 256 + Int(bytes[offset + 6])
                    let components = Int(bytes[offset + 7])
                    guard (1...maximumArtworkPixels).contains(width), (1...maximumArtworkPixels).contains(height),
                          [1, 3].contains(components), length == 8 + 3 * components else { return false }
                    frame = true
                }
                if marker == 0xDA {
                    guard frame, length >= 6 else { return false }
                    let components = Int(bytes[offset + 2])
                    guard (1...3).contains(components), length == 6 + 2 * components else { return false }
                    scan = true
                } else {
                    scan = false
                }
                offset += length
            }
            return false
        }
    }

    private static func projectedTracks(_ tracks: [Track]) -> [Track] {
        var result: [Track] = []
        var seen = Set<String>()
        for track in tracks {
            guard result.count < maximumTracksPerList else { break }
            guard isValidIdentifier(track.id), seen.insert(track.id).inserted else { continue }
            let title = boundedText(track.title, maximum: maximumTextBytes)
            guard !title.isEmpty else { continue }
            let credits = track.credits.prefix(maximumCredits).compactMap { credit -> ArtistCredit? in
                let name = boundedText(credit.name, maximum: maximumCreditNameBytes)
                return name.isEmpty ? nil : ArtistCredit(name: name)
            }
            result.append(Track(id: track.id, title: title, credits: credits, isExplicit: track.isExplicit))
        }
        return result
    }

    private static func validateTracks(_ tracks: [Track]) throws {
        guard tracks.count <= maximumTracksPerList, Set(tracks.map(\.id)).count == tracks.count else {
            throw WidgetSnapshotError.invalidSnapshot
        }
        for track in tracks {
            guard isValidIdentifier(track.id), !track.title.isEmpty, track.title == boundedText(track.title, maximum: maximumTextBytes),
                  track.credits.count <= maximumCredits, track.credits.allSatisfy({
                      $0.id == nil && !$0.name.isEmpty && $0.name == boundedText($0.name, maximum: maximumCreditNameBytes)
                  }), track.albumTitle == nil, track.albumID == nil, track.duration == nil, track.artworkURL == nil,
                  track.language == nil, track.isAudioRecording == nil, track.playCount == nil else {
                throw WidgetSnapshotError.invalidSnapshot
            }
        }
    }

    private static func boundedText(_ value: String, maximum: Int) -> String {
        var text = ""
        var bytes = 0
        for scalar in value.unicodeScalars {
            let piece = CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
            guard bytes + piece.utf8.count <= maximum else { break }
            text += piece
            bytes += piece.utf8.count
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidDate(_ date: Date) -> Bool {
        let time = date.timeIntervalSince1970
        return time.isFinite && time >= 0 && time < 253_402_300_800
    }
}
