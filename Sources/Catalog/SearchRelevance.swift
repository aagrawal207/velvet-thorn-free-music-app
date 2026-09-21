import Foundation

/// Relevance heuristics for song search. The provider keeps its own row order and tokenizes initials
/// ("A. R.") into unrelated matches, so pages are re-tiered against the query and the artist it names.
enum SearchRelevance {
    /// Minimum normalized-name similarity for an artists-search result to count as the queried artist.
    static let artistMatchThreshold = 0.85
    /// Minimum similarity between a track's credited artist and the matched artist to be "by" that artist.
    static let sameArtistThreshold = 0.9
    /// Tier-0 depth at which partial matches are dropped from an artist-resolved page.
    static let fullArtistDepth = 8
    /// Minimum tier-0 tracks on the songs page before an artists-search hit is featured; guards against
    /// artists that merely share a name with the searched song.
    static let minimumFeaturedTracks = 2

    /// Lowercase, diacritic-free text with punctuation removed and runs of single letters joined, so that
    /// "A. R. Rahman", "A.R. Rahman", and "AR Rahman" all become "ar rahman".
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let spaced = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        var merged: [String] = []
        var initials = ""
        for token in spaced.split(whereSeparator: \.isWhitespace) {
            if isInitial(token) {
                initials += token
                continue
            }
            if !initials.isEmpty {
                merged.append(initials)
                initials = ""
            }
            merged.append(String(token))
        }
        if !initials.isEmpty { merged.append(initials) }
        return merged.joined(separator: " ")
    }

    /// Normalized Levenshtein similarity in 0...1 over `normalize`d text; equal strings score 1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let left = Array(normalize(a).prefix(256))
        let right = Array(normalize(b).prefix(256))
        if left == right { return 1 }
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for (row, character) in left.enumerated() {
            current[0] = row + 1
            for column in right.indices {
                current[column + 1] = min(previous[column + 1] + 1, current[column] + 1,
                                          previous[column] + (character == right[column] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[right.count]) / Double(max(left.count, right.count))
    }

    /// 0: by the matched artist; 1: every query token appears in the title or credits; 2: some tokens; 3: none.
    static func tier(of track: Track, query: String, artist: MusicCollection?) -> Int {
        if let artist, isBy(artist, track) { return 0 }
        let tokens = normalize(query).split(separator: " ")
        guard !tokens.isEmpty else { return 3 }
        let words = normalize(([track.title] + track.artists).joined(separator: " ")).split(separator: " ")
        let matched = tokens.filter { token in words.contains { $0.hasPrefix(token) } }.count
        if matched == tokens.count { return 1 }
        return matched > 0 ? 2 : 3
    }

    /// Stable tiering that keeps provider order inside a tier. With a matched artist, tracks sharing nothing
    /// with the query are dropped, and partial matches too once the artist's own tracks fill the page.
    static func rank(_ tracks: [Track], query: String, artist: MusicCollection?) -> [Track] {
        let tiered = tracks.enumerated().map { (offset: $0.offset, tier: tier(of: $0.element, query: query, artist: artist), track: $0.element) }
        let lowestKept: Int
        if artist == nil {
            lowestKept = 3
        } else {
            lowestKept = tiered.filter { $0.tier == 0 }.count >= fullArtistDepth ? 1 : 2
        }
        return tiered.filter { $0.tier <= lowestKept }
            .sorted { $0.tier == $1.tier ? $0.offset < $1.offset : $0.tier < $1.tier }
            .map(\.track)
    }

    /// The artists-search result the query names: the first actual artist whose normalized name is close to the
    /// query or the provider's spelling correction, or that contains every query word (a first name alone).
    static func matchedArtist(in artists: [MusicCollection], query: String, correctedQuery: String? = nil) -> MusicCollection? {
        let queries = [query, correctedQuery].compactMap { $0 }.map(normalize).filter { !$0.isEmpty }
        guard !queries.isEmpty else { return nil }
        return artists.first { artist in
            guard artist.kind == .artist else { return false }
            let name = normalize(artist.title)
            let words = Set(name.split(separator: " "))
            return queries.contains { query in
                if similarity(name, query) >= artistMatchThreshold { return true }
                let tokens = query.split(separator: " ")
                return tokens.allSatisfy { $0.count >= 3 && words.contains($0) }
            }
        }
    }

    private static func isBy(_ artist: MusicCollection, _ track: Track) -> Bool {
        if let artistID = track.artistID, artistID == artist.id { return true }
        let name = normalize(artist.title)
        guard !name.isEmpty else { return false }
        return track.artists.contains { similarity(normalize($0), name) >= sameArtistThreshold }
    }

    /// A lone Latin letter, the shape initials take once punctuation is removed.
    private static func isInitial(_ token: Substring) -> Bool {
        guard token.unicodeScalars.count == 1, let scalar = token.unicodeScalars.first else { return false }
        return scalar.properties.isAlphabetic && scalar.value < 0x250
    }
}
