import Foundation
import NaturalLanguage

enum ArtistSpotlightLanguageClassifier {
    typealias Hypotheses = @Sendable (String) -> [String: Double]

    static func classify(_ document: LyricsDocument, for track: Track,
                         hypotheses: Hypotheses = recognize) -> ArtistSongLanguageResult {
        guard isMatched(document, to: track) else { return .unclassified(.noMatchedLyrics) }
        let text = originalText(document)
        // Classifying only a prefix can silently omit a guest verse or a translation at the end.
        guard text.count <= 12_000 else { return .unclassified(.uncertainLanguage) }
        let lines = cleanedLines(text)
        let normalized = normalizedLyrics(lines.joined(separator: "\n"))
        let words = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 20, Set(words).count >= 12,
              normalized.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 80 else {
            return .unclassified(.insufficientText)
        }
        let wholeTextLanguage = confidentLanguage(hypotheses(lines.joined(separator: "\n")), threshold: 0.92)
        if hasConflictingSegments(lines, wholeTextLanguage: wholeTextLanguage, hypotheses: hypotheses) {
            return .unclassified(.conflictingEvidence)
        }
        guard let language = wholeTextLanguage,
              hasOriginalScript(normalized, language: language),
              language != .english || hasEnglishGrammar(words, minimumDistinct: 6) else {
            return ArtistSpotlightLanguageSignals.scriptHint(normalized, source: .lyricsScript) ?? .unclassified(.uncertainLanguage)
        }
        if language == .english {
            // A romanized guest verse can be split into lines shorter than an individual-line check.
            var unsupportedWords = 0
            for line in lines {
                let lineWords = normalizedLyrics(line).split(whereSeparator: \.isWhitespace).map(String.init)
                if hasEnglishLineEvidence(line, words: lineWords, scores: hypotheses(line)) { unsupportedWords = 0 }
                else {
                    unsupportedWords += lineWords.count
                    if unsupportedWords >= 8 { return .unclassified(.uncertainLanguage) }
                }
            }
        }

        if let failure = windowFailure(in: lines, language: language, hypotheses: hypotheses) { return .unclassified(failure) }
        return .identified(language, source: document.providerSource?.isRecordingLinked == true ? .linkedLyrics : .matchedLyrics)
    }

    private enum WindowAssessment: Equatable { case accepted, ambiguous, rejected, conflicting }

    private static func windowFailure(in lines: [String], language: ArtistSongLanguage,
                                      hypotheses: Hypotheses) -> ArtistSongLanguageResult.UnknownReason? {
        let text = lines.joined(separator: "\n")
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return .uncertainLanguage }
        var lineBoundaries = [0]
        var boundary = 0
        for line in lines {
            boundary += line.split(whereSeparator: \.isWhitespace).count
            lineBoundaries.append(boundary)
        }

        func originalSample(_ range: Range<Int>) -> String {
            String(text[words[range.lowerBound].startIndex..<words[range.upperBound - 1].endIndex])
        }

