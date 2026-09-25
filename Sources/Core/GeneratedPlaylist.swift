import Foundation

enum GeneratedPlaylistKind: String, Codable, CaseIterable, Sendable {
    case discoverWeekly, dailyMix

    var title: String {
        switch self {
        case .discoverWeekly: "Discover Weekly"
        case .dailyMix: "Your Daily Mix"
        }
    }
}

/// A playlist the on-device recommendation engine produced. Stored so it stays stable between launches.
struct GeneratedPlaylist: Codable, Hashable, Identifiable, Sendable {
    var kind: GeneratedPlaylistKind
    var tracks: [Track]
    var generatedAt: Date
    /// Refresh key: ISO week for weekly mixes, calendar day for daily ones.
    var periodKey: String
    var seedArtists: [String]
    var id: String { kind.rawValue }

    var collection: MusicCollection {
        let basis = seedArtists.isEmpty ? "" : "Based on \(seedArtists.joined(separator: ", ")) · "
        let cadence = kind == .discoverWeekly ? "New every Monday" : "Fresh every day"
        return MusicCollection(id: "mix.\(kind.rawValue)", title: kind.title,
                               subtitle: basis + cadence + " · Made on this device from your listening",
                               artworkURL: tracks.first?.artworkURL, kind: .mix, tracks: tracks)
    }
}
