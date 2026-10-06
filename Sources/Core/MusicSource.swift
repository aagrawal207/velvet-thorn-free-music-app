import Foundation

enum MusicSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case youTubeMusic = "youtube", jioSaavn = "saavn", gaana = "gaana"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youTubeMusic: "YouTube Music"
        case .jioSaavn: "JioSaavn"
        case .gaana: "Gaana"
        }
    }

    /// Bare YouTube video IDs keep their legacy form so saved libraries and share links stay valid.
    var idPrefix: String {
        switch self {
        case .youTubeMusic: ""
        case .jioSaavn: "saavn:"
        case .gaana: "gaana:"
        }
    }

    static func source(of trackID: String) -> MusicSource {
        allCases.first { !$0.idPrefix.isEmpty && trackID.hasPrefix($0.idPrefix) } ?? .youTubeMusic
    }

    static func providerID(of trackID: String) -> String {
        String(trackID.dropFirst(source(of: trackID).idPrefix.count))
    }

    func trackID(forProviderID providerID: String) -> String {
        idPrefix + providerID
    }
}

extension Track {
    var source: MusicSource { MusicSource.source(of: id) }
    var providerID: String { MusicSource.providerID(of: id) }

    var shareURL: URL? {
        switch source {
        case .youTubeMusic: URL(string: "https://music.youtube.com/watch?v=\(id)")
        case .jioSaavn:
            // The provider's perma-URL uses a token that differs from the song id, so link to its search page instead.
            title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                .flatMap { URL(string: "https://www.jiosaavn.com/search/song/\($0)") }
        case .gaana:
            // Song pages need the seokey slug, which the library does not keep; the search page takes the title.
            title.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed)
                .flatMap { URL(string: "https://gaana.com/search/all?keyword=\($0)") }
        }
    }

    /// `urlQueryAllowed` keeps `&`, `+` and `=`, which would split or alter a title inside one query value.
    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))
}

// MARK: Prefixed collection identity

extension MusicSource {
    /// What a prefixed id names. YouTube ids are bare and typed by their provider shape, never by this.
    enum EntityKind: String, Sendable { case track, album, playlist, artist }

    /// `saavn:album:<id>`; YouTube collections keep their bare browse ids. Mixes share the playlist form.
    func collectionID(_ kind: CollectionKind, providerID: String) -> String {
        guard !idPrefix.isEmpty else { return providerID }
        return idPrefix + Self.segment(for: kind) + ":" + providerID
    }

    /// Nil for bare YouTube ids, which have no self-describing prefix.
    static func entityKind(of id: String) -> EntityKind? {
        let source = source(of: id)
        guard !source.idPrefix.isEmpty else { return nil }
        let rest = id.dropFirst(source.idPrefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return .track }
        return EntityKind(rawValue: String(rest[..<colon]))
    }

    /// The provider's own id with the source and entity prefixes removed; bare ids are returned unchanged.
    static func entityProviderID(of id: String) -> String {
        let source = source(of: id)
        guard !source.idPrefix.isEmpty else { return id }
        let rest = id.dropFirst(source.idPrefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return String(rest) }
        return String(rest[rest.index(after: colon)...])
    }

    private static func segment(for kind: CollectionKind) -> String {
        switch kind {
        case .album: EntityKind.album.rawValue
        case .artist: EntityKind.artist.rawValue
        case .playlist, .mix: EntityKind.playlist.rawValue
        }
    }
}

extension MusicCollection {
    var source: MusicSource { MusicSource.source(of: id) }
}
