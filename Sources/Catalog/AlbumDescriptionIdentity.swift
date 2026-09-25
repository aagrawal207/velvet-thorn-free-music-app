import Foundation

enum AlbumDescriptionIdentity {
    static func albumID(_ value: String) -> String? {
        guard let id = CatalogText.identifier(value), id.hasPrefix("MPRE") || id.hasPrefix("MPAL") else { return nil }
        return id
    }

    static func matches(text: String, title: String, credits: [ArtistCredit], articleTitle: String) -> Bool {
        let titleKey = LyricsMatcher.normalized(title)
        let sentences = sentences(text)
        let textKey = LyricsMatcher.normalized(sentences.first ?? "")
        guard !titleKey.isEmpty, textKey.hasPrefix(titleKey + " is ") || textKey.hasPrefix(titleKey + " was "),
              !credits.isEmpty, credits.count <= 8 else { return false }

        let definition = String(textKey.dropFirst(titleKey.count)).split(separator: " ")
        let albumKinds: Set<Substring> = ["album", "soundtrack", "ep"]
        guard let kind = definition.indices.first(where: { index in
            albumKinds.contains(definition[index]) || (definition[index] == "extended"
                && definition.indices.contains(index + 1) && definition[index + 1] == "play")
        }), kind < 16 else { return false }
        let otherKinds: Set<Substring> = ["film", "song", "single", "singer", "rapper", "musician", "band", "actor",
                                           "novel", "book", "video", "disambiguation", "list"]
        guard !definition[..<kind].contains(where: otherKinds.contains) else { return false }

        let names = credits.map { SearchRelevance.normalize($0.name) }
        guard names.allSatisfy({ !$0.isEmpty && $0 != "various artists" && $0 != "unknown artist" }) else { return false }
        let soundtrack = definition[kind] == "soundtrack"
        let kindLength = definition[kind] == "extended" ? 2 : 1
        var attribution = SearchRelevance.normalize(definition.dropFirst(kind + kindLength).joined(separator: " "))
        if soundtrack, attribution.hasPrefix("album ") { attribution = String(attribution.dropFirst(6)) }

        let relatedNames: Set<String>
        if attribution.hasPrefix("by ") {
            // An explicit lead byline must agree on its own; later contributors cannot repair a conflict.
            guard let leadNames = attributedNames(String(attribution.dropFirst(3)), names: names) else { return false }
            relatedNames = leadNames
        } else {
            guard soundtrack else { return false }
            var composers = soundtrackComposers(sentences, names: names)
            if attribution.hasPrefix("composed by ") {
                guard let leadNames = attributedNames(String(attribution.dropFirst(12)), names: names) else { return false }
                composers.formUnion(leadNames)
            }
            relatedNames = composers
        }
        guard names.allSatisfy(relatedNames.contains) else { return false }

        let articleKey = LyricsMatcher.normalized(articleTitle)
        if articleKey == titleKey { return true }
        let suffixes = ["album", "soundtrack", "EP"] + credits.map { $0.name + " album" }
        return suffixes.contains { articleKey == LyricsMatcher.normalized(title + " (" + $0 + ")") }
    }

    private static func sentences(_ text: String) -> [String] {
        // A period after a single letter belongs to an initial, including spaced initials such as A. R.
        text.replacingOccurrences(of: #"(?<!\b[A-Za-z])\.(?=\s|$)|[!?](?=\s|$)|[\r\n]+"#,
                                  with: "\u{001F}", options: .regularExpression)
            .components(separatedBy: "\u{001F}").compactMap(CatalogText.clean)
    }

    private static func attributedNames(_ byline: String, names: [String]) -> Set<String>? {
        let text = SearchRelevance.normalize(byline)
        let alternatives = names.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let descriptors = #"(?:(?:the|an?|american|british|english|indian|canadian|australian|scottish|irish|welsh|"#
            + #"singer|songwriter|rapper|musician|composer|producer|record|recording|artist|artists|band|group|duo|trio|rock|pop|hip|hop|electronic|and) ){0,6}"#
        let artist = descriptors + "(?:" + alternatives + ")"
        let pattern = "^(" + artist + "(?: (?:and )?" + artist + "){0,7})"
            + #"(?=$| (?:and )?(?:featuring|with|including|produced|inspired|compared|unlike|for|who|which)\b)"#
        guard let attributed = capture(pattern, in: text),
              let expression = try? NSRegularExpression(pattern: "(?:^| )" + descriptors + "(" + alternatives + ")(?= |$)") else { return nil }
        return Set(expression.matches(in: attributed, range: NSRange(attributed.startIndex..., in: attributed)).compactMap { match in
            Range(match.range(at: 1), in: attributed).map { String(attributed[$0]) }
        })
    }

    private static func soundtrackComposers(_ sentences: [String], names: [String]) -> Set<String> {
        let passive = #"^(?:the|this|its) (?:music|score|songs|soundtrack|album)(?: (?:of|for) (?:the|this) film)? (?:was|were|is|are) (?:(?:mostly|mainly|primarily|jointly) )?composed by (.+)$"#
        let active = #"^(.+) composed (?:the|this) (?:music|score|soundtrack)(?: for (?:the|this) film)?$"#
        let sharedSongs = #"^(.+) composed (?:(?:one|two|three|four|five|six|seven|eight|nine|ten|[0-9]+) )?songs(?: each)?(?: as guest composers?)?$"#
        var result = Set<String>()
        for sentence in sentences {
            let text = SearchRelevance.normalize(sentence)
            let clauses = text.replacingOccurrences(of: #" (?:although|while) "#, with: "\u{001F}", options: .regularExpression)
                .components(separatedBy: "\u{001F}")
            if let byline = capture(passive, in: clauses.first ?? "") {
                result.formUnion(attributedNames(byline, names: names) ?? [])
                // Shared song clauses inherit the same soundtrack subject, including its guest composers.
                for clause in clauses.dropFirst() {
                    if let byline = capture(sharedSongs, in: clause) {
                        result.formUnion(attributedNames(byline, names: names) ?? [])
                    }
                }
            } else if let byline = capture(active, in: text) {
                result.formUnion(attributedNames(byline, names: names) ?? [])
            }
        }
        return result
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func excerpt(_ text: String, maximumCharacters: Int) -> (text: String, shortened: Bool) {
        guard text.count > maximumCharacters else { return (text, false) }
        let prefix = text.prefix(maximumCharacters)
        let boundary = prefix.lastIndex(where: \.isWhitespace) ?? prefix.endIndex
        return (String(prefix[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines) + "…", true)
    }
}
