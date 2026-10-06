import Foundation

enum LibraryListeningCheckpointError: Error {
    case busy, stale, retired
}

struct LibraryListeningCheckpointMetrics: Sendable {
    let preparationMilliseconds: Double
    let captureMilliseconds: Double
    let applyMilliseconds: Double
    let outcome: String
    var mainActorMilliseconds: Double { captureMilliseconds + applyMilliseconds }
}

struct LibraryListeningCheckpointPreparation: Sendable {
    let candidate: LibraryDocument
    let encoded: Data
    let documentGeneration: UUID
    let privacyGeneration: UUID
    let contextGeneration: UUID
    let syncChanged: Bool
    let historyChanged: Bool
    let lifetimeChanged: Bool
    let lifetimePublication: LifetimeListeningPublication?
    let preparationMilliseconds: Double
    let captureMilliseconds: Double

    static func make(events: [ListeningEvent], recent: RecentListen?, snapshot: PlaybackSnapshot?,
                     document: LibraryDocument, documentGeneration: UUID, privacyGeneration: UUID,
                     contextGeneration: UUID, now: Date, writer: UUID, captureMilliseconds: Double) throws -> Self {
        let began = ContinuousClock.now
        try Task.checkCancellation()
        var candidate = document
        var checkpoints: [LibrarySyncCheckpoint] = []
        var appended = false
        if document.preferences.saveListeningHistory {
            guard events.count <= PlaybackListeningBuffer.defaultMaximumSessions,
                  Set(events.map(\.id)).count == events.count else {
                throw LibraryStorageError.invalidData("listening checkpoint batch")
            }
            for delta in events {
                try Task.checkCancellation()
                guard LibraryValidation.isValidDate(delta.startedAt), delta.listenedSeconds > 0,
                      LibraryValidation.isValidListeningSeconds(delta.listenedSeconds, now: now) else {
                    throw LibraryStorageError.invalidData("listening checkpoint")
                }
                var event = delta
                if let index = candidate.events.firstIndex(where: { $0.id == delta.id }) {
                    let saved = candidate.events[index]
                    guard saved.track.id == delta.track.id, abs(saved.startedAt.timeIntervalSince(delta.startedAt)) < 0.001 else {
                        throw LibraryStorageError.invalidData("listening session identity")
                    }
                    event.startedAt = saved.startedAt
                    let cumulative = try candidate.lifetimeListening.cumulativeEvent(for: event)
                    event.listenedSeconds = max(event.listenedSeconds + saved.listenedSeconds,
                                               cumulative.listenedSeconds)
                    candidate.events[index] = event
                } else {
                    event = try candidate.lifetimeListening.cumulativeEvent(for: event)
                    candidate.events.append(event)
                    appended = true
                }
                try candidate.lifetimeListening.include(event)
                checkpoints.append(.listening(event))
            }
            if appended {
                candidate.events.sort {
                    $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
                }
            }
            if let recent {
                candidate.recentlyPlayed.removeAll { $0.id == recent.id }
                candidate.recentlyPlayed.insert(recent, at: 0)
                checkpoints.append(.recent(recent))
            }
        }
        if let snapshot { candidate.playback = snapshot }
        try LibraryValidation.validate(candidate, now: now)
        let pruned = LibraryHistoryRetention.apply(to: &candidate, now: now)
        var syncChanged = pruned
        if var state = try LibrarySyncJournal.recordingCheckpoints(checkpoints, previous: document, candidate: candidate,
                                                                  historyWasPruned: pruned, now: now, writer: writer) {
            if document.syncState == nil {
                try LibrarySyncJournal.restoreAggregates(in: &candidate, from: state)
                LibrarySyncMerge.compact(&state, retaining: candidate)
            }
            syncChanged = syncChanged || document.syncState == nil || state.clock != document.syncState?.clock
                || state.registers.count != (document.syncState?.registers.count ?? 0)
            candidate.syncState = state
        }
        try Task.checkCancellation()
        let historyChanged = !document.events.elementsEqual(candidate.events, by: {
            $0.id == $1.id && $0.startedAt == $1.startedAt && $0.listenedSeconds == $1.listenedSeconds && $0.track == $1.track
        })
        let lifetimeChanged = document.lifetimeListening != candidate.lifetimeListening
        let lifetimePublication = lifetimeChanged ? LifetimeListeningPublication(candidate.lifetimeListening, now: now) : nil
        let encoded = try LibraryPersistence.encode(candidate)
        try Task.checkCancellation()
        return Self(candidate: candidate, encoded: encoded, documentGeneration: documentGeneration,
                    privacyGeneration: privacyGeneration, contextGeneration: contextGeneration,
                     syncChanged: syncChanged, historyChanged: historyChanged,
                     lifetimeChanged: lifetimeChanged, lifetimePublication: lifetimePublication,
                    preparationMilliseconds: began.duration(to: .now) / .milliseconds(1), captureMilliseconds: captureMilliseconds)
    }
}
