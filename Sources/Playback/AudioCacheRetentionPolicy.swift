import Foundation

struct AudioCacheRetentionPolicy: Sendable {
    static let maximumQualifyingPlays = 20
    static let maximumHistoryTracks = AudioCacheLimit.gb5.maximumSongs
    private static let day: TimeInterval = 86_400

    struct Signal: Equatable, Sendable {
        var lastListenedAt: Date
        var qualifyingSessions: [Date] = []
    }

    struct Candidate: Equatable, Sendable {
        let id: String
        let bytes: Int64
        let accessedAt: Date
    }

    private(set) var signals: [String: Signal] = [:]

    init(events: [ListeningEvent] = [], now: Date = Date(), retaining trackIDs: Set<String> = []) {
        guard LibraryValidation.isValidDate(now) else { return }
        let oldest = now.addingTimeInterval(-90 * Self.day)
        let frequencyCutoff = now.addingTimeInterval(-30 * Self.day)
        var sessions: [UUID: ListeningEvent] = [:]
        var conflicting = Set<UUID>()
        for event in events {
            guard AudioCache.isValidTrackID(event.track.id), !conflicting.contains(event.id),
                  LibraryValidation.isValidDate(event.startedAt), event.startedAt >= oldest, event.startedAt <= now,
                  LibraryValidation.isValidListeningSeconds(event.listenedSeconds, now: now),
                  (try? LibraryValidation.validateTrack(event.track)) != nil else { continue }
            if let previous = sessions[event.id] {
                guard previous.track.id == event.track.id, previous.startedAt == event.startedAt else {
                    sessions.removeValue(forKey: event.id)
                    conflicting.insert(event.id)
                    continue
                }
                if previous.listenedSeconds >= event.listenedSeconds { continue }
            }
            sessions[event.id] = event
        }
        for event in sessions.values {
            // A session start is the durable listen timestamp; pauses make start plus credited seconds an invented end.
            var signal = signals[event.track.id] ?? Signal(lastListenedAt: event.startedAt)
            signal.lastListenedAt = max(signal.lastListenedAt, event.startedAt)
            if event.startedAt >= frequencyCutoff,
               event.listenedSeconds >= ListeningAnalytics.qualifyingSeconds(for: event.track) {
                signal.qualifyingSessions.append(event.startedAt)
                signal.qualifyingSessions.sort(by: >)
                if signal.qualifyingSessions.count > Self.maximumQualifyingPlays { signal.qualifyingSessions.removeLast() }
            }
            signals[event.track.id] = signal
        }
        // Every stored recording keeps its signal; the remaining slots remember high-value admission candidates.
        let capacity = max(Self.maximumHistoryTracks, trackIDs.count)
        if signals.count > capacity {
            let ordered = signals.keys.sorted { left, right in
                if trackIDs.contains(left) != trackIDs.contains(right) { return trackIDs.contains(left) }
                let lhs = score(for: left, now: now), rhs = score(for: right, now: now)
                if lhs != rhs { return lhs > rhs }
                if signals[left]!.lastListenedAt != signals[right]!.lastListenedAt {
                    return signals[left]!.lastListenedAt > signals[right]!.lastListenedAt
                }
                return left < right
            }
            signals = Dictionary(uniqueKeysWithValues: ordered.prefix(capacity).map { ($0, signals[$0]!) })
        }
    }

    func qualifyingPlays(for id: String, now: Date) -> Int {
        guard LibraryValidation.isValidDate(now), let signal = signals[id] else { return 0 }
        let cutoff = now.addingTimeInterval(-30 * Self.day)
        return signal.qualifyingSessions.filter { $0 >= cutoff && $0 <= now }.count
    }

    func lastListen(for id: String, now: Date) -> Date? {
        guard LibraryValidation.isValidDate(now), let date = signals[id]?.lastListenedAt,
              date <= now, now.timeIntervalSince(date) <= 90 * Self.day else { return nil }
        return date
    }

    func score(for id: String, now: Date) -> Double {
        let frequency = log1p(Double(qualifyingPlays(for: id, now: now))) / log(21)
        let recency = lastListen(for: id, now: now).map { pow(2, -now.timeIntervalSince($0) / (7 * Self.day)) } ?? 0
        return 0.55 * recency + 0.45 * frequency
    }

    func evictionOrder(_ candidates: [Candidate], now: Date) -> [Candidate] {
        candidates.sorted { left, right in
            let lhs = score(for: left.id, now: now), rhs = score(for: right.id, now: now)
            if lhs != rhs { return lhs < rhs }
            let leftListen = lastListen(for: left.id, now: now) ?? .distantPast
            let rightListen = lastListen(for: right.id, now: now) ?? .distantPast
            if leftListen != rightListen { return leftListen < rightListen }
            if left.accessedAt != right.accessedAt { return left.accessedAt < right.accessedAt }
            return left.id < right.id
        }
    }
}
