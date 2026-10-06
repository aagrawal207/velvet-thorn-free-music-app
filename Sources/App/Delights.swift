import Foundation

/// The hidden delights. Raw values are the bounded `kind` dimension of `event=delight`.
enum DelightKind: String, CaseIterable, Sendable {
    case equalizerMax, equalizerMin, lateNight, likesCentury, repeatTen, aboutTabla, sleepPaused, anniversary
}

/// Every delight line in one place, so tests and docs/DELIGHTS.md quote the same words.
enum DelightCopy {
    static let equalizerMax = "Every band at max. Your neighbours have been notified."
    static let equalizerMin = "Every band at minimum. Bold of you to call this music."
    static let likesCentury = "Century! 100 liked songs. Sachin would be proud."
    static let repeatTen = "Ten times in a row. The song is flattered. Slightly concerned, but flattered."
    static let aboutFirst = "There’s no secret menu. Nice try, though."
    static let aboutAgain = "Still no secret menu. Persistence noted."
    static let sleepForeground = "Shh. Paused for you."

    static func sleepBackground(time: String) -> String {
        "Paused at \(time), like you asked. You were asleep anyway."
    }
}

// MARK: Equalizer

enum EqualizerExtreme: Sendable {
    case maximum, minimum

    /// Every band pinned to one end of the slider range; a partial curve never qualifies.
    init?(gains: [Double], range: ClosedRange<Double> = EqualizerSettings.gainRange) {
        guard gains.count == EqualizerPreset.bandFrequencies.count else { return nil }
        if gains.allSatisfy({ $0 >= range.upperBound }) {
            self = .maximum
        } else if gains.allSatisfy({ $0 <= range.lowerBound }) {
            self = .minimum
        } else {
            return nil
        }
    }

    var message: String { self == .maximum ? DelightCopy.equalizerMax : DelightCopy.equalizerMin }
    var kind: DelightKind { self == .maximum ? .equalizerMax : .equalizerMin }
}

// MARK: Late night

/// The full player's eyebrow from 2:00 to 3:59 local time. The option follows the calendar day, so one night keeps
/// one line while the next night moves on to another.
struct LateNightEyebrow: Equatable, Sendable {
    static let hours = 2...3
    static let optionCount = 5

    let option: Int
    let text: String
    let spokenText: String

    static func line(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> LateNightEyebrow? {
        let hour = calendar.component(.hour, from: date)
        guard hours.contains(hour) else { return nil }
        let option = ((night(at: date, calendar: calendar) % optionCount) + optionCount) % optionCount
        let words = phrase(option: option, hour: hour)
        return LateNightEyebrow(option: option, text: words.text, spokenText: words.spoken)
    }

    static func night(at date: Date, calendar: Calendar) -> Int {
        calendar.ordinality(of: .day, in: .era, for: date) ?? 0
    }

    private static func phrase(option: Int, hour: Int) -> (text: String, spoken: String) {
        switch option {
        case 0: return (text: "STILL UP? SAME.", spoken: "Still up? Same.")
        case 1: return (text: "SLEEP IS JUST A RUMOUR", spoken: "Sleep is just a rumour")
        case 2: return (text: "\(hour) A.M. BOLD CHOICE", spoken: "\(hour) a.m. Bold choice.")
        case 3: return (text: "BEDTIME WAS HOURS AGO", spoken: "Bedtime was hours ago")
        default: return (text: "YOUR PILLOW MISSES YOU", spoken: "Your pillow misses you")
        }
    }
}

// MARK: Likes

enum LikesCentury {
    static let milestone = 100

    /// The caller reports only explicit likes that added a song, so imports, merges and promotions never arrive here.
    static func celebrates(likedCount: Int, alreadyShown: Bool) -> Bool {
        !alreadyShown && likedCount == milestone
    }
}

/// About 1.5 seconds of hearts over the screen; the overlay reads `startedAt` against the display clock.
struct HeartBurst: Equatable, Sendable {
    static let duration: TimeInterval = 1.5
    let id = UUID()
    let startedAt: Date
}

// MARK: Repeat One

/// Consecutive starts of one queue occurrence under Repeat One. Each recording is celebrated once per app session.
struct RepeatStreak: Sendable {
    static let celebratedStart = 10

    private(set) var occurrence: UUID?
    private(set) var count = 0
    private var lastStart: UUID?
    private var celebrated: Set<String> = []

    /// True on the start that completes ten in a row for a recording not yet celebrated this session.
    mutating func trackStarted(trackID: String, occurrence: UUID?, repeatMode: RepeatMode) -> Bool {
        lastStart = occurrence
        guard repeatMode == .one, let occurrence else {
            reset()
            return false
        }
        if occurrence == self.occurrence {
            count += 1
        } else {
            self.occurrence = occurrence
            count = 1
        }
        return count == Self.celebratedStart && celebrated.insert(trackID).inserted
    }

