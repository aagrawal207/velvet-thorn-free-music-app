import Foundation

enum GeneratedPlaylistKind: String, Codable, CaseIterable, Sendable {
    /// `dailyMix` keeps its original raw value as Daily Mix 1 so saved libraries, widgets and links still resolve.
    case discoverWeekly, dailyMix, dailyMix2, dailyMix3

    static let dailyMix1 = GeneratedPlaylistKind.dailyMix
    static let dailyMixes: [GeneratedPlaylistKind] = [.dailyMix, .dailyMix2, .dailyMix3]

    /// Accepts the stored raw value plus the `dailyMix1` spelling used by newer configuration surfaces.
    init?(identifier: String) {
        if identifier == "dailyMix1" { self = .dailyMix } else { self.init(rawValue: identifier) }
    }

    var isDailyMix: Bool { self != .discoverWeekly }

    /// One-based Daily Mix position; nil for Discover Weekly.
    var dailyMixNumber: Int? { Self.dailyMixes.firstIndex(of: self).map { $0 + 1 } }

    var title: String {
        switch self {
        case .discoverWeekly: "Discover Weekly"
        case .dailyMix: "Daily Mix 1"
        case .dailyMix2: "Daily Mix 2"
        case .dailyMix3: "Daily Mix 3"
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
    /// Short description of a Daily Mix's taste cluster; absent for Discover Weekly and older saved mixes.
    var focus: String? = nil
    var id: String { kind.rawValue }

    static let maximumFocusBytes = 120

    /// Home card subtitle: the cluster focus, else the seed artists, else the cadence.
    var caption: String {
        let cadence = kind == .discoverWeekly ? "New every Monday" : "Fresh every day"
        guard kind.isDailyMix else { return cadence }
        if let focus, !focus.isEmpty { return focus }
        return Self.artistSummary(seedArtists) ?? cadence
    }

    /// "A", "A and B" or "A, B and more"; never lists more than two names.
    static func artistSummary(_ names: [String]) -> String? {
        let names = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and more"
        }
    }

    var collection: MusicCollection {
        let basis: String
        if kind.isDailyMix, let focus, !focus.isEmpty { basis = "\(focus) · " }
        else { basis = seedArtists.isEmpty ? "" : "Based on \(seedArtists.joined(separator: ", ")) · " }
        let cadence = kind == .discoverWeekly ? "New every Monday" : "Fresh every day"
        return MusicCollection(id: "mix.\(kind.rawValue)", title: kind.title,
                               subtitle: basis + cadence + " · Made on this device from your listening",
                               artworkURL: tracks.first?.artworkURL, kind: .mix, tracks: tracks)
    }
}
