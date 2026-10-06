import SwiftUI

extension NowPlayingView {
    enum PlayerSheet: Identifiable {
        case lyrics, queue
        case browse(Track)
        case actions(Track, PlayerOptionsRoute)

        var id: String {
            switch self {
            case .lyrics: "lyrics"
            case .queue: "queue"
            case .browse(let track): "browse.\(track.id)"
            case .actions(let track, let route): "actions.\(track.id).\(route.rawValue)"
            }
        }
    }

    enum PlayerDeferredAction {
        case album(MusicCollection), artist(ArtistCredit)
    }
}
