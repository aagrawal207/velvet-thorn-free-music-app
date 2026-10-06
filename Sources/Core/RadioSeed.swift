import Foundation

/// The listener's original choice stays fixed while recommendations and the play queue change.
enum RadioSeed: Codable, Hashable, Sendable, Identifiable {
    case song(Track)
    case artist(ArtistCredit)

    var id: String {
        switch self {
        case .song(let track): "song:\(track.id)"
        case .artist(let artist): "artist:\(artist.id ?? SearchRelevance.normalize(artist.name))"
        }
    }

    var title: String {
        switch self {
        case .song(let track): track.title
        case .artist(let artist): artist.name
        }
    }

    var radioTitle: String { "\(title) Radio" }
    var kind: String { if case .song = self { "song" } else { "artist" } }
    var artworkURL: URL? { if case .song(let track) = self { track.artworkURL } else { nil } }

    var isValid: Bool {
        switch self {
        case .song(let track):
            return (try? LibraryValidation.validateTrack(track)) != nil
                && track.id.utf8.count <= 512 && track.title.utf8.count <= 2_048
        case .artist(let artist):
            return !artist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && artist.name.utf8.count <= 512 && !(artist.id?.isEmpty ?? false)
                && (artist.id?.utf8.count ?? 0) <= 512
        }
    }
}

struct RadioTuning: Codable, Hashable, Sendable {
    var familiarity: DiscoveryFamiliarity = .balanced
    /// Nil uses the listening profile softly; an explicit choice excludes unclassified recordings.
    var language: ArtistSongLanguage?

    var summary: String { "\(familiarity.radioTitle) · \(language?.title ?? "Automatic Language")" }
}

extension DiscoveryFamiliarity {
    var radioTitle: String {
        switch self {
        case .familiar: "Familiar"
        case .balanced: "Balanced"
        case .newMusic: "Discover"
        }
    }
}

struct RadioHistoryEntry: Codable, Hashable, Sendable, Identifiable {
    let seed: RadioSeed
    var tuning: RadioTuning
    var startedAt: Date
    var id: String { seed.id }
}
