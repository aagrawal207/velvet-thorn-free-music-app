import Foundation

enum ArtistSpotlightLanguageSignals {
    static func titleHint(_ title: String) -> ArtistSongLanguageResult? {
        guard title.utf8.count <= 2_048 else { return nil }
        let named = ArtistSongLanguage.allCases.filter { language in
            let pattern = #"(?i)(?:\(|\[|\s[-–—]\s)\s*"# + language.title + #"(?:\s+version)?\s*(?:\)|\]|$)"#
            return title.range(of: pattern, options: .regularExpression) != nil
        }
        if named.count > 1 { return .unclassified(.conflictingEvidence) }
        let script = scriptHint(title, source: .titleScript, minimumLetters: 4)
        if let language = named.first {
            if case .likely(let other, _) = script, other != language { return .unclassified(.conflictingEvidence) }
            return .likely(language, source: .titleLabel)
        }
        return script
    }

    static func scriptHint(_ text: String, source: ArtistSongLanguageResult.Source,
                           minimumLetters: Int = 80) -> ArtistSongLanguageResult? {
        let letters = String(text.prefix(12_000)).unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= minimumLetters else { return nil }
        // Devanagari is shared by several languages, and Latin script is common in transliterations.
        // These narrower scripts still yield suggestions, never confirmed filter membership.
        let scripts: [(ArtistSongLanguage, ClosedRange<UInt32>)] = [(.tamil, 0x0B80...0x0BFF), (.telugu, 0x0C00...0x0C7F)]
        for (language, range) in scripts {
            let count = letters.filter { range.contains($0.value) }.count
            if Double(count) / Double(letters.count) >= 0.98 { return .likely(language, source: source) }
        }
        return nil
    }

    static func combine(lyrics: ArtistSongLanguageResult?, metadata: ArtistSongLanguageResult?, title: String) -> ArtistSongLanguageResult {
        if lyrics?.hasConflictingEvidence == true || metadata?.hasConflictingEvidence == true {
            return .unclassified(.conflictingEvidence)
        }
        // A work with an explicit unsupported/undetermined language is not a missing metadata response.
        if metadata == .unclassified(.uncertainLanguage) { return .unclassified(.uncertainLanguage) }
        if let a = lyrics?.language, let b = metadata?.language, a != b { return .unclassified(.conflictingEvidence) }
        if let metadata, metadata.language != nil { return metadata }
        if let lyrics, lyrics.language != nil { return lyrics }
        if let lyrics, lyrics.isLikely { return lyrics }
        return titleHint(title) ?? lyrics ?? .unclassified(.noMatchedLyrics)
    }
}
