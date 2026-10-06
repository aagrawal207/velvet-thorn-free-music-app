import Foundation

/// A catalog song together with the JioSaavn-only fields the resolver and lyrics paths need at play time.
struct JioSaavnSong: Sendable, Equatable {
    var track: Track
    var encryptedMediaURL: String?
    var has320: Bool
    var hasLyrics: Bool
}

enum JioSaavnText {
    private static let namedEntities: [String: String] = [
        "quot": "\"", "amp": "&", "apos": "'", "lt": "<", "gt": ">", "nbsp": "\u{00A0}",
    ]

    /// Titles arrive HTML-escaped (`&quot;`, `&amp;`, `&#039;`); the provider never sends markup that must be kept.
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var remainder = Substring(text)
        while let ampersand = remainder.firstIndex(of: "&") {
            result += remainder[..<ampersand]
            let afterAmpersand = remainder[remainder.index(after: ampersand)...]
            guard let semicolon = afterAmpersand.firstIndex(of: ";"), afterAmpersand.distance(from: afterAmpersand.startIndex, to: semicolon) <= 8,
                  let replacement = entity(String(afterAmpersand[..<semicolon])) else {
                result.append("&")
                remainder = afterAmpersand
                continue
            }
            result += replacement
            remainder = afterAmpersand[afterAmpersand.index(after: semicolon)...]
        }
        result += remainder
        return result
    }

    private static func entity(_ name: String) -> String? {
        if let named = namedEntities[name.lowercased()] { return named }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") { value = UInt32(digits.dropFirst(), radix: 16) }
        else { value = UInt32(digits) }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = unescape(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Provider ids are short URL-safe tokens or decimal numbers; anything else is refused before it becomes an id.
    static func identifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
        else { return nil }
        return value
    }

    /// Catalog rows carry 150 px (or 50 px) thumbnails; the CDN publishes 500 px copies under the same name.
    static func artwork(_ value: String?) -> URL? {
        guard let value = clean(value), var components = URLComponents(string: value), components.scheme == "https",
              let host = components.host?.lowercased(), host.hasSuffix("saavncdn.com") || host.hasSuffix("jiosaavn.com") else { return nil }
        let name = components.path.split(separator: "/").last.map(String.init) ?? ""
        // Albums use "-150x150.jpg", artists and editorial playlists "_150x150.jpg"; the separator stays as found.
        for size in ["150x150", "50x50"] {
            for separator in ["-", "_"] where name.contains("\(separator)\(size).") {
                let resized = name.replacingOccurrences(of: "\(separator)\(size).", with: "\(separator)500x500.")
                components.path = String(components.path.dropLast(name.count)) + resized
                return components.url
            }
        }
        return components.url
    }

    static func language(_ value: String?) -> MusicLanguage? {
        switch value?.lowercased() {
        case "hindi": .hindi
        case "english": .english
        default: nil
        }
    }

    static func flag(_ json: CatalogJSON) -> Bool {
        if let bool = json.bool { return bool }
        return ["true", "1"].contains(json.string?.lowercased() ?? "")
    }
}

/// Maps `api.php` payloads onto the shared catalog models. Ids are prefixed here so nothing downstream sees a bare one.
enum JioSaavnParser {
    private static let source = MusicSource.jioSaavn

    // MARK: Rows

    static func song(_ json: CatalogJSON) -> JioSaavnSong? {
        guard (json["type"].string ?? "song") == "song", let id = JioSaavnText.identifier(json["id"].string),
              let title = JioSaavnText.clean(json["title"].string) else { return nil }
        let info = json["more_info"]
        var credits = artistCredits(info["artistMap"]["primary_artists"])
        if credits.isEmpty { credits = artistCredits(info["artistMap"]["artists"].array.filter { $0["role"].string == "singer" }) }
        if credits.isEmpty { credits = fallbackCredits(subtitle: json["subtitle"].string, music: info["music"].string) }
        let albumID = JioSaavnText.identifier(info["album_id"].string).map { source.collectionID(.album, providerID: $0) }
        let duration = info["duration"].string.flatMap(Double.init) ?? info["duration"].int.map(Double.init)
        let track = Track(id: source.trackID(forProviderID: id), title: title, credits: credits,
                          albumTitle: JioSaavnText.clean(info["album"].string), albumID: albumID,
                          duration: PlaybackTiming.validDuration(duration),
                          artworkURL: JioSaavnText.artwork(json["image"].string),
                          language: JioSaavnText.language(json["language"].string),
                          isExplicit: JioSaavnText.flag(json["explicit_content"]), isAudioRecording: true,
                          playCount: playCount(json["play_count"]))
        return JioSaavnSong(track: track, encryptedMediaURL: JioSaavnText.clean(info["encrypted_media_url"].string),
                            has320: JioSaavnText.flag(info["320kbps"]), hasLyrics: JioSaavnText.flag(info["has_lyrics"]))
    }