    /// Turning Repeat One on counts the play already under way as the first; any other change ends the streak.
    mutating func repeatModeChanged(to mode: RepeatMode) {
        if mode == .one, let lastStart {
            occurrence = lastStart
            count = 1
        } else {
            reset()
        }
    }

    private mutating func reset() {
        occurrence = nil
        count = 0
    }
}

// MARK: About

/// Seven taps on the Version row, each within `maximumGap` of the previous one, complete a round.
struct AboutTapCounter: Sendable {
    static let requiredTaps = 7
    static let maximumGap: TimeInterval = 1.5

    private(set) var taps = 0
    private(set) var rounds = 0
    private var lastTap: Date?

    mutating func tap(at date: Date) -> String? {
        if let lastTap, date >= lastTap, date.timeIntervalSince(lastTap) <= Self.maximumGap {
            taps += 1
        } else {
            taps = 1
        }
        lastTap = date
        guard taps == Self.requiredTaps else { return nil }
        taps = 0
        rounds += 1
        return rounds == 1 ? DelightCopy.aboutFirst : DelightCopy.aboutAgain
    }
}

// MARK: Sleep timer

enum SleepPauseMessage {
    static let backgroundWindow: TimeInterval = 12 * 60 * 60

    /// The return-to-app line for a pause that happened in the background; nil once it is too old to be news.
    static func background(pausedAt: Date, now: Date, locale: Locale = .autoupdatingCurrent,
                           timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        let elapsed = now.timeIntervalSince(pausedAt)
        guard elapsed >= 0, elapsed <= backgroundWindow else { return nil }
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        return DelightCopy.sleepBackground(time: pausedAt.formatted(style))
    }
}

// MARK: Anniversary

/// Where listening began: the earliest lifetime receipt or retained event, with the song only when that event survives.
struct ListeningOrigin: Equatable, Sendable {
    let startedAt: Date
    let firstSongTitle: String?

    static func make(coverageStartedAt coverage: Date?, events: [ListeningEvent]) -> ListeningOrigin? {
        let earliest = events.min { $0.startedAt < $1.startedAt }
        guard let earliest else { return coverage.map { ListeningOrigin(startedAt: $0, firstSongTitle: nil) } }
        guard let coverage else {
            return ListeningOrigin(startedAt: earliest.startedAt, firstSongTitle: earliest.track.title)
        }
        // Receipts round starts to the millisecond; a later retained event means the first session's detail expired.
        guard earliest.startedAt.timeIntervalSince(coverage) <= 0.001 else {
            return ListeningOrigin(startedAt: coverage, firstSongTitle: nil)
        }
        return ListeningOrigin(startedAt: min(coverage, earliest.startedAt), firstSongTitle: earliest.track.title)
    }
}

struct AnniversaryCard: Equatable, Sendable {
    let years: Int
    /// Calendar year of the anniversary day; dismissal stores it, so the next anniversary still appears.
    let anniversaryYear: Int
    let title: String
    let message: String
}

enum AnniversaryDelight {
    static let visibleDays = 7

    static func card(origin: ListeningOrigin?, lifetimeSeconds: TimeInterval, historyEnabled: Bool,
                     dismissedYear: Int?, now: Date, calendar: Calendar) -> AnniversaryCard? {
        guard historyEnabled, let origin else { return nil }
        let first = calendar.startOfDay(for: origin.startedAt)
        let today = calendar.startOfDay(for: now)
        guard let years = calendar.dateComponents([.year], from: first, to: today).year, years >= 1,
              let anniversary = calendar.date(byAdding: .year, value: years, to: first),
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: anniversary), to: today).day,
              (0..<visibleDays).contains(days) else { return nil }
        let year = calendar.component(.year, from: anniversary)
        guard dismissedYear != year else { return nil }
        let hours = lifetimeSeconds.isFinite ? Int(max(0, lifetimeSeconds) / 3_600) : 0
        return AnniversaryCard(years: years, anniversaryYear: year, title: title(years: years),
                               message: message(hours: hours, firstSongTitle: origin.firstSongTitle))
    }

    static func title(years: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en")
        formatter.numberStyle = .spellOut
        let words = formatter.string(from: NSNumber(value: years)) ?? String(years)
        let count: String = words.prefix(1).uppercased() + words.dropFirst()
        return "\(count) \(years == 1 ? "year" : "years") of Velvet Thorn."
    }

    static func message(hours: Int, firstSongTitle: String?) -> String {
        let together: String
        if hours < 1 {
            together = "Less than an hour together."
        } else if hours == 1 {
            together = "1 hour together."
        } else {
            together = "\(hours.formatted()) hours together."
        }
        guard let title = firstSongTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return together
        }
        return "\(together) Your first song was \(title), and honestly, it shows."
    }
}
