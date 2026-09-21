import Foundation

enum LRCParser {
    static let maximumSourceBytes = 512 * 1024
    static let maximumLines = 5_000
    private static let metadataTags: Set<String> = ["ar", "al", "ti", "au", "lr", "length", "by", "offset", "re", "tool", "ve"]

    /// LRC's positive offset advances lyrics; the user-facing delay is applied separately.
    static func parse(_ source: String, duration: TimeInterval? = nil) -> [LyricLine] {
        guard source.utf8.count <= maximumSourceBytes else { return [] }
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0
        var nextID = 0

        for rawLine in source.components(separatedBy: .newlines) {
            var remainder = rawLine.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            var times: [TimeInterval] = []

            while remainder.first == "[", let end = remainder.firstIndex(of: "]") {
                let tag = String(remainder[remainder.index(after: remainder.startIndex)..<end])
                guard tag.count <= 128 else { break }
                if let time = timestamp(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let milliseconds = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)),
                          milliseconds.isFinite, abs(milliseconds) <= 3_600_000 {
                    offset = milliseconds / 1_000
                } else {
                    let name = tag.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                    let malformedTime = tag.contains(":") && tag.first.map { $0.isNumber || $0 == "-" || $0 == "+" } == true
                    if !Self.metadataTags.contains(name), !malformedTime, !tag.hasPrefix("#") { break }
                }
                remainder = String(remainder[remainder.index(after: end)...])
                    .trimmingCharacters(in: .whitespaces)
            }

            let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            for time in times {
                guard lines.count < maximumLines else { return [] }
                lines.append(LyricLine(id: nextID, time: time, text: text))
                nextID += 1
            }
        }

        let end = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return lines.compactMap { line -> LyricLine? in
            var adjusted = line
            adjusted.time = max(0, line.time - offset)
            if let end, adjusted.time > end { return nil }
            return adjusted
        }.sorted { lhs, rhs in
            lhs.time == rhs.time ? lhs.id < rhs.id : lhs.time < rhs.time
        }
    }

    /// The next timestamp ends a line, including an explicitly empty instrumental line.
    static func activeLineIndex(in lines: [LyricLine], at position: TimeInterval,
                                offset: TimeInterval = 0, duration: TimeInterval? = nil) -> Int? {
        guard position.isFinite, offset.isFinite, position >= 0, !lines.isEmpty else { return nil }
        if let duration, duration.isFinite, duration > 0, position >= duration { return nil }
        let lyricTime = position - offset
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lines[middle].time <= lyricTime {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower == 0 ? nil : lower - 1
    }

    private static func timestamp(_ tag: String) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...4).contains(parts[0].count),
              parts[0].utf8.allSatisfy({ (48...57).contains($0) }),
              let minutes = Double(parts[0]) else { return nil }
        let secondsParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(secondsParts.count), secondsParts[0].count == 2,
              secondsParts[0].utf8.allSatisfy({ (48...57).contains($0) }),
              let seconds = Double(secondsParts[0]), seconds < 60 else { return nil }
        if secondsParts.count == 2 {
            let digits = secondsParts[1]
            guard (1...9).contains(digits.count), digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        }
        guard let preciseSeconds = Double(parts[1]) else { return nil }
        return minutes * 60 + preciseSeconds
    }
}

enum LyricsTiming {
    static let maximumOffset: TimeInterval = 10
    static let step: TimeInterval = 0.5

    static func boundedOffset(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(maximumOffset, max(-maximumOffset, value)) : 0
    }

    static func seekPosition(for line: LyricLine, offset: TimeInterval,
                             duration: TimeInterval?) -> TimeInterval {
        let position = max(0, line.time + boundedOffset(offset))
        guard let duration, duration.isFinite, duration > 0 else { return position }
        return min(position, duration)
    }
}
