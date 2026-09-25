import Foundation

struct PlaybackShufflePolicy {
    enum HistoryAvailability: String {
        case notRead, unavailable, empty, available
    }

    struct Order {
        let entries: [PlaybackQueue.Entry]
        let recentCount: Int
        let weighted: Bool
        var effectiveStyle: ShuffleStyle { weighted ? .fewerRepeats : .random }
    }

    let historyAvailability: HistoryAvailability
    private let style: ShuffleStyle
    private var recentWeights: [String: Double] = [:]

    init(style: ShuffleStyle, history: [ListeningEvent]?, now: Date) {
        self.style = style
        historyAvailability = history.map { $0.isEmpty ? .empty : .available } ?? .unavailable
        guard let history, LibraryValidation.isValidDate(now) else { return }
        var sessions: [UUID: ListeningEvent] = [:]
        var conflicting = Set<UUID>()
        for event in history {
            guard !conflicting.contains(event.id), LibraryValidation.isValidDate(event.startedAt),
                  LibraryValidation.isValidListeningSeconds(event.listenedSeconds, now: now),
                  (try? LibraryValidation.validateTrack(event.track)) != nil else { continue }
            if var previous = sessions[event.id] {
                guard previous.track.id == event.track.id, previous.startedAt == event.startedAt else {
                    sessions.removeValue(forKey: event.id)
                    conflicting.insert(event.id)
                    continue
                }
                previous.listenedSeconds = max(previous.listenedSeconds, event.listenedSeconds)
                // Conflicting duration snapshots must not lower qualification merely because of input order.
                if ListeningAnalytics.qualifyingSeconds(for: event.track) > ListeningAnalytics.qualifyingSeconds(for: previous.track) {
                    previous.track = event.track
                }
                sessions[event.id] = previous
            } else {
                sessions[event.id] = event
            }
        }
        for event in sessions.values {
            let ageDays = now.timeIntervalSince(event.startedAt) / 86_400
            guard ageDays >= 0, ageDays < 7,
                  event.listenedSeconds >= ListeningAnalytics.qualifyingSeconds(for: event.track) else { continue }
            // Session start is the saved listen timestamp; adding credited seconds would invent an end through pauses.
            let weight = 0.1 + 0.9 * min(ageDays / 7, 1)
            recentWeights[event.track.id] = min(recentWeights[event.track.id] ?? 1, weight)
        }
    }

    func weight(for track: Track) -> Double { style == .fewerRepeats ? recentWeights[track.id] ?? 1 : 1 }

    func order<Generator: RandomNumberGenerator>(_ entries: [PlaybackQueue.Entry], using generator: inout Generator) -> Order {
        let weights = entries.map { weight(for: $0.track) }
        let recentCount = entries.filter { recentWeights[$0.track.id, default: 1] < 1 }.count
        let weighted = style == .fewerRepeats && entries.count > 1 && recentCount > 0
        guard weighted else {
            return Order(entries: entries.shuffled(using: &generator), recentCount: recentCount, weighted: false)
        }
        // Independent exponential races implement weighted sampling without replacement for every occurrence.
        let bucketCount: UInt64 = UInt64(1) << 52
        let scale: Double = Double(bucketCount)
        let priorities: [(index: Int, priority: Double)] = entries.indices.map { index -> (index: Int, priority: Double) in
            // 52-bit midpoints keep both endpoints strictly inside (0, 1), including extreme generator values.
            let random: UInt64 = generator.next()
            let bucket: UInt64 = random >> 12
            let midpoint: Double = Double(bucket) + 0.5
            let unit: Double = midpoint / scale
            let priority: Double = -log(unit) / weights[index]
            return (index: index, priority: priority)
        }
        let ranked = priorities.sorted {
            $0.priority == $1.priority ? $0.index < $1.index : $0.priority < $1.priority
        }
        return Order(entries: ranked.map { entries[$0.index] }, recentCount: recentCount, weighted: true)
    }
}
