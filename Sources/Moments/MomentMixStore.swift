import Foundation
import Observation
import OSLog

@MainActor
protocol MomentMixPersistence {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

struct MomentMixStorageFailure: Error { }

@MainActor
final class MomentMixFilePersistence: MomentMixPersistence {
    static let maximumBytes = 1 << 20
    let url: URL

    init(url: URL) { self.url = url }

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GanaBajana/Moments", isDirectory: true)
            .appendingPathComponent("moments.json")
    }

    func read() throws -> Data? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch {
            if Self.isMissingFile(error) { return nil }
            throw error
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw MomentMixStorageFailure() }
        return data
    }

    static func isMissingFile(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(POSIXErrorCode.ENOENT.rawValue) }
        guard error.domain == NSCocoaErrorDomain,
              error.code == CocoaError.Code.fileReadNoSuchFile.rawValue || error.code == CocoaError.Code.fileNoSuchFile.rawValue else { return false }
        // A wrapper must not turn EACCES or ENOTDIR into permission to create a replacement store.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(POSIXErrorCode.ENOENT.rawValue)
        }
        return true
    }

    func write(_ data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw MomentMixStorageFailure() }
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

@MainActor @Observable
final class MomentMixStore {
    private(set) var snapshot: MomentMixSnapshot
    private(set) var revision: UInt64 = 0
    private(set) var errorMessage: String?
    private(set) var resetPending = false
    private(set) var historyEnabled = false
    @ObservationIgnored private let persistence: (any MomentMixPersistence)?
    @ObservationIgnored private var baseline: Data?
    @ObservationIgnored private var blocked = false
    @ObservationIgnored private var synchronizedEpoch = false
    @ObservationIgnored private var pendingReset: MomentMixSnapshot?
    @ObservationIgnored private var captureGeneration = UUID()
    @ObservationIgnored private var pendingContexts: [UUID: ContextCapture] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Moments")

    struct ContextCapture: Sendable {
        let generation: UUID
        let capturedAt: Date
        let route: MomentRoute
    }

    init(persistence: (any MomentMixPersistence)? = nil, now: Date = Date()) {
        self.persistence = persistence
        snapshot = MomentMixSnapshot(learningSince: now)
        do {
            if let data = try persistence?.read() {
                baseline = data
                let loaded = try JSONDecoder().decode(MomentMixSnapshot.self, from: data)
                try Self.validate(loaded)
                snapshot = loaded
            }
        } catch {
            blocked = true
            errorMessage = "Moment mixes couldn’t be read. The saved file has been kept."
        }
    }

    var canLearn: Bool {
        historyEnabled && synchronizedEpoch && snapshot.preferences.learningEnabled && !blocked && !resetPending
    }

    /// Unavailable library state is not evidence of a privacy reset; preserve the last durable file.
    func suspend() {
        historyEnabled = false
        synchronizedEpoch = false
        retireCaptures()
    }

    /// Capture immediately before the existing durable callback awaits; never attribute a later route to old playback.
    func capture(route: MomentRoute, now: Date = Date()) -> ContextCapture? {
        guard canLearn else { return nil }
        let allowedRoute = route == .active && !snapshot.preferences.motionEnabled ? .general : route
        return ContextCapture(generation: captureGeneration, capturedAt: now, route: allowedRoute)
    }

    /// Pending context contains no play credit. Qualification still requires an event in the durable library.
    func stageContext(for events: [ListeningEvent], capture: ContextCapture) {
        guard canLearn, capture.generation == captureGeneration else { return }
        let learned = Set(snapshot.evidence.map(\.eventID))
        for event in events where abs(event.startedAt.timeIntervalSince(capture.capturedAt)) <= 30
            && event.startedAt >= snapshot.learningSince && !learned.contains(event.id) {
            if pendingContexts[event.id] == nil && pendingContexts.count < 128 {
                pendingContexts[event.id] = capture
            }
        }
    }

    /// Post-durability IDs may arrive while history preparation is pending; freshness is checked against the stored event.
    func stageContext(forEventIDs ids: Set<UUID>, capture: ContextCapture) {
        guard canLearn, capture.generation == captureGeneration else { return }
        let learned = Set(snapshot.evidence.map(\.eventID))
        for id in ids where !learned.contains(id) && pendingContexts[id] == nil {
            guard pendingContexts.count < 128 else { break }
            pendingContexts[id] = capture
        }
    }

