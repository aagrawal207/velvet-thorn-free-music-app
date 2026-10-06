import Foundation

enum TrailingTimeStyle: String, Codable, CaseIterable, Sendable {
    case songLength, remaining

    var title: String {
        switch self {
        case .songLength: "Song length"
        case .remaining: "Time remaining"
        }
    }
}

/// What an upward swipe over the player's artwork or heading opens.
enum PlayerSwipeUpAction: String, Codable, CaseIterable, Sendable {
    case lyrics, queue, moreOptions, off

    var title: String {
        switch self {
        case .lyrics: "Lyrics"
        case .queue: "Queue"
        case .moreOptions: "More options"
        case .off: "Off"
        }
    }
}

enum AudioQualityPreference: String, Codable, CaseIterable, Sendable {
    case best, balanced, dataSaver

    var title: String {
        switch self {
        case .best: "Best available"
        case .balanced: "Balanced"
        case .dataSaver: "Data saver"
        }
    }

    var detail: String {
        switch self {
        case .best: "Highest bitrate offered, including higher tiers when available"
        case .balanced: "Up to 160 kbps"
        case .dataSaver: "Up to 64 kbps"
        }
    }

    /// Bits per second; nil leaves source ranking without a ceiling.
    var maximumBitRate: Int? {
        switch self {
        case .best: nil
        case .balanced: 160_000
        case .dataSaver: 64_000
        }
    }
}
