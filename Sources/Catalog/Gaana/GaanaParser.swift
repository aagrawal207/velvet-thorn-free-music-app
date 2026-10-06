import Foundation

/// A catalog song together with the Gaana-only fields the resolver needs at play time.
struct GaanaSong: Sendable, Equatable {
    /// One encrypted HLS master URL; `expiresAt` comes from the payload's epoch `expiryTime`.
    struct EncryptedURL: Sendable, Equatable {
        let message: String
        let expiresAt: Date?
    }

    var track: Track
    var seokey: String?
    var urls: [GaanaMediaURL.Tier: EncryptedURL]
    /// `rest_lev` or `vendor_rest_lev` other than 0: the provider restricts playback and hands out no usable stream.
    var isRestricted: Bool
    var isPremium: Bool
    /// `loudness.integrated` in LUFS ("-8.0 LUFS"), when the provider measured the recording.
    var integratedLoudness: Double?
}

enum GaanaText {
    /// Titles occasionally carry HTML entities; the JioSaavn unescaper handles the same named and numeric forms.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = JioSaavnText.unescape(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Provider ids are decimal strings; seokeys are URL slugs. Both stay short and URL-safe or are refused.
    static func identifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
        else { return nil }
        return value
    }

    static func identifier(_ json: CatalogJSON) -> String? {
        identifier(json.string ?? json.int64.map(String.init))
    }

    /// Rows carry 200 px `size_m` (or 100 px `size_s`) files; the CDN publishes the 400 px `size_l` under the same name.
    static func artwork(_ value: String?) -> URL? {
        guard let value = clean(value), var components = URLComponents(string: value),
              let host = components.host?.lowercased(), host.hasSuffix("gaanacdn.com") || host.hasSuffix("gaana.com") else { return nil }
        components.scheme = "https"
        let name = components.path.split(separator: "/").last.map(String.init) ?? ""
        for size in ["size_m", "size_s"] where name.hasPrefix(size + "_") || name.hasPrefix(size + ".") {
            components.path = String(components.path.dropLast(name.count)) + "size_l" + name.dropFirst(size.count)
            return components.url
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
        if let number = json.int { return number != 0 }
        return ["true", "1"].contains(json.string?.lowercased() ?? "")
    }

    /// `popularity` reads "180685771~180685771": lifetime plays, repeated; `play_ct` ("180M+") is only a rounded label.
    static func playCount(_ json: CatalogJSON) -> Int64? {
        guard let text = json.string?.split(separator: "~").first, let count = Int64(text), count > 0 else { return nil }
        return count
    }

    /// "-8.0 LUFS" to -8.0; other units or unparsable text answer nil.
    static func lufs(_ json: CatalogJSON) -> Double? {
        guard let text = json.string?.lowercased(), text.hasSuffix("lufs"),
              let value = Double(text.dropLast(4).trimmingCharacters(in: .whitespaces)), value.isFinite, (-70...0).contains(value) else { return nil }
        return value
    }

    /// Epoch seconds; the provider hands out URLs that expire about four hours after the details call.
    static func expiry(_ json: CatalogJSON) -> Date? {
        guard let seconds = json.int64 ?? json.string.flatMap(Int64.init), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

/// Maps `gsearch` rows and `apiv2` payloads onto the shared catalog models. Ids are prefixed here so nothing
/// downstream sees a bare one; the numeric provider id is the stable identity, seokeys stay in `GaanaSong`.
enum GaanaParser {
    private static let source = MusicSource.gaana

    // MARK: Search rows

    /// `gsearch` answers `{"gr":[{"ty":"Track","gd":[row]}]}`; the `include` filter decides which groups arrive.
    static func search(_ json: CatalogJSON, filter: SearchFilter) -> CatalogPage {
        let rows = json["gr"].array.flatMap { $0["gd"].array }
        switch filter {
        case .songs: return CatalogPage(tracks: unique(rows.compactMap(searchTrack)))
        case .albums: return CatalogPage(collections: unique(rows.compactMap { searchCollection($0, type: "Album", kind: .album) }))
        case .artists: return CatalogPage(collections: unique(rows.compactMap { searchCollection($0, type: "Artist", kind: .artist) }))
        case .playlists: return CatalogPage(collections: unique(rows.compactMap { searchCollection($0, type: "Playlist", kind: .playlist) }))
        }
    }

    /// Search rows name performers in `sti` ("Mithoon,Arijit Singh") without ids; the details call fills the ids later.
    static func searchTrack(_ row: CatalogJSON) -> Track? {
        guard row["ty"].string == "Track", let id = GaanaText.identifier(row["iid"]) ?? GaanaText.identifier(row["id"]),
              let title = GaanaText.clean(row["ti"].string) else { return nil }
        return Track(id: source.trackID(forProviderID: id), title: title, credits: names(row["sti"].string),
                     artworkURL: GaanaText.artwork(row["aw"].string), language: GaanaText.language(row["language"].string),
                     isAudioRecording: true)
    }

    static func searchCollection(_ row: CatalogJSON, type: String, kind: CollectionKind) -> MusicCollection? {
        guard row["ty"].string == type, let id = GaanaText.identifier(row["iid"]) ?? GaanaText.identifier(row["id"]),
              let title = GaanaText.clean(row["ti"].string) else { return nil }
        let byline = names(row["sti"].string).map(\.name).joined(separator: ", ")
        return MusicCollection(id: source.collectionID(kind, providerID: id), title: title,
                               subtitle: kind == .artist ? "Artist" : byline, artworkURL: GaanaText.artwork(row["aw"].string),
                               kind: kind, language: kind == .artist ? nil : GaanaText.language(row["language"].string))
    }

    // MARK: Detail payloads

    /// A `tracks[]` object of `song_detail`, `album/detail` or `playlist/detail`.
    static func song(_ json: CatalogJSON) -> GaanaSong? {
        guard let id = GaanaText.identifier(json["track_id"]), let title = GaanaText.clean(json["track_title"].string) else { return nil }
        var credits = artistCredits(json["artist"].array)
        if credits.isEmpty { credits = artistCredits(json["artist_detail"].array.filter { $0["role"].string?.contains("Singer") ?? true }) }
        let albumID = GaanaText.identifier(json["album_id"]).map { source.collectionID(.album, providerID: $0) }
        let duration = json["duration"].string.flatMap(Double.init) ?? json["duration"].int.map(Double.init)
        let track = Track(id: source.trackID(forProviderID: id), title: title, credits: credits,
                          albumTitle: GaanaText.clean(json["album_title"].string), albumID: albumID,
                          duration: PlaybackTiming.validDuration(duration),
                          artworkURL: GaanaText.artwork(json["artwork_large"].string ?? json["atw"].string ?? json["artwork"].string),
                          language: GaanaText.language(json["language"].string),
                          isExplicit: GaanaText.flag(json["parental_warning"]), isAudioRecording: true,
                          playCount: GaanaText.playCount(json["popularity"]))
        var urls: [GaanaMediaURL.Tier: GaanaSong.EncryptedURL] = [:]
        for tier in GaanaMediaURL.Tier.allCases {
            let entry = json["urls"][tier.rawValue]
            guard let message = GaanaText.clean(entry["message"].string) else { continue }
            urls[tier] = GaanaSong.EncryptedURL(message: message, expiresAt: GaanaText.expiry(entry["expiryTime"]))
        }
        let restricted = [json["rest_lev"], json["vendor_rest_lev"]].contains { level in
            guard let value = level.int ?? level.string.flatMap(Int.init) else { return false }
            return value != 0
        }
        return GaanaSong(track: track, seokey: GaanaText.identifier(json["seokey"]), urls: urls, isRestricted: restricted,
                         isPremium: GaanaText.flag(json["is_premium"]), integratedLoudness: GaanaText.lufs(json["loudness"]["integrated"]))
    }

    static func songs(_ rows: [CatalogJSON]) -> [Track] {
        unique(rows.compactMap(song).map(\.track))
    }

    /// `song_detail` answers `{"count":1,"tracks":[...]}`; a missing id answers `tracks: null` with `count: 0`.
    static func songDetails(_ json: CatalogJSON) -> [GaanaSong] {
        json["tracks"].array.compactMap(song)
    }

    /// `album/detail`: songs under `tracks`, header credits from `album.primaryartist` then `album.artist`.
    static func albumPage(_ json: CatalogJSON) -> CatalogPage? {
        let album = json["album"]
        guard let title = GaanaText.clean(album["title"].string) else { return nil }
        var credits = artistCredits(album["primaryartist"].array)
        if credits.isEmpty { credits = artistCredits(album["artist"].array) }
        return CatalogPage(tracks: songs(json["tracks"].array), title: title, credits: credits)
    }

    /// `playlist/detail`: songs under `tracks`; `count` is what the provider chose to list, not the full `trackcount`.
    static func playlistPage(_ json: CatalogJSON) -> CatalogPage? {
        guard let title = GaanaText.clean(json["playlist"]["title"].string) else { return nil }
        return CatalogPage(tracks: songs(json["tracks"].array), title: title)
    }

    /// `artist/entity/detail/v1`: the header plus a "Top Songs" section; albums and similar artists arrive separately.
    static func artistPage(_ detail: CatalogJSON, albums: CatalogJSON, similar: CatalogJSON, id: String) -> ArtistPage? {
        let header = detail["artist"]
        guard let name = GaanaText.clean(header["name"].string) else { return nil }
        let topSongs = detail["section_data"].array.flatMap { $0["entities_repo"]["entities"].array }.filter { $0["entity_type"].string == "TR" }
        return ArtistPage(id: id, name: name, artworkURL: GaanaText.artwork(header["atw"].string ?? header["artwork"].string),
                          topSongs: entityTracks(topSongs), releases: unique(albums["entities"].array.compactMap(entityAlbum)),
                          relatedArtists: unique(similar["entities"].array.compactMap(entityArtist)))
    }

    // MARK: Home entities

    /// `/home/artist/tracks/<id>` rows: flat `entity_*` fields plus an `entity_info` array of `{key, value}` pairs.
    static func entityTracks(_ rows: [CatalogJSON]) -> [Track] {
        unique(rows.compactMap(entityTrack))
    }

    static func entityTrack(_ json: CatalogJSON) -> Track? {
        guard json["entity_type"].string == "TR", let id = GaanaText.identifier(json["entity_id"]),
              let title = GaanaText.clean(json["name"].string) else { return nil }
        let info = entityInfo(json)
        let album = info["album"]?.array.first
        let duration = info["duration"]?.string.flatMap(Double.init) ?? info["duration"]?.int.map(Double.init)
        return Track(id: source.trackID(forProviderID: id), title: title, credits: artistCredits(info["artist"]?.array ?? []),
                     albumTitle: GaanaText.clean(album?["name"].string),
                     albumID: GaanaText.identifier(album?["album_id"] ?? .null).map { source.collectionID(.album, providerID: $0) },
                     duration: PlaybackTiming.validDuration(duration),
                     artworkURL: GaanaText.artwork(json["artwork_medium"].string ?? json["atw"].string ?? json["artwork"].string),
                     language: GaanaText.language(json["language"].string),
                     isExplicit: GaanaText.flag(info["parental_warning"] ?? .null), isAudioRecording: true)
    }

    static func entityAlbum(_ json: CatalogJSON) -> MusicCollection? {
        guard json["entity_type"].string == "AL", let id = GaanaText.identifier(json["entity_id"]),
              let title = GaanaText.clean(json["name"].string) else { return nil }
        let byline = artistCredits(entityInfo(json)["primaryartist"]?.array ?? []).map(\.name).joined(separator: ", ")
        return MusicCollection(id: source.collectionID(.album, providerID: id), title: title, subtitle: byline,
                               artworkURL: GaanaText.artwork(json["artwork_medium"].string ?? json["atw"].string ?? json["artwork"].string),
                               kind: .album, language: GaanaText.language(json["language"].string))
    }

    static func entityArtist(_ json: CatalogJSON) -> MusicCollection? {
        guard json["entity_type"].string == "AR", let id = GaanaText.identifier(json["entity_id"]),
              let name = GaanaText.clean(json["name"].string) else { return nil }
        return MusicCollection(id: source.collectionID(.artist, providerID: id), title: name, subtitle: "Artist",
                               artworkURL: GaanaText.artwork(json["atw"].string ?? json["artwork_medium"].string ?? json["artwork"].string),
                               kind: .artist)
    }

    private static func entityInfo(_ json: CatalogJSON) -> [String: CatalogJSON] {
        var info: [String: CatalogJSON] = [:]
        for pair in json["entity_info"].array {
            guard let key = pair["key"].string else { continue }
            info[key] = pair["value"]
        }
        return info
    }

    // MARK: Helpers

    /// `artist` rows carry `artist_id`, `name` and `seokey`; `artist_detail` rows the same plus a `role`.
    static func artistCredits(_ rows: [CatalogJSON]) -> [ArtistCredit] {
        var seen = Set<String>()
        return rows.compactMap { row -> ArtistCredit? in
            guard let name = GaanaText.clean(row["name"].string), seen.insert(name.lowercased()).inserted else { return nil }
            let id = GaanaText.identifier(row["artist_id"]).map { source.collectionID(.artist, providerID: $0) }
            return ArtistCredit(name: name, id: id)
        }
    }

    /// "Mithoon,Arijit Singh" from search rows; names only, so `openArtist` resolves them by name later.
    private static func names(_ text: String?) -> [ArtistCredit] {
        var seen = Set<String>()
        return (GaanaText.clean(text) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 80 && seen.insert($0.lowercased()).inserted }
            .map { ArtistCredit(name: $0) }
    }

    private static func unique(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    private static func unique(_ collections: [MusicCollection]) -> [MusicCollection] {
        var seen = Set<String>()
        return collections.filter { seen.insert($0.id).inserted }
    }
}
