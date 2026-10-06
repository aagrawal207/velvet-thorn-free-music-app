import Foundation
import Observation
import OSLog
import SwiftUI

@MainActor @Observable
final class MomentMixController {
    let store: MomentMixStore
    let motion = MomentMotionMonitor()
    private(set) var collections: [MusicCollection] = []
    private(set) var summaries: [MomentSummary] = []
    @ObservationIgnored private var lastHistoryRevision: UInt64?
    @ObservationIgnored private var lastHistoryLibrary: ObjectIdentifier?
    @ObservationIgnored private var preparedHistory: (library: ObjectIdentifier, revision: UInt64, selection: MomentHistorySelection)?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparationGeneration = UUID()
    @ObservationIgnored private(set) var historyPreparationCount: UInt64 = 0
    @ObservationIgnored private var projectedRevision: UInt64?
    @ObservationIgnored private var projectedDay: String?
    @ObservationIgnored private var favorites: [Track] = []
    @ObservationIgnored private var playlists: [UserPlaylist] = []
    @ObservationIgnored private var disliked: Set<String> = []
    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private var historyEpoch: UUID?
    @ObservationIgnored private var epochReader: (@MainActor (LibraryStore) -> UUID?)?
    @ObservationIgnored private var observationGeneration = UUID()
    @ObservationIgnored private let usesDeviceSignals: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: () -> Calendar
    @ObservationIgnored private let prepareHistory: @Sendable ([ListeningEvent], Date, Date, Calendar) async -> MomentHistorySelection
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Moments")

    init(store: MomentMixStore, usesDeviceSignals: Bool = false,
         now: @escaping () -> Date = { Date() }, calendar: @escaping () -> Calendar = { .current },
         prepareHistory: @escaping @Sendable ([ListeningEvent], Date, Date, Calendar) async -> MomentHistorySelection = MomentHistorySelection.prepareAsync) {
        self.store = store
        self.usesDeviceSignals = usesDeviceSignals
        self.now = now
        self.calendar = calendar
        self.prepareHistory = prepareHistory
    }

    func capture(for events: [ListeningEvent] = []) -> MomentMixStore.ContextCapture? {
        guard usesDeviceSignals, store.canLearn, library?.preferences.saveListeningHistory == true else { return nil }
        let date = now()
        let learned = Set(store.snapshot.evidence.map(\.eventID))
        guard events.contains(where: { !learned.contains($0.id) && abs($0.startedAt.timeIntervalSince(date)) <= 30 }) else { return nil }
        let capture = store.capture(route: motion.route(MomentAudioRoute.current(), now: date), now: date)
        if let capture { store.stageContext(for: events, capture: capture) }
        return capture
    }

    /// Observe published slices, not event counts or raw player progress. Existing library callbacks remain installed.
    func startObserving(library: LibraryStore, historyEpoch: @escaping @MainActor (LibraryStore) -> UUID?) {
        observationGeneration = UUID()
        self.library = library
        epochReader = historyEpoch
        synchronize(library: library, historyEpoch: historyEpoch(library))
        observeLibrary()
    }

