import Foundation

enum LibraryReloadResult: Equatable, Sendable {
    case reloaded
    case historyBoundary
    case failed
}

enum LibraryRecovery {
    static func crossesHistoryBoundary(from previous: LibraryDocument, to current: LibraryDocument, now: Date) -> Bool {
        guard current.preferences.saveListeningHistory,
              previous.preferences.saveListeningHistory == current.preferences.saveListeningHistory,
              previous.listeningHistoryEpoch == current.listeningHistoryEpoch else { return true }

        // Older writers have no privacy epoch; missing or reduced retained history is a conservative reset signal.
        var retained = previous
        LibraryHistoryRetention.apply(to: &retained, now: now)
        let events = Dictionary(uniqueKeysWithValues: current.events.map { ($0.id, $0) })
        if retained.events.contains(where: { event in
            guard let saved = events[event.id] else { return true }
            return saved.track.id != event.track.id
                || abs(saved.startedAt.timeIntervalSince(event.startedAt)) >= 0.001
                || saved.listenedSeconds < event.listenedSeconds
        }) { return true }
        let recentIDs = Set(current.recentlyPlayed.map(\.id))
        return retained.recentlyPlayed.contains { !recentIDs.contains($0.id) }
    }
}
