import Foundation

struct CachedSong: Equatable, Identifiable, Sendable {
    let id: String
    let track: Track?
    let preferredAudio: CachedAudio?
    let bytes: Int64
    let variantCount: Int
    let isInUse: Bool

    var isPlayable: Bool {
        AudioCache.isProviderTrackID(id) && preferredAudio?.trackID == id && preferredAudio?.url.isFileURL == true
    }
}

struct AudioCacheSnapshot: Equatable, Sendable {
    let usage: AudioCache.Usage
    let songs: [CachedSong]
}

enum CachedSongRemoval: Equatable, Sendable {
    case removed, notFound, inUse
}

struct AudioCacheRemoval: Equatable, Sendable {
    let outcome: CachedSongRemoval
    let usage: AudioCache.Usage
}
