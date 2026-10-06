import Foundation

enum ListeningAnalytics {
    // Detail retains its own denominator; lifetime totals must never change genre shares or per-recording rankings.
    static func lifetimeHero(_ lifetime: LifetimeListeningSummary) -> ListeningSummary {
        ListeningSummary(seconds: lifetime.seconds, plays: lifetime.plays)
    }

    static func summary(
        events: [ListeningEvent], for window: ListeningWindow, now: Date,
        calendar: Calendar = .current
    ) -> ListeningSummary {
        guard LibraryValidation.isValidDate(now),
              let cutoff = calendar.date(byAdding: .day, value: -window.days, to: now) else {
            return ListeningSummary()
        }
        return summary(events: events, cutoff: cutoff, now: now, calendar: calendar)
    }

    static func allAvailableSummary(events: [ListeningEvent], now: Date,
                                    calendar: Calendar = .current) -> ListeningSummary {
        summary(events: events, cutoff: nil, now: now, calendar: calendar)
    }

    /// `summary(events:for:now:).seconds` without ranking, artists or days, for the recap's previous-window comparison.
    static func listenedSeconds(events: [ListeningEvent], for window: ListeningWindow, now: Date,
                                calendar: Calendar = .current) -> TimeInterval {
        guard LibraryValidation.isValidDate(now),
              let cutoff = calendar.date(byAdding: .day, value: -window.days, to: now) else { return 0 }
        var seenSessions = Set<UUID>()
        var seconds: TimeInterval = 0
        // Same validation and first-occurrence session deduplication as `summary`, which dedupes before the cutoff.
        for event in events where LibraryValidation.isValidDate(event.startedAt) && event.startedAt <= now
            && LibraryValidation.isValidListeningSeconds(event.listenedSeconds, now: now)
            && (try? LibraryValidation.validateTrack(event.track)) != nil
            && seenSessions.insert(event.id).inserted {
            if event.startedAt >= cutoff { seconds += event.listenedSeconds }
        }
        return seconds
    }

