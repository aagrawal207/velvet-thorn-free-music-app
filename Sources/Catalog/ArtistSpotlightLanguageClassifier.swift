import Foundation
import NaturalLanguage

enum ArtistSpotlightLanguageClassifier {
    typealias Hypotheses = @Sendable (String) -> [String: Double]

    static func classify(_ document: LyricsDocument, for track: Track,
                         hypotheses: Hypotheses = recognize) -> ArtistSongLanguageResult {
        guard isMatched(document, to: track) else { return .unclassified(.noMatchedLyrics) }
        let text = document.kind == .synced && !document.lines.isEmpty
            ? document.lines.map(\.text).joined(separator: "\n") : (document.plainText ?? "")
        var seen = Set<String>()
        let lines = String(text.prefix(12_000)).components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("["), seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
        let normalized = LyricsMatcher.normalized(lines.joined(separator: "\n"))
        let words = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 20, Set(words).count >= 12,
              normalized.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 80 else {
            return .unclassified(.insufficientText)
        }
        guard let language = confidentLanguage(hypotheses(normalized), threshold: 0.92),
              hasOriginalScript(normalized, language: language),
              language != .english || hasEnglishGrammar(words, minimumDistinct: 6) else {
            return ArtistSpotlightLanguageSignals.scriptHint(normalized, source: .lyricsScript) ?? .unclassified(.uncertainLanguage)
        }
        if language == .english {
            for line in lines {
                let lineWords = LyricsMatcher.normalized(line).split(whereSeparator: \.isWhitespace).map(String.init)
                if lineWords.count >= 8, !hasEnglishGrammar(lineWords, minimumDistinct: 2) {
                    return .unclassified(.uncertainLanguage)
                }
            }
        }

        // Whole-text detection can hide a translated verse. Each substantial window must agree,
        // including the ending; a short final window is joined to the preceding one.
        var windows: [[String]] = []
        let windowSize = language == .english ? 20 : 40
        for offset in stride(from: 0, to: words.count, by: windowSize) {
            let chunk = Array(words[offset..<min(offset + windowSize, words.count)])
            if chunk.count < 20, !windows.isEmpty { windows[windows.count - 1] += chunk }
            else { windows.append(chunk) }
        }
        for window in windows {
            let sample = window.joined(separator: " ")
            guard confidentLanguage(hypotheses(sample), threshold: 0.88) == language,
                  hasOriginalScript(sample, language: language),
                  language != .english || hasEnglishGrammar(window, minimumDistinct: 4) else {
                return .unclassified(.uncertainLanguage)
            }
        }
        return .identified(language, source: document.providerSource?.isRecordingLinked == true ? .linkedLyrics : .matchedLyrics)
    }

    static func recognize(_ text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum: 4).map { ($0.key.rawValue, $0.value) })
    }

    private static func confidentLanguage(_ hypotheses: [String: Double], threshold: Double) -> ArtistSongLanguage? {
        let ranked = hypotheses.filter { $0.value.isFinite && (0...1).contains($0.value) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let first = ranked.first, first.value >= threshold,
              first.value - (ranked.dropFirst().first?.value ?? 0) >= 0.20 else { return nil }
        return ArtistSongLanguage(rawValue: first.key)
    }

    private static func hasOriginalScript(_ text: String, language: ArtistSongLanguage) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let matching = letters.filter { scalar in
            switch language {
            case .hindi: (0x0900...0x097F).contains(scalar.value)
            case .bengali: (0x0980...0x09FF).contains(scalar.value)
            case .tamil: (0x0B80...0x0BFF).contains(scalar.value)
            case .telugu: (0x0C00...0x0C7F).contains(scalar.value)
            case .english: scalar.value < 0x0250 || (0x1E00...0x1EFF).contains(scalar.value)
            }
        }
        return Double(matching.count) / Double(letters.count) >= 0.96
    }

    private static func hasEnglishGrammar(_ words: [String], minimumDistinct: Int) -> Bool {
        // Latin letters alone are not evidence of English: romanized Hindi and Tamil use them too.
        let functionWords: Set<String> = [
            "the", "and", "you", "your", "with", "this", "that", "have", "from", "they", "will", "when",
            "are", "was", "were", "would", "could", "should", "there", "their", "these", "those", "because",
            "through", "what", "where", "while", "which", "about", "them", "into", "without", "before", "after", "we", "our",
        ]
        let matches = words.filter { functionWords.contains($0) }
        return Set(matches).count >= minimumDistinct && Double(matches.count) / Double(words.count) >= 0.20
    }

    private static func isMatched(_ document: LyricsDocument, to track: Track) -> Bool {
        // Each provider verifies the recording before supplying this identity. Never invent missing
        // duration/album fields to re-score it; linked lyrics retain their exact provider track ID.
        guard document.trackID == track.id, let source = document.providerSource,
              (source.isRecordingLinked ? CatalogText.videoID(track.id) != nil : (document.sourceID ?? 0) > 0),
              document.kind == .plain || document.kind == .synced,
              let title = document.matchedTitle, let artist = document.matchedArtist else { return false }
        let requested = LyricsMatcher.cleanTitle(track.title, artists: track.artists)
        let matched = LyricsMatcher.cleanTitle(title, artists: [artist])
        guard agrees(requested, matched) else { return false }
        let expected = LyricsMatcher.artistParts(track.artists)
        let actual = LyricsMatcher.artistParts([artist])
        guard !actual.isEmpty, actual.allSatisfy({ name in expected.contains { agrees($0, name) } }) else { return false }
        return source.isRecordingLinked || actual.count == expected.count || (track.artists.count > 1 && actual.count * 2 >= expected.count)
    }

    private static func agrees(_ left: String, _ right: String) -> Bool {
        guard !LyricsMatcher.normalized(left).isEmpty, !LyricsMatcher.normalized(right).isEmpty else { return false }
        if SearchRelevance.normalize(left) == SearchRelevance.normalize(right) { return true }
        guard let a = LyricsMatcher.romanized(left), let b = LyricsMatcher.romanized(right) else { return false }
        return !a.isEmpty && a == b
    }
}
