import Foundation
import WidgetKit

struct MusicWidgetPresentation: Equatable, Sendable {
    enum EmptyState: Equatable, Sendable {
        case needsApp, unavailable, historyOff, noRecentSongs, noLikedSongs, likedPreviewUnavailable, noMix

        var title: String {
            switch self {
            case .needsApp: "Your music, here"
            case .unavailable: "Can't load music"
            case .historyOff: "History is off"
            case .noRecentSongs: "No recent songs"
            case .noLikedSongs: "No liked songs yet"
            case .likedPreviewUnavailable: "Your liked songs"
            case .noMix: "No saved mix yet"
            }
        }

        var message: String {
            switch self {
            case .needsApp: "Open Velvet Thorn to load this widget."
            case .unavailable: "Open Velvet Thorn to refresh your saved music."
            case .historyOff: "Recently played stays hidden while listening history is off."
            case .noRecentSongs: "Songs you play in Velvet Thorn will appear here."
            case .noLikedSongs: "Like a song in Velvet Thorn to find it here."
            case .likedPreviewUnavailable: "Open Velvet Thorn to view your liked songs."
            case .noMix: "Open Velvet Thorn to find your next mix."
            }
        }

        var compactMessage: String {
            switch self {
            case .historyOff: "Recent songs stay hidden."
            case .noRecentSongs: "Play a song in Velvet Thorn."
            case .noLikedSongs: "Like a song in Velvet Thorn."
            case .unavailable: "Open Velvet Thorn to try again."
            default: message
            }
        }
    }

    enum TimelineState: Equatable, Sendable { case ready, empty, unavailable }

    let kind: MusicWidgetKind
    let mixKind: GeneratedPlaylistKind
    let tracks: [Track]
    let selectedMix: GeneratedPlaylist?
    let songCount: Int?
    let emptyState: EmptyState?

    init(snapshot: WidgetLibrarySnapshot, kind: MusicWidgetKind, mixKind: GeneratedPlaylistKind = .dailyMix) {
        self.kind = kind
        self.mixKind = mixKind
        guard snapshot.availability == .ready else {
            tracks = []
            selectedMix = nil
            songCount = nil
            emptyState = snapshot.availability == .unavailable ? .unavailable : .needsApp
            return
        }
        switch kind {
        case .recentlyPlayed:
            tracks = snapshot.historyEnabled ? Array(snapshot.recentlyPlayed.prefix(WidgetLibrarySnapshot.maximumTracksPerList)) : []
            selectedMix = nil
            songCount = nil
            emptyState = !snapshot.historyEnabled ? .historyOff : tracks.isEmpty ? .noRecentSongs : nil
        case .likedSongs:
            tracks = Array(snapshot.likedSongs.prefix(WidgetLibrarySnapshot.maximumTracksPerList))
            selectedMix = nil
            songCount = Self.collectionCount(snapshot.likedSongCount, preview: tracks)
            emptyState = tracks.isEmpty
                ? (snapshot.likedSongCount > 0 ? .likedPreviewUnavailable : .noLikedSongs) : nil
        case .mixes:
            let mix = snapshot.mixes.first {
                $0.kind == mixKind && !$0.tracks.isEmpty
                    && !$0.periodKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            selectedMix = mix
            let preview = Array((mix?.tracks ?? []).prefix(WidgetLibrarySnapshot.maximumTracksPerList))
            tracks = preview
            songCount = mix.flatMap { Self.collectionCount(snapshot.mixSongCounts[$0.id], preview: preview) }
            emptyState = mix == nil ? .noMix : nil
        }
    }

    var heading: String { kind == .mixes ? mixKind.widgetTitle : kind.title }

    var countText: String? {
        songCount.map { "\($0.formatted()) \($0 == 1 ? "song" : "songs")" }
    }

    var browseRoute: MusicWidgetRoute {
        if let selectedMix {
            return .mix(kind: selectedMix.kind, periodKey: selectedMix.periodKey, play: false)
        }
        return .open(kind)
    }

    var playMixRoute: MusicWidgetRoute? {
        guard let selectedMix else { return nil }
        return .mix(kind: selectedMix.kind, periodKey: selectedMix.periodKey, play: true)
    }

    func trackRoute(for id: String) -> MusicWidgetRoute? {
        guard kind != .mixes, tracks.contains(where: { $0.id == id }) else { return nil }
        return .playTrack(source: kind, id: id)
    }

    func widgetRoute(for family: WidgetFamily) -> MusicWidgetRoute {
        if family == .systemSmall, let first = tracks.first, let route = trackRoute(for: first.id) {
            return route
        }
        return browseRoute
    }

    var timelineState: TimelineState {
        if emptyState == .unavailable { return .unavailable }
        return emptyState == nil ? .ready : .empty
    }

    var smallAccessibilityLabel: String {
        if let emptyState { return "\(heading). \(emptyState.title). \(emptyState.message)" }
        if kind == .mixes {
            return "\(heading)\(countText.map { ". \($0)" } ?? ""). Open mix in Velvet Thorn."
        }
        guard let first = tracks.first else { return heading }
        return "\(heading). Play \(first.title), \(first.artistName)\(first.isExplicit ? ". Explicit" : "")"
    }

    private static func collectionCount(_ count: Int?, preview: [Track]) -> Int? {
        guard let count, count > 0, count >= preview.count else { return nil }
        return count
    }
}

extension GeneratedPlaylistKind {
    var widgetTitle: String { title }
}

/// Mix widget choices. Stored selections are raw kind values; the original `dailyMix` value is Daily Mix 1.
enum MixWidgetOptions {
    static let kinds: [GeneratedPlaylistKind] = GeneratedPlaylistKind.dailyMixes + [.discoverWeekly]

    static func kind(for selection: String?) -> GeneratedPlaylistKind {
        selection.flatMap(GeneratedPlaylistKind.init(identifier:)) ?? .dailyMix
    }
}
