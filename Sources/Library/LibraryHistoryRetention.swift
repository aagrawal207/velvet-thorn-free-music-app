import Foundation

enum LibraryHistoryRetention {
    // The margin beyond a rolling year keeps whole local days without pruning recap inputs.
    static let days = 400

    @discardableResult
    static func apply(to document: inout LibraryDocument, now: Date, calendar: Calendar = .current) -> Bool {
        guard LibraryValidation.isValidDate(now),
              let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) else {
            return false
        }
        let eventCount = document.events.count
        let recentCount = document.recentlyPlayed.count
        if document.events.contains(where: { $0.startedAt < cutoff }) {
            let listenedDays = Set(document.events.map { calendar.startOfDay(for: $0.startedAt) })
            let streakDays = ListeningAnalytics.currentStreakDays(in: listenedDays, now: now, calendar: calendar)
            var keptStreakDays = Set<Date>()
            document.events.removeAll { event in
                guard event.startedAt < cutoff else { return false }
                // One actual session per older streak day preserves the current streak without its full history.
                let day = calendar.startOfDay(for: event.startedAt)
                return !streakDays.contains(day) || !keptStreakDays.insert(day).inserted
            }
        }
        document.recentlyPlayed.removeAll { $0.playedAt < cutoff }
        return document.events.count != eventCount || document.recentlyPlayed.count != recentCount
    }
}
