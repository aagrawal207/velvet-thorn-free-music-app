import Foundation

enum ListeningAnalytics {
    static func summary(
        events: [ListeningEvent], for window: ListeningWindow, now: Date,
        calendar: Calendar = .current
    ) -> ListeningSummary {
        guard LibraryValidation.isValidDate(now),
              let cutoff = calendar.date(byAdding: .day, value: -window.days, to: now) else {
            return ListeningSummary()
        }

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
        var tracks: [String: RankedTrack] = [:]
        var artists: [String: RankedArtist] = [:]
        var lastTrackListen: [String: Date] = [:]
        var lastArtistListen: [String: Date] = [:]
        var secondsByDay: [Date: TimeInterval] = [:]

        for event in validEvents where event.startedAt >= cutoff {
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
            for name in event.track.artists {
                let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = displayName.precomposedStringWithCanonicalMapping.lowercased()
                guard !key.isEmpty, creditedArtists.insert(key).inserted else { continue }
                // Collaborators each receive credit; the overall total is counted once above.
                var artist = artists[key] ?? RankedArtist(name: displayName, seconds: 0, plays: 0)
                artist.seconds += seconds
                artist.plays += plays
                artists[key] = artist
                lastArtistListen[key] = max(lastArtistListen[key] ?? .distantPast, event.startedAt)
            }
            secondsByDay[calendar.startOfDay(for: event.startedAt), default: 0] += seconds
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

        var day = calendar.startOfDay(for: cutoff)
        let today = calendar.startOfDay(for: now)
        while day <= today {
            result.days.append(ListeningDay(date: day, seconds: secondsByDay[day, default: 0]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }

        // The current streak is independent of the selected recap window and survives a quiet morning.
        let listenedDays = Set(validEvents.map { calendar.startOfDay(for: $0.startedAt) })
        result.streak = currentStreakDays(in: listenedDays, now: now, calendar: calendar).count
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
