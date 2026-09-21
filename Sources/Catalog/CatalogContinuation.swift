import Foundation

struct CatalogContinuation: Codable, Sendable {
    let token: String
    let visitorData: String?
    let scope: String
    /// Artist a song search resolved to on its first page; later pages keep the same relevance filter.
    var featuredArtist: MusicCollection?
    /// Spelling correction the first page was ranked against, so continuation pages rank the same way.
    var correctedQuery: String?

    private static let prefix = "ganabajana.catalog.1:"

    init(token: String, visitorData: String?, scope: String, featuredArtist: MusicCollection? = nil, correctedQuery: String? = nil) {
        self.token = token
        self.visitorData = visitorData
        self.scope = scope
        self.featuredArtist = featuredArtist.map { artist in
            var trimmed = artist
            trimmed.tracks = []
            return trimmed
        }
        self.correctedQuery = correctedQuery
    }

    static func decode(_ value: String, scope: String) throws -> CatalogContinuation {
        guard !value.isEmpty, value.utf8.count <= 131_072 else { throw MusicServiceError.invalidResponse }
        if !value.hasPrefix(prefix) {
            guard value.utf8.count <= 65_536 else { throw MusicServiceError.invalidResponse }
            return CatalogContinuation(token: value, visitorData: nil, scope: scope)
        }
        guard let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let cursor = try? JSONDecoder().decode(Self.self, from: data), cursor.scope == scope,
              !cursor.token.isEmpty, cursor.token.utf8.count <= 65_536,
              (cursor.visitorData?.utf8.count ?? 0) <= 4_096,
              (cursor.correctedQuery?.utf8.count ?? 0) <= 4_096,
              cursor.featuredArtist.map(isValidArtist) ?? true else {
            throw MusicServiceError.unavailable("This catalog continuation is no longer valid for the current request. Please reload.")
        }
        return cursor
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.prefix + (try encoder.encode(self)).base64EncodedString()
    }

    static func attach(to page: CatalogPage, response: CatalogResponse, previous: CatalogContinuation?, scope: String,
                       featuredArtist: MusicCollection? = nil, correctedQuery: String? = nil) throws -> CatalogPage {
        var page = page
        if let token = page.continuation {
            // Generated editorial playlists need the same anonymous visitor across pages.
            // This public response token carries no account credentials or cookies.
            let visitor = response.json["responseContext"]["visitorData"].string ?? previous?.visitorData
            guard (visitor?.utf8.count ?? 0) <= 4_096 else { throw MusicServiceError.invalidResponse }
            page.continuation = try CatalogContinuation(token: token, visitorData: visitor, scope: scope,
                                                        featuredArtist: featuredArtist ?? previous?.featuredArtist,
                                                        correctedQuery: correctedQuery ?? previous?.correctedQuery).encoded()
        }
        return page
    }

    private static func isValidArtist(_ artist: MusicCollection) -> Bool {
        artist.kind == .artist && artist.tracks.isEmpty && artist.id.hasPrefix("UC")
            && CatalogText.identifier(artist.id) != nil && artist.title.utf8.count <= 1_024
    }
}