    private static func summary(events: [ListeningEvent], cutoff: Date?, now: Date,
                                calendar: Calendar) -> ListeningSummary {
        guard LibraryValidation.isValidDate(now) else { return ListeningSummary() }

        var seenSessions = Set<UUID>()
        let validEvents = events.filter {
            LibraryValidation.isValidDate($0.startedAt) && $0.startedAt <= now
                && LibraryValidation.isValidListeningSeconds($0.listenedSeconds, now: now)
                && (try? LibraryValidation.validateTrack($0.track)) != nil
                && seenSessions.insert($0.id).inserted
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        var result = ListeningSummary()
        var days = DayBuckets(calendar: calendar)
        var artistKeys: [[String]: [(display: String, key: String)]] = [:]
        var tracks: [String: RankedTrack] = [:]
        var artists: [String: RankedArtist] = [:]
        var lastTrackListen: [String: Date] = [:]
        var lastArtistListen: [String: Date] = [:]
        var secondsByDay: [Date: TimeInterval] = [:]

        for event in validEvents {
            if let cutoff, event.startedAt < cutoff { continue }
            let seconds = event.listenedSeconds
            let plays = seconds >= qualifyingSeconds(for: event.track) ? 1 : 0
            result.seconds += seconds
            result.plays += plays

            var track = tracks[event.track.id] ?? RankedTrack(track: event.track, seconds: 0, plays: 0)
            track.seconds += seconds
            track.plays += plays
            tracks[event.track.id] = track
            lastTrackListen[event.track.id] = max(lastTrackListen[event.track.id] ?? .distantPast, event.startedAt)

            var creditedArtists = Set<String>()
            let names = event.track.artists
            let credited: [(display: String, key: String)]
            if let known = artistKeys[names] {
                credited = known
            } else {
                credited = names.map { name in
                    let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (display: displayName, key: displayName.precomposedStringWithCanonicalMapping.lowercased())
                }
                artistKeys[names] = credited
            }
            for (displayName, key) in credited {
                guard !key.isEmpty, creditedArtists.insert(key).inserted else { continue }
                // Collaborators each receive credit; the overall total is counted once above.
                var artist = artists[key] ?? RankedArtist(name: displayName, seconds: 0, plays: 0)
                artist.seconds += seconds
                artist.plays += plays
                artists[key] = artist
                lastArtistListen[key] = max(lastArtistListen[key] ?? .distantPast, event.startedAt)
            }
            secondsByDay[days.start(of: event.startedAt), default: 0] += seconds
        }

        result.topTracks = tracks.values.sorted {
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            if $0.plays != $1.plays { return $0.plays > $1.plays }
            let leftDate = lastTrackListen[$0.id] ?? .distantPast
            let rightDate = lastTrackListen[$1.id] ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.id < $1.id
        }
        result.topArtists = artists.keys.sorted {
            let left = artists[$0]!
            let right = artists[$1]!
            if left.seconds != right.seconds { return left.seconds > right.seconds }
            if left.plays != right.plays { return left.plays > right.plays }
            let leftDate = lastArtistListen[$0] ?? .distantPast
            let rightDate = lastArtistListen[$1] ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return $0 < $1
        }.compactMap { artists[$0] }
        result.uniqueTracks = tracks.count
        result.uniqueArtists = artists.count

        if let cutoff {
            var day = calendar.startOfDay(for: cutoff)
            let today = calendar.startOfDay(for: now)
            while day <= today {
                result.days.append(ListeningDay(date: day, seconds: secondsByDay[day, default: 0]))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        } else {
            // Older streak samples can span years. Keep sparse real days; the UI supplies bounded calendar buckets.
            result.days = secondsByDay.keys.sorted().map { ListeningDay(date: $0, seconds: secondsByDay[$0]!) }
        }

        // The current streak is independent of the selected recap window and survives a quiet morning.
        let listenedDays = Set(validEvents.map { days.start(of: $0.startedAt) })
        result.streak = currentStreakDays(in: listenedDays, now: now, calendar: calendar).count
        return result
    }

    static func languageSummary(
        events: [ListeningEvent], for window: ListeningWindow, now: Date, calendar: Calendar = .current,
        evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [:], overrides: [String: String] = [:]
    ) -> ListeningLanguageSummary {
        let listening = summary(events: events, for: window, now: now, calendar: calendar)
        return languageSummary(listening: listening, evidence: evidence, overrides: overrides)
    }

    static func languageSummary(listening: ListeningSummary,
                                evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [:],
                                overrides: [String: String] = [:]) -> ListeningLanguageSummary {
        guard listening.plays > 0 else { return ListeningLanguageSummary() }
        var result = ListeningLanguageSummary(totalPlays: listening.plays)
        var languages: [ArtistSongLanguage: LanguageListeningStat] = [:]
        for ranked in listening.topTracks where ranked.plays > 0 {
            result.totalSongs += 1
            let track = ranked.track
            let automatic = evidence[LyricsRequestKey(track)].map { [track.id: $0] } ?? [:]
            guard let language = ArtistSpotlight.languageResult(for: track, in: automatic, overrides: overrides)?.language else {
                result.unclassifiedPlays += ranked.plays
                result.unclassifiedSongs += 1
                continue
            }
            var row = languages[language] ?? LanguageListeningStat(language: language, plays: 0, songs: 0, share: 0)
            row.plays += ranked.plays
            row.songs += 1
            row.share = Double(row.plays) / Double(listening.plays)
            languages[language] = row
        }
        result.rows = languages.values.sorted {
            $0.plays == $1.plays ? $0.id < $1.id : $0.plays > $1.plays
        }
        return result
    }

    /// Projects the recap onto genre families: each qualified play spreads its recording's shares over the families.
    /// Plays without evidence stay in the total so the coverage percentage is honest.
    static func genreSummary(
        events: [ListeningEvent], for window: ListeningWindow, now: Date, calendar: Calendar = .current,
        evidence: [LyricsRequestKey: GenreDistribution]
    ) -> ListeningGenreSummary {
        let listening = summary(events: events, for: window, now: now, calendar: calendar)
        return genreSummary(listening: listening, evidence: evidence)
    }

    static func genreSummary(listening: ListeningSummary,
                             evidence: [LyricsRequestKey: GenreDistribution]) -> ListeningGenreSummary {
        guard listening.plays > 0 else { return ListeningGenreSummary() }
        var result = ListeningGenreSummary(totalPlays: listening.plays)
        var plays: [GenreFamily: Double] = [:]
        var songs: [GenreFamily: Int] = [:]
        for ranked in listening.topTracks where ranked.plays > 0 {
            result.totalSongs += 1
            guard let distribution = evidence[LyricsRequestKey(ranked.track)], distribution.isClassified else { continue }
            result.classifiedPlays += ranked.plays
            result.classifiedSongs += 1
            for share in distribution.shares {
                plays[share.family, default: 0] += Double(ranked.plays) * share.share
                songs[share.family, default: 0] += 1
            }
        }
        guard result.classifiedPlays > 0 else { return result }
        result.rows = plays.map { family, weight in
            GenreListeningStat(family: family, plays: weight, songs: songs[family, default: 0],
                               share: weight / Double(result.classifiedPlays))
        }.sorted {
            if $0.plays != $1.plays { return $0.plays > $1.plays }
            return $0.family.order < $1.family.order
        }
        return result
    }

    static func currentStreakDays(in listenedDays: Set<Date>, now: Date, calendar: Calendar) -> Set<Date> {
        var streakDay = calendar.startOfDay(for: now)
        var streak = Set<Date>()
        if !listenedDays.contains(streakDay),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: streakDay) {
            streakDay = yesterday
        }
        while listenedDays.contains(streakDay) {
            streak.insert(streakDay)
            guard let previous = calendar.date(byAdding: .day, value: -1, to: streakDay), previous < streakDay else { break }
            streakDay = previous
        }
        return streak
    }

    static func qualifyingSeconds(for track: Track) -> TimeInterval {
        guard let duration = track.duration, duration.isFinite, duration > 0 else { return 30 }
        return min(30, duration / 2)
    }
}

/// Sessions arrive newest first, so neighbours usually share a local day; reusing that day's bounds replaces a
/// calendar computation per session, which dominated summaries of long histories.
struct DayBuckets {
    let calendar: Calendar
    private var start: Date?
    private var end: Date?

    init(calendar: Calendar) { self.calendar = calendar }

    mutating func start(of date: Date) -> Date {
        if let start, let end, date >= start, date < end { return start }
        let day = calendar.startOfDay(for: date)
        // Adding a calendar day keeps 23- and 25-hour DST days exact; the fallback only disables reuse.
        start = day
        end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return day
    }
}
