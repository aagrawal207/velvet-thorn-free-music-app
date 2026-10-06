import Foundation
import OSLog

/// Another catalog's copy of a song, used when the song's own source hands out no stream. The match is by title,
/// first artist and duration, never by id, so it stays conservative: a miss falls through to the next source.
protocol CrossSourceStreamFallback: Sendable {
    var source: MusicSource { get }
    /// A stream for the same recording, preserving its playbackSource even when served from a local cache.
    /// Nil means no match; an unknown local copy must not be stamped with this fallback's catalog source.
    func resolve(matching track: Track, forceRefresh: Bool) async throws -> ResolvedStream?
}

enum CrossSourceMatch {
    /// Providers report whole seconds and occasionally trim silence; three seconds keeps versions and remixes apart.
    static let durationTolerance: TimeInterval = 3

    /// "Tum Hi Ho Mithoon": the first credited artist narrows a common title to the right recording.
    static func query(for track: Track) -> String {
        [track.title, track.credits.first?.name].compactMap { $0 }.joined(separator: " ")
    }

    /// The first candidate whose normalized title equals the song's and whose duration is within the tolerance.
    /// A song without a known duration never matches: the title alone cannot separate versions.
    static func best(_ candidates: [Track], for track: Track) -> Track? {
        guard let duration = track.duration, duration > 0 else { return nil }
        let title = SearchRelevance.normalize(track.title)
        guard !title.isEmpty else { return nil }
        let artist = track.credits.first.map { SearchRelevance.normalize($0.name) } ?? ""
        return candidates.first { candidate in
            guard candidate.isAudioRecording != false, let length = candidate.duration,
                  abs(length - duration) <= durationTolerance, SearchRelevance.normalize(candidate.title) == title else { return false }
            return artist.isEmpty || candidate.credits.contains { SearchRelevance.normalize($0.name) == artist }
        }
    }
}

/// JioSaavn as a stand-in: plain AAC files up to 320 kbps that the shared cache can also store.
struct JioSaavnStreamFallback: CrossSourceStreamFallback {
    let catalog: JioSaavnCatalogService
    let resolver: JioSaavnStreamResolver
    var source: MusicSource { .jioSaavn }

    func resolve(matching track: Track, forceRefresh: Bool) async throws -> ResolvedStream? {
        let page = try await catalog.search(query: CrossSourceMatch.query(for: track), filter: .songs, continuation: nil)
        guard let match = CrossSourceMatch.best(page.tracks, for: track) else { return nil }
        return try await resolver.resolve(track: match, forceRefresh: forceRefresh)
    }
}

/// YouTube Music as the last stand-in; the primary catalog's search is a single-source call, never the composite.
struct YouTubeStreamFallback: CrossSourceStreamFallback {
    let catalog: any MusicCatalogProviding
    let resolver: any StreamResolving
    var source: MusicSource { .youTubeMusic }

    func resolve(matching track: Track, forceRefresh: Bool) async throws -> ResolvedStream? {
        let page = try await catalog.search(query: CrossSourceMatch.query(for: track), filter: .songs, continuation: nil)
        guard let match = CrossSourceMatch.best(page.tracks.filter { $0.source == .youTubeMusic }, for: track) else { return nil }
        return try await resolver.resolve(track: match, forceRefresh: forceRefresh)
    }
}