    static func songs(_ rows: [CatalogJSON]) -> [Track] {
        var seen = Set<String>()
        return rows.compactMap(song).map(\.track).filter { seen.insert($0.id).inserted }
    }

    static func album(_ json: CatalogJSON) -> MusicCollection? {
        guard (json["type"].string ?? "album") == "album", let id = JioSaavnText.identifier(json["id"].string),
              let title = JioSaavnText.clean(json["title"].string) else { return nil }
        let info = json["more_info"]
        var parts: [String] = []
        let artists = artistCredits(info["artistMap"]["primary_artists"]).map(\.name)
        if !artists.isEmpty { parts.append(artists.joined(separator: ", ")) }
        else if let byline = JioSaavnText.clean(json["subtitle"].string) ?? JioSaavnText.clean(info["music"].string) { parts.append(byline) }
        if let year = JioSaavnText.clean(json["year"].string), year.count == 4 { parts.append(year) }
        return MusicCollection(id: source.collectionID(.album, providerID: id), title: title, subtitle: parts.joined(separator: " · "),
                               artworkURL: JioSaavnText.artwork(json["image"].string), kind: .album,
                               language: JioSaavnText.language(json["language"].string))
    }

    static func playlist(_ json: CatalogJSON) -> MusicCollection? {
        guard (json["type"].string ?? "playlist") == "playlist", let id = JioSaavnText.identifier(json["id"].string),
              let title = JioSaavnText.clean(json["title"].string) else { return nil }
        let info = json["more_info"]
        let count = info["song_count"].int ?? json["list_count"].int
        let subtitle = count.map { "\($0) \($0 == 1 ? "song" : "songs")" } ?? JioSaavnText.clean(json["subtitle"].string) ?? ""
        return MusicCollection(id: source.collectionID(.playlist, providerID: id), title: title, subtitle: subtitle,
                               artworkURL: JioSaavnText.artwork(json["image"].string), kind: .playlist,
                               language: JioSaavnText.language(info["language"].string ?? json["language"].string))
    }

    static func artist(_ json: CatalogJSON) -> MusicCollection? {
        guard (json["type"].string ?? "artist") == "artist", let id = JioSaavnText.identifier(json["id"].string ?? json["artistId"].string),
              let name = JioSaavnText.clean(json["name"].string ?? json["title"].string) else { return nil }
        return MusicCollection(id: source.collectionID(.artist, providerID: id), title: name, subtitle: "Artist",
                               artworkURL: JioSaavnText.artwork(json["image"].string), kind: .artist)
    }

    // MARK: Pages

    /// `search.getResults`, `search.getAlbumResults`, `search.getArtistResults` and `search.getPlaylistResults` all
    /// answer `{"total","start","results":[...]}`; the filter tells which row shape to expect.
    static func search(_ json: CatalogJSON, filter: SearchFilter) -> CatalogPage {
        let rows = json["results"].array
        switch filter {
        case .songs: return CatalogPage(tracks: songs(rows))
        case .albums: return CatalogPage(collections: unique(rows.compactMap(album)))
        case .artists: return CatalogPage(collections: unique(rows.compactMap(artist)))
        case .playlists: return CatalogPage(collections: unique(rows.compactMap(playlist)))
        }
    }