    /// The epoch is the library's existing persisted listeningHistoryEpoch, exposed read-only by the coordinator.
    @discardableResult
    func synchronizePrivacy(historyEnabled: Bool, historyEpoch: UUID?, now: Date = Date()) -> Bool {
        let changed = self.historyEnabled != historyEnabled
        self.historyEnabled = historyEnabled
        if changed { retireCaptures() }
        if snapshot.historyEpoch != historyEpoch {
            synchronizedEpoch = true
            return reset(historyEpoch: historyEpoch, now: now)
        }
        if resetPending, !retryReset() {
            synchronizedEpoch = false
            return false
        }
        var next = snapshot
        if historyEnabled && snapshot.historyWasEnabled == false {
            next.learningSince = now
            next.evidence = []
            next.selectedTrackIDs = [:]
            next.selectionDay = nil
        }
        next.historyWasEnabled = historyEnabled
        synchronizedEpoch = save(next)
        return synchronizedEpoch
    }

    /// Pass cumulative stored events, not checkpoint deltas. UUIDs cross the qualification threshold only once.
    @discardableResult
    func observe(events: [ListeningEvent], localEventIDs: Set<UUID> = [], capture: ContextCapture? = nil,
                 now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard canLearn, LibraryValidation.isValidDate(now) else { return false }
        let selection = MomentHistorySelection.prepare(events: events, learningSince: snapshot.learningSince,
                                                       now: now, calendar: calendar)
        if let capture { stageContext(forEventIDs: localEventIDs, capture: capture) }
        return observe(selection: selection, now: now, calendar: calendar)
    }

    @discardableResult
    func observe(selection: MomentHistorySelection, now: Date, calendar: Calendar) -> Bool {
        guard canLearn, LibraryValidation.isValidDate(now),
              selection.canReuse(learningSince: snapshot.learningSince, now: now, calendar: calendar) else { return false }
        pendingContexts = pendingContexts.filter { now.timeIntervalSince($0.value.capturedAt) <= 3_600 }
        let existing = Dictionary(uniqueKeysWithValues: snapshot.evidence.map { ($0.eventID, $0) })
        var next = snapshot
        next.evidence = selection.events(at: now).map { event in
            if let old = existing[event.id], old.trackID == event.track.id, old.startedAt == event.startedAt { return old }
            let route = pendingContexts[event.id].flatMap {
                abs(event.startedAt.timeIntervalSince($0.capturedAt)) <= 30 ? $0.route : nil
            } ?? .general
            let context = MomentContext.at(event.startedAt, route: route, calendar: calendar)
            // A fixed qualified span keeps checkpoint retries from stretching or multiplying inferred sessions.
            let span = ListeningAnalytics.qualifyingSeconds(for: event.track)
            return MomentEvidence(eventID: event.id, trackID: event.track.id, startedAt: event.startedAt,
                                  endedAt: event.startedAt.addingTimeInterval(span),
                                  localDay: MomentLearning.dayKey(event.startedAt, calendar: calendar), context: context)
        }
        guard next != snapshot else { return true }
        let saved = save(next)
        if saved {
            for entry in next.evidence { pendingContexts.removeValue(forKey: entry.eventID) }
            log.info("event=moment_learning outcome=saved evidence=\(next.evidence.count)")
        }
        return saved
    }

    @discardableResult
    func setLearningEnabled(_ enabled: Bool, now: Date = Date()) -> Bool {
        guard enabled != snapshot.preferences.learningEnabled else { return true }
        var next = snapshot
        next.preferences.learningEnabled = enabled
        next.learningSince = now
        next.evidence = []
        next.selectedTrackIDs = [:]
        next.selectionDay = nil
        if !enabled { next.preferences.motionEnabled = false }
        guard save(next) else { return false }
        retireCaptures()
        return true
    }

    @discardableResult
    func setMixEnabled(_ enabled: Bool, context: MomentContext) -> Bool {
        var next = snapshot
        if enabled { next.preferences.disabledMixIDs.remove(context.id) }
        else { next.preferences.disabledMixIDs.insert(context.id) }
        return save(next)
    }

    @discardableResult
    func setMotionEnabled(_ enabled: Bool) -> Bool {
        guard !enabled || canLearn else { return false }
        var next = snapshot
        next.preferences.motionEnabled = enabled
        if !enabled {
            next.evidence.removeAll { $0.context.route == .active }
            next.selectedTrackIDs = next.selectedTrackIDs.filter { !$0.key.hasSuffix(".active") }
        }
        guard save(next) else { return false }
        retireCaptures()
        return true
    }

