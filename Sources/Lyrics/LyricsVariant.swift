import CryptoKit
import Foundation

enum LyricsScript: String, CaseIterable, Sendable {
    case latin, gurmukhi, devanagari, bengali, tamil, telugu, arabic, mixed, other

    var title: String {
        switch self {
        case .latin: "Latin"
        case .gurmukhi: "Gurmukhi"
        case .devanagari: "Devanagari"
        case .bengali: "Bengali"
        case .tamil: "Tamil"
        case .telugu: "Telugu"
        case .arabic: "Arabic Script"
        case .mixed: "Mixed Scripts"
        case .other: "Published Text"
        }
    }

    static func detect(_ text: String) -> Self {
        var counts: [Self: Int] = [:]
        for scalar in text.unicodeScalars
            where CharacterSet.letters.contains(scalar) && !CharacterSet.nonBaseCharacters.contains(scalar) {
            let script: Self
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF, 0xAB30...0xAB6F: script = .latin
            case 0x0A00...0x0A7F: script = .gurmukhi
            case 0x0900...0x097F: script = .devanagari
            case 0x0980...0x09FF: script = .bengali
            case 0x0B80...0x0BFF: script = .tamil
            case 0x0C00...0x0C7F: script = .telugu
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF: script = .arabic
            default: script = .other
            }
            counts[script, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total >= 4, let largest = counts.max(by: { $0.value < $1.value }) else { return .other }
        guard Double(largest.value) / Double(total) >= 0.9 else { return .mixed }
        return largest.key
    }

    func isOriginalScript(for languageCode: String?) -> Bool {
        guard let languageCode else { return false }
        let parts = languageCode.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-")
        switch parts.first {
        case "pa", "pan":
            if parts.contains("arab") { return self == .arabic }
            if parts.contains("guru") { return self == .gurmukhi }
            return self == .gurmukhi || self == .arabic
        case "hi", "hin", "mr", "ne": return self == .devanagari
        case "bn", "ben": return self == .bengali
        case "ta", "tam": return self == .tamil
        case "te", "tel": return self == .telugu
        case "ur", "urd", "ar", "ara": return self == .arabic
        case "en", "eng": return self == .latin
        default: return false
        }
    }
}

struct LyricsVariant: Identifiable, Sendable {
    let document: LyricsDocument
    let id: String
    let script: LyricsScript

    init(_ document: LyricsDocument) {
        self.document = document
        id = document.selectionID
        script = LyricsScript.detect(document.displayText)
    }

    func title(recordingLanguage: String?) -> String {
        let scriptTitle: String
        if script.isOriginalScript(for: recordingLanguage) {
            scriptTitle = "Original Script · \(script.title)"
        } else if script == .latin, let recordingLanguage,
                  LyricsScript.allCases.contains(where: { $0 != .latin && $0.isOriginalScript(for: recordingLanguage) }) {
            scriptTitle = "Romanised / Latin"
        } else { scriptTitle = script.title }
        return "\(scriptTitle) · \(document.kind == .synced ? "Timed" : "Plain") · \(document.source)"
    }
}

extension LyricsDocument {
    var displayText: String {
        kind == .synced ? lines.map(\.text).joined(separator: "\n") : (plainText ?? "")
    }

    func samePublishedContent(as other: LyricsDocument) -> Bool {
        source == other.source && sourceID == other.sourceID && kind == other.kind
            && plainText == other.plainText && lines == other.lines
            && (providerTrackID == other.providerTrackID || providerTrackID == nil || other.providerTrackID == nil)
    }

    /// Content and timestamps identify a selection; fetch dates must not reset following or a saved in-memory choice.
    var selectionID: String {
        var hash = SHA256()
        for value in [source, sourceID.map(String.init) ?? "", providerTrackID ?? "", kind.rawValue, plainText ?? ""] {
            hash.update(data: Data(value.utf8))
            hash.update(data: Data([0]))
        }
        for line in lines {
            hash.update(data: Data("\(line.id):\(line.time):\(line.text)\u{0}".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func validateVariant(for track: Track) throws {
        guard trackID == track.id else { throw LyricsLookupError.recordingMismatch }
        guard source.utf8.count <= 1_024, (attributionText?.utf8.count ?? 0) <= 4_096,
              (plainText?.utf8.count ?? 0) <= LRCParser.maximumSourceBytes,
              lines.count <= LRCParser.maximumLines,
              lines.reduce(0, { $0 + $1.text.utf8.count }) <= LRCParser.maximumSourceBytes else {
            throw MusicServiceError.invalidResponse
        }
        switch kind {
        case .plain:
            guard lines.isEmpty, !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  displayText.components(separatedBy: .newlines).count <= LRCParser.maximumLines else {
                throw MusicServiceError.invalidResponse
            }
        case .synced:
            guard lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  Set(lines.map(\.id)).count == lines.count,
                  lines.allSatisfy({ $0.time.isFinite && $0.time >= 0 }),
                  zip(lines, lines.dropFirst()).allSatisfy({ $0.0.time <= $0.1.time }) else {
                throw MusicServiceError.invalidResponse
            }
            if let duration = LyricsMatcher.validDuration(track.duration),
               lines.contains(where: { !$0.text.isEmpty && $0.time >= duration }) {
                throw LyricsLookupError.recordingMismatch
            }
        case .instrumental, .unavailable: break
        }
    }
}
