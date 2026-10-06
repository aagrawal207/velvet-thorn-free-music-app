import Foundation

/// Immutable, bounded history prepared away from UI callbacks. The controller keys reuse by the actual library revision.
struct MomentHistorySelection: Sendable {
    private let selected: [ListeningEvent]
    private let preparedAt: Date
    private let learningSince: Date
    private let calendar: Calendar
    private let cutoff: Date
    private let nextEligibility: Date?

    nonisolated static func prepareAsync(events: [ListeningEvent], learningSince: Date, now: Date,
                                        calendar: Calendar) async -> Self {
        prepare(events: events, learningSince: learningSince, now: now, calendar: calendar)
    }

    static func prepare(events: [ListeningEvent], learningSince: Date, now: Date,
                        calendar: Calendar) -> Self {
        let cutoff = calendar.date(byAdding: .day, value: -MomentLearning.retentionDays, to: now) ?? now
        var nextEligibility: Date?
        let eligible = events.filter { event in
            guard LibraryValidation.isValidDate(event.startedAt), event.startedAt >= cutoff,
                  event.startedAt >= learningSince, event.listenedSeconds.isFinite, event.listenedSeconds > 0,
                  event.listenedSeconds >= ListeningAnalytics.qualifyingSeconds(for: event.track),
                  event.track.isAudioRecording != false, !event.track.id.isEmpty,
                  event.track.id.utf8.count <= 512 else { return false }
            let eligibility = max(event.startedAt, Date(timeIntervalSince1970: event.listenedSeconds))
            if eligibility > now {
                nextEligibility = min(nextEligibility ?? eligibility, eligibility)
                return false
            }
            return true
        }.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }
        var seen = Set<UUID>()
        var selected: [ListeningEvent] = []
        for event in eligible where seen.insert(event.id).inserted {
            selected.append(event)
            if selected.count == MomentLearning.maximumEvents { break }
        }
        return Self(selected: selected, preparedAt: now, learningSince: learningSince, calendar: calendar,
                    cutoff: cutoff, nextEligibility: nextEligibility)
    }

    func canReuse(learningSince: Date, now: Date, calendar: Calendar) -> Bool {
        guard LibraryValidation.isValidDate(now), now >= preparedAt, self.learningSince == learningSince,
              self.calendar == calendar, nextEligibility.map({ now < $0 }) ?? true,
              let cutoff = calendar.date(byAdding: .day, value: -MomentLearning.retentionDays, to: now),
              cutoff >= self.cutoff else { return false }
        return true
    }

    func events(at now: Date) -> [ListeningEvent] {
        guard let cutoff = calendar.date(byAdding: .day, value: -MomentLearning.retentionDays, to: now) else { return [] }
        // Once the oldest selected event expires, every omitted older event is expired too; no backfill scan is needed.
        return selected.filter { $0.startedAt >= cutoff }
    }
}
