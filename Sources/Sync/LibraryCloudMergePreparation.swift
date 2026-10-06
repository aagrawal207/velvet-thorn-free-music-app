import Foundation

struct LibraryCloudMergePreparation: Sendable {
    let candidate: LibraryDocument
    let encoded: Data?
    let baselineData: Data?
    let generation: UUID
    let remoteChanged: Bool
    let historyBoundary: Bool
    let recommendationsChanged: Bool
    let lifetimeChanged: Bool
    let lifetimePublication: LifetimeListeningPublication?

    static func make(incoming: LibrarySyncState, document: LibraryDocument, baselineData: Data?,
                     generation: UUID, now: Date, writer: UUID) throws -> Self {
        try LibrarySyncValidation.validate(incoming, now: now)
        let localState = try document.syncState ?? LibrarySyncJournal.seed(document, now: now, writer: writer)
        var joined = try LibrarySyncMerge.joined(localState, incoming)
        var candidate = try LibrarySyncProjection.materialize(joined, onto: document, now: now)
        let historyBoundary = joined.historyReset != localState.historyReset
            || joined.historyRetirement != localState.historyRetirement
            || candidate.preferences.saveListeningHistory != document.preferences.saveListeningHistory
        if historyBoundary { candidate.listeningHistoryEpoch = UUID() }
        LibrarySyncMerge.compact(&joined, retaining: candidate)
        try LibrarySyncJournal.restoreAggregates(in: &candidate, from: joined)
        candidate.syncState = joined
        try LibraryValidation.validate(candidate, now: now)
        let remoteChanged = joined != localState
        let retainedChanged = candidate.events.count != document.events.count
            || candidate.recentlyPlayed.count != document.recentlyPlayed.count
        var previousRecommendations = localState
        var incomingRecommendations = joined
        previousRecommendations.clock = nil
        incomingRecommendations.clock = nil
        for key in ["shuffleStyle", "shuffleDefaultMigrated"].map({ LibrarySyncKey(.preference, $0) }) {
            previousRecommendations.registers.removeValue(forKey: key)
            incomingRecommendations.registers.removeValue(forKey: key)
        }
        // A shuffle preference or clock-only merge cannot change discovery; mixed content edits still refresh it.
        let recommendationsChanged = historyBoundary || retainedChanged || previousRecommendations != incomingRecommendations
        let needsWrite = document.syncState == nil || remoteChanged || retainedChanged
        let lifetimeChanged = document.lifetimeListening != candidate.lifetimeListening
        let lifetimePublication = lifetimeChanged ? LifetimeListeningPublication(candidate.lifetimeListening, now: now) : nil
        if needsWrite {
            _ = try LibrarySyncCodec.encodeReplica(LibrarySyncReplica(replicaID: writer, state: joined))
        }
        return Self(candidate: candidate, encoded: needsWrite ? try LibraryPersistence.encode(candidate) : nil,
                    baselineData: baselineData, generation: generation, remoteChanged: remoteChanged,
                    historyBoundary: historyBoundary, recommendationsChanged: recommendationsChanged,
                    lifetimeChanged: lifetimeChanged, lifetimePublication: lifetimePublication)
    }
}