    /// `content.getAlbumDetails`: the album object with its songs under `list` and header credits in `more_info`.
    static func albumPage(_ json: CatalogJSON) -> CatalogPage? {
        guard let title = JioSaavnText.clean(json["title"].string) else { return nil }
        var credits = artistCredits(json["more_info"]["artistMap"]["primary_artists"])
        if credits.isEmpty { credits = fallbackCredits(subtitle: json["subtitle"].string, music: json["more_info"]["music"].string) }
        return CatalogPage(tracks: songs(json["list"].array), title: title, credits: credits)
    }

    /// `playlist.getDetails`: songs under `list`; `list_count` is the provider's total for pagination.
    static func playlistPage(_ json: CatalogJSON) -> (page: CatalogPage, total: Int)? {
        guard let title = JioSaavnText.clean(json["title"].string) else { return nil }
        let tracks = songs(json["list"].array)
        return (CatalogPage(tracks: tracks, title: title), max(json["list_count"].int ?? tracks.count, tracks.count))
    }

    /// `artist.getArtistPageDetails`: top songs, albums plus singles as releases, and similar artists.
    static func artistPage(_ json: CatalogJSON, id: String) -> ArtistPage? {
        guard let name = JioSaavnText.clean(json["name"].string) else { return nil }
        let releases = unique((json["topAlbums"].array + json["singles"].array + json["latest_release"].array).compactMap(album))
        return ArtistPage(id: id, name: name, artworkURL: JioSaavnText.artwork(json["image"].string),
                          topSongs: songs(json["topSongs"].array), releases: releases,
                          relatedArtists: unique(json["similarArtists"].array.compactMap(artist)))
    }

    /// `song.getDetails` answers `{"songs":[...]}`; the fixture form of the same call is `webapi.get&type=song`.
    static func songDetails(_ json: CatalogJSON) -> [JioSaavnSong] {
        json["songs"].array.compactMap(song)
    }

    /// `reco.getreco` keys the neighbours by the seed id; a bare array means the context returned nothing.
    static func recommendations(_ json: CatalogJSON, seedProviderID: String) -> [Track] {
        let rows = json[seedProviderID].array.isEmpty ? json.array : json[seedProviderID].array
        let seedID = source.trackID(forProviderID: seedProviderID)
        return songs(rows).filter { $0.id != seedID }
    }

    /// `lyrics.getLyrics` returns `{"lyrics":"line<br>line"}`; a failure envelope or empty text means unavailable.
    static func lyrics(_ json: CatalogJSON) -> String? {
        guard let raw = json["lyrics"].string else { return nil }
        let text = JioSaavnText.unescape(raw.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive]))
            .replacingOccurrences(of: #"<[^>]{1,32}>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: Helpers

    static func artistCredits(_ json: CatalogJSON) -> [ArtistCredit] {
        artistCredits(json.array)
    }

    private static func artistCredits(_ rows: [CatalogJSON]) -> [ArtistCredit] {
        var seen = Set<String>()
        return rows.compactMap { row -> ArtistCredit? in
            guard let name = JioSaavnText.clean(row["name"].string), seen.insert(name.lowercased()).inserted else { return nil }
            let id = JioSaavnText.identifier(row["id"].string).map { source.collectionID(.artist, providerID: $0) }
            return ArtistCredit(name: name, id: id)
        }
    }

    /// "Mithoon, Arijit Singh - Aashiqui 2" names the performers before the dash; `music` is the composer.
    private static func fallbackCredits(subtitle: String?, music: String?) -> [ArtistCredit] {
        var text = JioSaavnText.clean(subtitle) ?? ""
        if let dash = text.range(of: " - ") { text = String(text[..<dash.lowerBound]) }
        if text.isEmpty { text = JioSaavnText.clean(music) ?? "" }
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 80 && seen.insert($0.lowercased()).inserted }
            .map { ArtistCredit(name: $0) }
    }

    private static func playCount(_ json: CatalogJSON) -> Int64? {
        guard let count = json.int64, count > 0 else { return nil }
        return count
    }

    private static func unique(_ collections: [MusicCollection]) -> [MusicCollection] {
        var seen = Set<String>()
        return collections.filter { seen.insert($0.id).inserted }
    }
}