        // Raw overlapping cores keep punctuation, contractions, and line breaks available to recognition.
        // Every core must pass its own lexical/script checks before additional context can help it.
        for offset in stride(from: 0, to: words.count, by: 20) {
            let core = offset..<min(offset + 40, words.count)
            var assessment = assessWindow(originalSample(core), language: language, hypotheses: hypotheses)
            if assessment == .ambiguous {
                let context = windowContext(for: core, lineBoundaries: lineBoundaries, wordCount: words.count)
                if context != core { assessment = assessWindow(originalSample(context), language: language, hypotheses: hypotheses) }
            }
            if assessment == .conflicting { return .conflictingEvidence }
            guard assessment == .accepted else { return .uncertainLanguage }
            if core.upperBound == words.count { break }
        }
        return nil
    }

    private static func windowContext(for core: Range<Int>, lineBoundaries: [Int], wordCount: Int) -> Range<Int> {
        // One retry can add at most 20 original words per side, preferring complete neighboring lines.
        let lowerLimit = max(0, core.lowerBound - 20)
        let upperLimit = min(wordCount, core.upperBound + 20)
        let start = lineBoundaries.last { $0 >= lowerLimit && $0 < core.lowerBound } ?? lowerLimit
        let end = lineBoundaries.first { $0 > core.upperBound && $0 <= upperLimit } ?? upperLimit
        return start..<end
    }

    private static func assessWindow(_ text: String, language: ArtistSongLanguage, hypotheses: Hypotheses) -> WindowAssessment {
        let scores = hypotheses(text)
        if let other = credibleLanguage(text, scores: scores), other != language.rawValue { return .conflicting }
        let normalized = normalizedLyrics(text)
        let words = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        guard hasOriginalScript(normalized, language: language),
              language != .english || hasEnglishGrammar(words, minimumDistinct: 4) else { return .rejected }
        let code = confidentCode(scores, threshold: 0.88)
        if code == language.rawValue { return .accepted }
        // A confident alternative, including an unsupported language, cannot be diluted by English context.
        return code == nil ? .ambiguous : .rejected
    }

    #if DEBUG
    struct EnglishLexicalInspection: Sendable {
        struct Line: Sendable {
            let index: Int
            let wordCount: Int
            let lexicalPassOne: Bool
            let lexicalPassTwo: Bool
            let englishConfidence: Double?
            let recognizerAssistedReset: Bool

            var resetsUnsupportedRun: Bool { lexicalPassTwo || recognizerAssistedReset }
        }

        let wholeWordCount: Int
        let wholeLexicalPass: Bool
        let wholeScriptPass: Bool
        let totalLineCount: Int
        let firstRejectedLine: Int?
        let rejectedRunWordCount: Int?
        let lines: [Line]
    }

    // Only numeric/boolean evidence leaves this inspection; lyric text stays in the caller's existing document.
    // Indices follow retained, deduplicated lines, including short lines omitted by the segment recognizer.
    static func englishLexicalInspection(_ document: LyricsDocument, for track: Track,
                                         hypotheses: Hypotheses = recognize) -> EnglishLexicalInspection? {
        guard isMatched(document, to: track) else { return nil }
        let text = originalText(document)
        guard text.count <= 12_000 else { return nil }
        let lines = cleanedLines(text)
        let normalized = normalizedLyrics(lines.joined(separator: "\n"))
        let words = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        var unsupportedWords = 0
        var firstRejectedLine: Int?
        var rejectedRunWordCount: Int?
        var inspected: [EnglishLexicalInspection.Line] = []
        // Omitted lines have no diagnostic verdict; recognizer-assisted decisions require their own scores.
        for (offset, line) in lines.prefix(128).enumerated() {
            let lineWords = normalizedLyrics(line).split(whereSeparator: \.isWhitespace).map(String.init)
            let passesTwo = hasEnglishGrammar(lineWords, minimumDistinct: 2, minimumRatio: 0.12)
            let scores = hypotheses(line)
            let supported = hasEnglishLineEvidence(line, words: lineWords, scores: scores)
            if supported { unsupportedWords = 0 }
            else {
                unsupportedWords += lineWords.count
                if firstRejectedLine == nil, unsupportedWords >= 8 {
                    firstRejectedLine = offset + 1
                    rejectedRunWordCount = unsupportedWords
                }
            }
            let english = scores["en"].flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            inspected.append(.init(index: offset + 1, wordCount: lineWords.count,
                lexicalPassOne: hasEnglishGrammar(lineWords, minimumDistinct: 1, minimumRatio: 0.12),
                lexicalPassTwo: passesTwo, englishConfidence: english, recognizerAssistedReset: supported && !passesTwo))
        }
        return EnglishLexicalInspection(wholeWordCount: words.count,
            wholeLexicalPass: hasEnglishGrammar(words, minimumDistinct: 6),
            wholeScriptPass: hasOriginalScript(normalized, language: .english), totalLineCount: lines.count,
            firstRejectedLine: firstRejectedLine, rejectedRunWordCount: rejectedRunWordCount, lines: inspected)
    }
    #endif

    private static func originalText(_ document: LyricsDocument) -> String {
        document.kind == .synced && !document.lines.isEmpty
            ? document.lines.map(\.text).joined(separator: "\n") : (document.plainText ?? "")
    }

    private static func cleanedLines(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.replacingOccurrences(
                of: #"(?i)^\s*\[(?:verse|chorus|pre[- ]?chorus|post[- ]?chorus|bridge|intro|outro|refrain|hook|instrumental)(?:\s+\d+)?(?:\s*:\s*[^\]]{1,80})?\]\s*"#,
                with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedLyrics(trimmed)
            let words = key.split(whereSeparator: \.isWhitespace).map(String.init)
            // Shared vocalizations supply no language evidence and must not certify English on their own.
            let vocalizations: Set<String> = ["oh", "ooh", "oooh", "ah", "aah", "yeah", "hey", "woah", "whoa", "la", "na", "mm", "mmm", "hmm", "uh"]
            guard words.contains(where: { !vocalizations.contains($0) }), seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    static func recognize(_ text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum: 4).map { ($0.key.rawValue, $0.value) })
    }

    private static func confidentLanguage(_ hypotheses: [String: Double], threshold: Double) -> ArtistSongLanguage? {
        confidentCode(hypotheses, threshold: threshold).flatMap(ArtistSongLanguage.init(rawValue:))
    }

    private static func confidentCode(_ hypotheses: [String: Double], threshold: Double) -> String? {
        let ranked = hypotheses.filter { $0.value.isFinite && (0...1).contains($0.value) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let first = ranked.first, first.value >= threshold,
              first.value - (ranked.dropFirst().first?.value ?? 0) >= 0.20 else { return nil }
        return first.key
    }

    private static func hasConflictingSegments(_ lines: [String], wholeTextLanguage: ArtistSongLanguage?, hypotheses: Hypotheses) -> Bool {
        var languages = Set<String>()
        // Short or lower-confidence lines may never supply a second segment language.
        // A credible segment must still agree with the whole-text classification.
        if let wholeTextLanguage { languages.insert(wholeTextLanguage.rawValue) }
        for line in lines where normalizedLyrics(line).split(whereSeparator: \.isWhitespace).count >= 8 {
            if let language = credibleLanguage(line, scores: hypotheses(line)) { languages.insert(language) }
            if languages.count > 1 { return true }
        }
        return false
    }

    private static func credibleLanguage(_ text: String, scores: [String: Double]) -> String? {
        guard let code = confidentCode(scores, threshold: 0.95), !["und", "mul", "zxx"].contains(code) else { return nil }
        let normalized = normalizedLyrics(text)
        if let language = ArtistSongLanguage(rawValue: code), !hasOriginalScript(normalized, language: language) { return nil }
        let words = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        if code == ArtistSongLanguage.english.rawValue, !hasEnglishGrammar(words, minimumDistinct: 2, minimumRatio: 0.12) { return nil }
        return code
    }

    private static func hasEnglishLineEvidence(_ text: String, words: [String],
                                               scores: @autoclosure () -> [String: Double]) -> Bool {
        if hasEnglishGrammar(words, minimumDistinct: 2, minimumRatio: 0.12) { return true }
        // A repeated pronoun or single anchor can support a line, but recognizer confidence alone cannot.
        return hasEnglishGrammar(words, minimumDistinct: 1, minimumRatio: 0.12)
            && hasOriginalScript(text, language: .english)
            && confidentLanguage(scores(), threshold: 0.97) == .english
    }

    private static func normalizedLyrics(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "’", with: "'").lowercased()
        let contractions = [
            (#"\bwon't\b"#, "will not"), (#"\bcan't\b"#, "can not"), (#"\bain't\b"#, "is not"),
            (#"n't\b"#, " not"), (#"\bi'm\b"#, "i am"),
            (#"\b(you|we|they)'re\b"#, "$1 are"), (#"\b(i|you|we|they)'ve\b"#, "$1 have"),
            (#"\b(i|you|he|she|it|we|they)'ll\b"#, "$1 will"), (#"\b(i|you|he|she|we|they)'d\b"#, "$1 would"),
            (#"\b(he|she|it|that|there|what)'s\b"#, "$1 is"),
        ]
        for (pattern, replacement) in contractions {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return LyricsMatcher.normalized(value)
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

    private static func hasEnglishGrammar(_ words: [String], minimumDistinct: Int, minimumRatio: Double = 0.15) -> Bool {
        // Latin letters alone are not evidence of English: romanized Hindi and Tamil use them too.
        let functionWords: Set<String> = [
            "the", "and", "you", "your", "with", "this", "that", "have", "from", "they", "will", "when",
            "are", "was", "were", "would", "could", "should", "there", "their", "these", "those", "because",
            "through", "what", "where", "while", "which", "about", "them", "into", "without", "before", "after", "we", "our",
            "i", "me", "my", "mine", "he", "him", "his", "she", "her", "it", "its", "is", "am", "be", "been", "being",
            "has", "had", "do", "does", "did", "can", "not", "no", "but", "if", "than", "then", "so", "as", "at", "of", "on",
            "in", "to", "for", "a", "an", "us",
        ]
        let matches = words.filter { functionWords.contains($0) }
        // Short words such as Hindi "is", "me", "to", and "do" can coincide with English function words.
        let anchors = Set(matches).subtracting(["a", "an", "in", "is", "me", "to", "us", "do"])
        return Set(matches).count >= minimumDistinct && anchors.count >= max(1, minimumDistinct / 2)
            && Double(matches.count) / Double(max(1, words.count)) >= minimumRatio
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
