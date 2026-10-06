import Foundation

struct CachedSong: Equatable, Identifiable, Sendable {
    let id: String
    let track: Track?
    let preferredAudio: CachedAudio?
    let bytes: Int64
    let variantCount: Int
    let isInUse: Bool
    /// At least one complete variant lives in the permanent download tier.
    let isDownloaded: Bool

    init(id: String, track: Track?, preferredAudio: CachedAudio?, bytes: Int64, variantCount: Int, isInUse: Bool,
         isDownloaded: Bool = false) {
        self.id = id
        self.track = track
        self.preferredAudio = preferredAudio
        self.bytes = bytes
        self.variantCount = variantCount
        self.isInUse = isInUse
        self.isDownloaded = isDownloaded
    }

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