    private func observeLibrary() {
        guard let library, let epochReader else { return }
        let generation = observationGeneration
        withObservationTracking {
            _ = library.historyRevision
            _ = library.preferences.saveListeningHistory
            _ = library.favorites
            _ = library.playlists
            _ = library.dislikedTrackIDs
            _ = library.hasLoadedDocument
            _ = library.requiresReload
            _ = epochReader(library)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.observationGeneration,
                      let library = self.library, let readEpoch = self.epochReader else { return }
                self.synchronize(library: library, historyEpoch: readEpoch(library))
                self.observeLibrary()
            }
        }
    }

    /// Call after durable history revisions and library-choice changes, and on foreground/calendar changes.
    func synchronize(library: LibraryStore, historyEpoch: UUID?, localEventIDs: Set<UUID> = [],
                     capture: MomentMixStore.ContextCapture? = nil) {
        self.library = library
        self.historyEpoch = historyEpoch
        let date = now(), calendar = self.calendar()
        guard LibraryValidation.isValidDate(date) else { suspend(); return }
        let day = MomentLearning.dayKey(date, calendar: calendar) + "|" + calendar.timeZone.identifier
        let projectionKey = day + "|\(calendar.identifier)|" + MomentTime.at(date, calendar: calendar).rawValue
        guard library.hasLoadedDocument, !library.requiresReload else {
            suspend()
            return
        }
        let wasLearning = store.canLearn
        _ = store.synchronizePrivacy(historyEnabled: library.preferences.saveListeningHistory,
                                      historyEpoch: historyEpoch, now: date)
        if let capture { store.stageContext(forEventIDs: localEventIDs, capture: capture) }
        if usesDeviceSignals { motion.configure(enabled: store.canLearn && store.snapshot.preferences.motionEnabled) }
        guard store.canLearn else {
            discardPreparedHistory()
            collections = []
            summaries = []
            projectedRevision = nil
            return
        }
        guard let preparedHistory, preparedHistory.library == ObjectIdentifier(library),
              preparedHistory.revision == library.historyRevision,
              preparedHistory.selection.canReuse(learningSince: store.snapshot.learningSince, now: date, calendar: calendar) else {
            collections = collections.compactMap { collection in
                guard !store.snapshot.preferences.disabledMixIDs.contains(String(collection.id.dropFirst("moment.".count))) else { return nil }
                var filtered = collection
                filtered.tracks.removeAll { library.dislikedTrackIDs.contains($0.id) }
                return filtered.tracks.count >= MomentLearning.minimumTracks ? filtered : nil
            }
            prepareHistoryIfNeeded(library: library, now: date, calendar: calendar)
            return
        }
        let sourceEvents = preparedHistory.selection.events(at: date)
        let cutoff = calendar.date(byAdding: .day, value: -MomentLearning.retentionDays, to: date) ?? date
        let evidenceExpired = store.snapshot.evidence.contains { $0.startedAt < cutoff }
        let historyChanged = lastHistoryRevision != library.historyRevision || lastHistoryLibrary != ObjectIdentifier(library)
        if historyChanged || evidenceExpired || !wasLearning || capture != nil || projectedRevision != store.revision || projectedDay != projectionKey {
            if store.observe(selection: preparedHistory.selection, now: date, calendar: calendar) {
                lastHistoryRevision = library.historyRevision
                lastHistoryLibrary = ObjectIdentifier(library)
            } else if store.canLearn {
                collections = []
                summaries = []
                projectedRevision = nil
                return
            }
        }
        let choicesChanged = favorites != library.favorites || playlists != library.playlists || disliked != library.dislikedTrackIDs
        guard choicesChanged || projectedRevision != store.revision || projectedDay != projectionKey else { return }
        favorites = library.favorites
        playlists = library.playlists
        disliked = library.dislikedTrackIDs
        let evidence = store.snapshot.evidence.filter { $0.startedAt >= cutoff && $0.startedAt <= date }
        let ids = Set(evidence.map(\.eventID))
        let qualifiedSpans = Dictionary(uniqueKeysWithValues: evidence.map { ($0.eventID, $0.endedAt.timeIntervalSince($0.startedAt)) })
        let events = sourceEvents.filter { ids.contains($0.id) }.map { event in
            var qualified = event
            qualified.listenedSeconds = qualifiedSpans[event.id] ?? 30
            return qualified
        }
        let profile = TasteProfile.build(events: events, favorites: favorites, playlists: playlists,
                                         recents: [], disliked: library.disliked, now: calendar.startOfDay(for: date))
        let candidates = events.map(\.track) + favorites + playlists.flatMap(\.tracks)
        var available: [String: Track] = [:]
        for track in candidates where track.isAudioRecording != false && !disliked.contains(track.id) {
            guard available.count < MomentLearning.maximumCandidates else { break }
            if available[track.id] == nil { available[track.id] = track }
        }
        let current = MomentContext.at(date, calendar: calendar)
        summaries = MomentLearning.summaries(evidence).sorted { left, right in
            let l = relevance(left), r = relevance(right)
            return l == r ? left.id < right.id : l > r
        }
        let recurringIDs = Set(summaries.filter(\.isRecurring).map(\.id))
        var selections = store.snapshot.selectionDay == day
            ? store.snapshot.selectedTrackIDs.filter { recurringIDs.contains($0.key) } : [:]
        let generated: [MusicCollection] = summaries.compactMap { summary in
            guard var mix = MomentLearning.collection(for: summary, library: candidates, profile: profile,
                                                     preferences: store.snapshot.preferences, periodKey: day) else { return nil }
            if let saved = selections[summary.id] {
                mix.tracks = saved.compactMap { available[$0] }
                mix.artworkURL = mix.tracks.first?.artworkURL
                guard mix.tracks.count >= MomentLearning.minimumTracks else { return nil }
            } else {
                selections[summary.id] = mix.tracks.map(\.id)
            }
            return mix
        }
        guard store.saveSelections(selections, day: day) else {
            collections = []
            projectedRevision = nil
            return
        }
        collections = generated
        projectedRevision = store.revision
        projectedDay = projectionKey
        let trackCount = generated.reduce(0) { $0 + $1.tracks.count }
        log.info("event=moment_mixes mixes=\(generated.count) tracks=\(trackCount)")

        func relevance(_ summary: MomentSummary) -> Int {
            (summary.context.weekend == current.weekend ? 100_000 : 0)
                + (summary.context.time == current.time ? 10_000 : 0) + summary.days
        }
    }

    func reset(historyEpoch: UUID?) {
        discardPreparedHistory()
        motion.stop()
        _ = store.reset(historyEpoch: historyEpoch, now: now())
        collections = []
        summaries = []
        favorites = []
        playlists = []
        disliked = []
        lastHistoryRevision = nil
        projectedRevision = nil
        self.historyEpoch = historyEpoch
    }

    func setLearningEnabled(_ enabled: Bool) {
        guard store.setLearningEnabled(enabled, now: now()) else { return }
        refresh()
    }

    func setMixEnabled(_ enabled: Bool, context: MomentContext) {
        guard store.setMixEnabled(enabled, context: context) else { return }
        refresh()
    }

    func setMotionEnabled(_ enabled: Bool) {
        guard !enabled || (usesDeviceSignals && motion.isAvailable), store.setMotionEnabled(enabled) else { return }
        if usesDeviceSignals { motion.configure(enabled: enabled, allowPrompt: enabled) }
        refresh()
    }

    func retryStorage() {
        guard store.reload() else { return }
        discardPreparedHistory()
        lastHistoryRevision = nil
        refresh()
    }

    var settingsContexts: [MomentContext] {
        let ids = Set(summaries.map(\.id)).union(store.snapshot.preferences.disabledMixIDs)
        return MomentContext.all.filter { ids.contains($0.id) }
    }

    var canEnableMotion: Bool { usesDeviceSignals && motion.isAvailable && store.canLearn }

    private func refresh() {
        guard let library else { return }
        if let epochReader { synchronize(library: library, historyEpoch: epochReader(library)) }
        else { synchronize(library: library, historyEpoch: historyEpoch) }
    }

    private func suspend() {
        discardPreparedHistory()
        store.suspend()
        motion.stop()
        collections = []
        summaries = []
        lastHistoryRevision = nil
        projectedRevision = nil
    }

    private func prepareHistoryIfNeeded(library: LibraryStore, now: Date, calendar: Calendar) {
        guard preparationTask == nil else { return }
        let source = library.events
        let sourceID = ObjectIdentifier(library), revision = library.historyRevision
        let floor = store.snapshot.learningSince, epoch = store.snapshot.historyEpoch
        let generation = preparationGeneration, prepare = prepareHistory
        historyPreparationCount &+= 1
        preparationTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                await prepare(source, floor, now, calendar)
            }.value
            guard let self else { return }
            self.preparationTask = nil
            guard !Task.isCancelled else { return }
            if generation == self.preparationGeneration, let library = self.library,
               ObjectIdentifier(library) == sourceID, library.historyRevision == revision,
               library.hasLoadedDocument, !library.requiresReload, library.preferences.saveListeningHistory,
               self.store.canLearn, self.store.snapshot.learningSince == floor, self.store.snapshot.historyEpoch == epoch {
                self.preparedHistory = (sourceID, revision, result)
                self.lastHistoryRevision = nil
                self.log.debug("event=moment_history_preparation outcome=applied")
            } else {
                self.log.debug("event=moment_history_preparation outcome=superseded")
            }
            self.refresh()
        }
    }

    private func discardPreparedHistory() {
        preparationGeneration = UUID()
        preparedHistory = nil
        lastHistoryRevision = nil
        lastHistoryLibrary = nil
    }

    /// Await the scheduled projection in tests or explicit consumers; playback acknowledgments never wait for it.
    func waitForPendingPreparation() async {
        while let preparationTask { await preparationTask.value }
    }

    isolated deinit { preparationTask?.cancel() }
}

private struct MomentMixControllerKey: EnvironmentKey {
    static let defaultValue: MomentMixController? = nil
}

extension EnvironmentValues {
    var momentMixController: MomentMixController? {
        get { self[MomentMixControllerKey.self] }
        set { self[MomentMixControllerKey.self] = newValue }
    }
}
