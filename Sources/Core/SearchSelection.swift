import Foundation

enum SearchSelection: Codable, Hashable, Identifiable, Sendable {
    case track(Track)
    case collection(MusicCollection)

    var id: String {
        switch self {
        case .track(let track): "track:\(track.id)"
        case .collection(let collection): "collection:\(collection.kind.rawValue):\(collection.id)"
        }
    }

    var title: String {
        switch self {
        case .track(let track): track.title
        case .collection(let collection): collection.title
        }
    }

    var subtitle: String {
        switch self {
        case .track(let track): track.artistName
        case .collection(let collection): collection.subtitle
        }
    }

    var artworkURL: URL? {
        switch self {
        case .track(let track): track.artworkURL
        case .collection(let collection): collection.artworkURL
        }
    }

    var typeTitle: String {
        switch self {
        case .track: "Song"
        case .collection(let collection):
            switch collection.kind {
            case .artist: "Artist"
            case .album: "Album"
            case .playlist: "Playlist"
            case .mix: "Mix"
            }
        }
    }
}

enum SearchSelectionSource: String, Sendable {
    case result, recent, resultMenu
}
