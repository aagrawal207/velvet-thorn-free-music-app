import Foundation

/// A display projection of the selected document, never a second lyrics source.
struct TVLyricsTimeline {
    enum Mode: String { case timed, untimed, instrumental, unavailable }

    struct LineWindow: Equatable {
        var previous: LyricLine?
        var current: LyricLine?
        var next: LyricLine?
    }

    let mode: Mode
    let lines: [LyricLine]
    let pages: [String]
    static let charactersPerPage = 140

    init(document: LyricsDocument) {
        if document.kind == .instrumental {
            mode = .instrumental
            lines = []
            pages = []
            return
        }
        guard document.kind != .unavailable,
              document.lines.count <= LRCParser.maximumLines,
              document.lines.reduce(0, { $0 + $1.text.utf8.count }) <= LRCParser.maximumSourceBytes,
              (document.plainText?.utf8.count ?? 0) <= LRCParser.maximumSourceBytes else {
            mode = .unavailable
            lines = []
            pages = []
            return
        }
        let timed = document.lines.filter { $0.time.isFinite && $0.time >= 0 }
            .enumerated().sorted {
                $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
            }.map(\.element)
        if document.kind == .synced,
           timed.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            mode = .timed
            lines = timed
            pages = []
        } else {
            let plain = document.plainText ?? document.lines.map(\.text).joined(separator: "\n")
            let chunks = Self.paginate(plain)
            mode = chunks.isEmpty ? .unavailable : .untimed
            lines = []
            pages = chunks
        }
    }

    func window(at position: TimeInterval, offset: TimeInterval, duration: TimeInterval?) -> LineWindow {
        guard mode == .timed, position.isFinite, position >= 0 else { return LineWindow() }
        if let duration, duration.isFinite, duration > 0, position >= duration { return LineWindow() }
        guard let index = LRCParser.activeLineIndex(in: lines, at: position,
                                                   offset: LyricsTiming.boundedOffset(offset), duration: duration) else {
            return LineWindow(next: lines.first)
        }
        return LineWindow(previous: index > 0 ? lines[index - 1] : nil,
                          current: lines[index], next: index + 1 < lines.count ? lines[index + 1] : nil)
    }

    private static func paginate(_ text: String) -> [String] {
        var chunks: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var remainder = trimmed[...]
            while !remainder.isEmpty {
                guard chunks.count < LRCParser.maximumLines else { return [] }
                let limit = remainder.index(remainder.startIndex, offsetBy: charactersPerPage,
                                            limitedBy: remainder.endIndex) ?? remainder.endIndex
                var end = limit
                if limit < remainder.endIndex,
                   let space = remainder[..<limit].lastIndex(where: { $0.isWhitespace }),
                   remainder.distance(from: remainder.startIndex, to: space) >= charactersPerPage / 2 {
                    end = space
                }
                chunks.append(String(remainder[..<end]))
                remainder = remainder[end...]
                while remainder.first?.isWhitespace == true { remainder = remainder.dropFirst() }
            }
        }
        return chunks
    }
}
