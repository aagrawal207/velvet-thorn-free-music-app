import Foundation

enum MusicWidgetKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case recentlyPlayed, likedSongs, mixes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyPlayed: "Recently played"
        case .likedSongs: "Liked songs"
        case .mixes: "Mix"
        }
    }

    var symbol: String {
        switch self {
        case .recentlyPlayed: "clock.arrow.circlepath"
        case .likedSongs: "heart.fill"
        case .mixes: "sparkles"
        }
    }

    var widgetKind: String {
        switch self {
        case .recentlyPlayed: "Breezy.RecentlyPlayed"
        case .likedSongs: "Breezy.LikedSongs"
        case .mixes: "Breezy.Mix"
        }
    }
}

enum MusicWidgetRoute: Equatable, Sendable {
    case open(MusicWidgetKind)
    case playTrack(source: MusicWidgetKind, id: String)
    case mix(kind: GeneratedPlaylistKind, periodKey: String, play: Bool)

    var source: MusicWidgetKind {
        switch self {
        case .open(let kind), .playTrack(let kind, _): kind
        case .mix: .mixes
        }
    }

    var startsPlayback: Bool {
        switch self {
        case .open: false
        case .playTrack: true
        case .mix(_, _, let play): play
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "ganabajana"
        components.host = "widget"
        switch self {
        case .open(let kind):
            components.path = "/open"
            components.queryItems = [URLQueryItem(name: "kind", value: kind.rawValue)]
        case .playTrack(let source, let id):
            components.path = "/play"
            components.queryItems = [URLQueryItem(name: "source", value: source.rawValue), URLQueryItem(name: "id", value: id)]
        case .mix(let kind, let period, let play):
            components.path = "/mix"
            components.queryItems = [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "period", value: period),
                                     URLQueryItem(name: "play", value: play ? "1" : "0")]
        }
        return components.url!
    }

    init?(url: URL) {
        guard url.absoluteString.utf8.prefix(4097).count <= 4096,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "ganabajana", components.host?.lowercased() == "widget",
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count <= 3 else { return nil }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value, WidgetLibrarySnapshot.isValidIdentifier(value) else { return nil }
            values[item.name] = value
        }
        switch components.path {
        case "/open":
            guard Set(values.keys) == ["kind"], let raw = values["kind"], let kind = MusicWidgetKind(rawValue: raw) else { return nil }
            self = .open(kind)
        case "/play":
            guard Set(values.keys) == ["source", "id"], let raw = values["source"],
                  let kind = MusicWidgetKind(rawValue: raw), kind != .mixes, let id = values["id"] else { return nil }
            self = .playTrack(source: kind, id: id)
        case "/mix":
            guard Set(values.keys) == ["kind", "period", "play"], let raw = values["kind"],
                  let kind = GeneratedPlaylistKind(identifier: raw), let period = values["period"],
                  let play = values["play"], play == "0" || play == "1" else { return nil }
            self = .mix(kind: kind, periodKey: period, play: play == "1")
        default:
            return nil
        }
    }
}