    /// Called inside the existing post-durability onHistoryCleared closure, including remote/reload boundaries.
    @discardableResult
    func reset(historyEpoch: UUID?, now: Date = Date()) -> Bool {
        retireCaptures()
        var cleared = snapshot
        cleared.historyEpoch = historyEpoch
        cleared.historyWasEnabled = historyEnabled
        cleared.learningSince = now
        cleared.evidence = []
        cleared.selectedTrackIDs = [:]
        cleared.selectionDay = nil
        pendingReset = cleared
        resetPending = true
        // Privacy publication is immediate; failed erasure stays blocked and visible until a retry succeeds.
        snapshot = cleared
        revision &+= 1
        return retryReset()
    }

    @discardableResult
    func retryReset() -> Bool {
        guard let pendingReset else { return !blocked }
        guard save(pendingReset, force: true) else { return false }
        self.pendingReset = nil
        resetPending = false
        log.info("event=moment_reset outcome=saved")
        return true
    }

    /// Repaired/external files require an explicit reload; pending privacy erasure wins over recovered evidence.
    @discardableResult
    func reload() -> Bool {
        do {
            let data = try persistence?.read()
            let recovered = try data.map { try JSONDecoder().decode(MomentMixSnapshot.self, from: $0) }
            if let recovered { try Self.validate(recovered) }
            baseline = data
            blocked = false
            if pendingReset != nil { return retryReset() }
            if let recovered { snapshot = recovered }
            synchronizedEpoch = false
            retireCaptures()
            errorMessage = nil
            revision &+= 1
            return true
        } catch {
            blocked = true
            errorMessage = "Moment mixes couldn’t be reloaded. The saved file has been kept."
            return false
        }
    }

    private func retireCaptures() {
        pendingContexts.removeAll()
        captureGeneration = UUID()
    }

    /// Freeze recording order for the local day; exclusions still apply when projecting the saved IDs.
    @discardableResult
    func saveSelections(_ selections: [String: [String]], day: String) -> Bool {
        guard canLearn else { return false }
        var next = snapshot
        next.selectionDay = day
        next.selectedTrackIDs = selections
        return save(next)
    }

    private func save(_ next: MomentMixSnapshot, force: Bool = false) -> Bool {
        guard !blocked, !resetPending || force else { return false }
        guard force || next != snapshot else { return true }
        do {
            try Self.validate(next)
            if let persistence {
                guard try persistence.read() == baseline else {
                    blocked = true
                    throw MomentMixStorageFailure()
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(next)
                try persistence.write(data)
                baseline = data
            }
            snapshot = next
            revision &+= 1
            errorMessage = nil
            return true
        } catch {
            errorMessage = resetPending
                ? "Moment mixes are hidden. Clearing their saved data needs another try."
                : "Moment mixes couldn’t be saved. Try again."
            log.error("event=moment_storage outcome=failed")
            return false
        }
    }

    private static func validate(_ snapshot: MomentMixSnapshot) throws {
        let ids = Set(MomentContext.all.map(\.id))
        guard snapshot.version == 1, LibraryValidation.isValidDate(snapshot.learningSince),
              snapshot.evidence.count <= MomentLearning.maximumEvents,
              Set(snapshot.evidence.map(\.eventID)).count == snapshot.evidence.count,
              snapshot.preferences.disabledMixIDs.isSubset(of: ids),
              (snapshot.selectionDay?.utf8.count ?? 0) <= 200,
              Set(snapshot.selectedTrackIDs.keys).isSubset(of: ids),
              snapshot.selectedTrackIDs.values.allSatisfy({
                  $0.count <= MomentLearning.maximumTracks && Set($0).count == $0.count
                      && $0.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 }
              }),
              snapshot.evidence.allSatisfy({
                  !$0.trackID.isEmpty && $0.trackID.utf8.count <= 512 && $0.localDay.utf8.count <= 64
                      && LibraryValidation.isValidDate($0.startedAt) && LibraryValidation.isValidDate($0.endedAt)
                      && $0.endedAt >= $0.startedAt && $0.endedAt.timeIntervalSince($0.startedAt) <= 30
              }) else { throw MomentMixStorageFailure() }
    }
}
