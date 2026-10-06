import Foundation
import OSLog

/// Durable intent is committed before OS submission; one token fences resolution, callbacks and publication.
actor BackgroundDownloadEngine {
    typealias Planner = @Sendable (Track) async throws -> BackgroundDownloadPlan
    typealias Publication = @Sendable (Track, AudioDownloader.Part, AudioCache.Sidecar, DownloadPublicationFence) async throws -> Void
    typealias Promotion = @Sendable (String, DownloadPublicationFence) async throws -> AudioCache.DownloadTierChange
    typealias Save = @Sendable (DownloadQueueRecord, URL) throws -> Void

    private let store: any DownloadTierStore
    private let planner: Planner
    private let publication: Publication
    private let promotion: Promotion
    private let session: any BackgroundDownloadSession
    private let staging: BackgroundDownloadStaging
    private let queueFile: URL
    private let connectivity: any DownloadConnectivity
    private let save: Save
    private let now: @Sendable () -> Date
    private let backoff: [TimeInterval]
    private let allowOpus: Bool
    private var records: [BackgroundPendingDownload] = []
    private var tracks: [String: Track] = [:]
    private var tasks: [UUID: Int] = [:]
    private var retiring: Set<Int> = []
    private var completedDuringRestore: Set<Int> = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var cancelledWork: Set<UUID> = []
    private var fences: [UUID: DownloadPublicationFence] = [:]
    private var fractions: [UUID: Double] = [:]
    private var parked: Set<UUID> = []
    /// Transient planning failures per song this session; they wait longer instead of spending one of three attempts.
    private var transientRetries: [String: Int] = [:]
    static let defaultTransientBackoff: [TimeInterval] = [5, 15, 45, 120]
    private let transientBackoff: [TimeInterval]
    /// A copy the player is already writing usually finishes within a song's length on a working connection.
    static let copyInProgressWait: TimeInterval = 90
    private var eventTask: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var restoring = false
    private var restored = false
    private var foreground = false
    private var allowCellular: Bool
    private(set) var storageFailure = false
    private var onChange: (@Sendable ([DownloadItem]) async -> Void)?
    private var onTierChange: (@Sendable (String, Bool) -> Void)?
    private var onStorageError: (@Sendable (Bool) async -> Void)?
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Downloads")

    init(store: any DownloadTierStore, planner: @escaping Planner, publication: @escaping Publication,
         promotion: @escaping Promotion, session: any BackgroundDownloadSession, staging: BackgroundDownloadStaging,
         queueFile: URL, connectivity: any DownloadConnectivity, allowCellular: Bool = false,
         allowOpus: Bool = OpusNativeAudio.isSupported, backoff: [TimeInterval] = [2, 6],
         transientBackoff: [TimeInterval] = BackgroundDownloadEngine.defaultTransientBackoff,
         now: @escaping @Sendable () -> Date = { Date() }, save: @escaping Save = { try $0.save(to: $1) }) {
        self.store = store
        self.planner = planner
        self.publication = publication
        self.promotion = promotion
        self.session = session
        self.staging = staging
        self.queueFile = queueFile
        self.connectivity = connectivity
        self.allowCellular = allowCellular
        self.allowOpus = allowOpus
        self.backoff = backoff.isEmpty ? [2, 6] : backoff
        self.transientBackoff = transientBackoff
        self.now = now
        self.save = save
    }

    deinit {
        eventTask?.cancel()
        wake?.cancel()
        workers.values.forEach { $0.cancel() }
    }

    var items: [DownloadItem] {
        records.compactMap { record in
            guard let track = tracks[record.id] else { return nil }
            var item = DownloadItem(track: track, enqueuedAt: record.enqueuedAt)
            if record.phase == .failed { item.state = .failed(reason: (record.failure ?? .interrupted).message) }
            else if storageFailure { item.waitingReason = .storage }
            else if record.phase == .staged { item.waitingReason = .processing }
            else if record.phase == .transferring {
                item.state = .downloading(fraction: fractions[record.token] ?? 0)
                if connectivity.isExpensivePath && !allowCellular { item.state = .waitingForWiFi }
                else if connectivity.isOffline { item.waitingReason = .connection }
            } else if !foreground { item.waitingReason = .foregroundResolution }
            else if connectivity.isOffline { item.waitingReason = .connection }
            else if connectivity.isExpensivePath && !allowCellular { item.state = .waitingForWiFi }
            return item
        }
    }

    func setObservers(onChange: @escaping @Sendable ([DownloadItem]) async -> Void,
                      onTierChange: @escaping @Sendable (String, Bool) -> Void,
                      onStorageError: @escaping @Sendable (Bool) async -> Void = { _ in }) async {
        self.onChange = onChange
        self.onTierChange = onTierChange
        self.onStorageError = onStorageError
        startEvents()
        await publish()
    }

    private func startEvents() {
        guard eventTask == nil else { return }
        let events = session.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
    }

    func restore(resolvingTracks lookup: DownloadManager.TrackLookup) async {
        guard (!restored || storageFailure), !restoring else { return }
        restored = false
        fences.values.forEach { $0.cancel() }
        cancelledWork.formUnion(workers.keys)
        workers.values.forEach { $0.cancel() }
        restoring = true
        completedDuringRestore.removeAll()
        defer { restoring = false; completedDuringRestore.removeAll() }
        startEvents()
        // Connect even when the queue is unreadable, so foreign/orphaned OS tasks cannot continue unnoticed.
        let live = await session.allTasks()
        retiring.formIntersection(Set(live.map(\.id)))
        tasks.removeAll()
        do {
            if FileManager.default.fileExists(atPath: queueFile.path) {
                let record = try DownloadQueueRecord.read(from: queueFile)
                records = record.pending ?? record.trackIDs.map { BackgroundPendingDownload(id: $0) }
            }
            let resolved = try await lookup(records.map(\.id))
            tracks = Dictionary(resolved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let desired = records.filter { tracks[$0.id] != nil }
            guard commit(desired) else { throw BackgroundDownloadFailure.staging }
            var adopted = Set<UUID>()
            for task in live {
                guard let token = task.token, let record = records.first(where: { $0.token == token }),
                      record.phase == .transferring, !completedDuringRestore.contains(task.id),
                      adopted.count < 2, adopted.insert(token).inserted,
                      record.allowCellular == allowCellular, task.allowsCellular == allowCellular,
                      (record.expiresAt ?? .distantPast) > now() else { retire(task.id); continue }
                tasks[token] = task.id
                session.resume(task.id)
            }
            for index in records.indices {
                let token = records[index].token
                if records[index].phase != .failed, (try? staging.load(token)) != nil {
                    if let task = tasks.removeValue(forKey: token) { retire(task) }
                    records[index].phase = .staged
                } else if records[index].phase == .transferring || records[index].phase == .staged {
                    if tasks[token] == nil {
                        records[index].phase = records[index].attempts >= 3 ? .failed : .queued
                        records[index].failure = .interrupted
                        records[index].token = UUID()
                        records[index].metadata = nil
                    }
                }
            }
            guard commit(records) else { throw BackgroundDownloadFailure.staging }
            try staging.prune(keeping: Set(records.map(\.token)))
            restored = true
            log.info("event=background_download outcome=reattached count=\(self.tasks.count)")
            await publish()
            pump()
        } catch {
            live.forEach { retire($0.id) }
            storageFailure = true
            log.error("event=background_download outcome=queue_unreadable")
            await publish()
        }
    }

    @discardableResult
    func enqueue(_ wanted: [Track]) async -> Int {
        guard restored, !storageFailure else { return 0 }
        var next = records
        var added = 0
        for track in wanted where AudioCache.isProviderTrackID(track.id) {
            if let index = next.firstIndex(where: { $0.id == track.id }) {
                guard next[index].phase == .failed else { continue }
                transientRetries.removeValue(forKey: track.id)
                if (try? staging.load(next[index].token)) != nil {
                    next[index].phase = .staged
                    next[index].failure = nil
                    next[index].attempts = 0
                } else {
                    staging.remove(next[index].token)
                    next[index] = BackgroundPendingDownload(id: track.id)
                }
            } else {
                guard next.count < DownloadQueueRecord.maximumEntries else { break }
                next.append(BackgroundPendingDownload(id: track.id))
            }
            tracks[track.id] = track
            added += 1
        }
        guard commit(next) else { await publish(); return 0 }
        await publish()
        pump()
        return added
    }

    func retry(_ id: String) async {
        guard let track = tracks[id] else { return }
        _ = await enqueue([track])
    }

    @discardableResult
    func cancel(_ id: String) async -> Bool {
        guard restored else { return false }
        guard let record = records.first(where: { $0.id == id }) else { return true }
        // A failed durable cancellation remains visible and retryable; its delivery is fenced immediately.
        fences[record.token]?.cancel()
        if workers[record.token] != nil { cancelledWork.insert(record.token) }
        workers[record.token]?.cancel()
        if let task = tasks.removeValue(forKey: record.token) { retire(task) }
        guard commit(records.filter { $0.id != id }) else { await publish(); return false }
        staging.remove(record.token)
        fractions.removeValue(forKey: record.token)
        await publish()
        pump()
        return true
    }

    func cancelAll() async {
        guard restored else { return }
        for record in records {
            fences[record.token]?.cancel()
            if workers[record.token] != nil { cancelledWork.insert(record.token) }
            workers[record.token]?.cancel()
            if let task = tasks.removeValue(forKey: record.token) { retire(task) }
        }
        let tokens = records.map(\.token)
        if commit([]) { tokens.forEach { staging.remove($0) } }
        await publish()
    }

    func clearFailed() async {
        guard restored else { return }
        let removed = records.filter { $0.phase == .failed }
        if commit(records.filter { $0.phase != .failed }) { removed.forEach { staging.remove($0.token) } }
        await publish()
    }

    func setForeground(_ active: Bool) async {
        foreground = active
        parked.removeAll()
        if active, restored, !storageFailure {
            var next = records
            var expired: [UUID] = []
            for index in next.indices where next[index].phase == .transferring && (next[index].expiresAt ?? .distantPast) <= now() {
                let token = next[index].token
                if (try? staging.load(token)) != nil { continue }
                expired.append(token)
                next[index].token = UUID()
                next[index].phase = next[index].attempts >= 3 ? .failed : .queued
                next[index].failure = .expired
                next[index].metadata = nil
            }
            if !expired.isEmpty {
                _ = commit(next)
                for token in expired {
                    if let task = tasks.removeValue(forKey: token) { retire(task) }
                }
            }
        }
        if !active {
            // Only resolution/conversion needs runtime. Already submitted OS transfers keep their own lifetime.
            for (token, worker) in workers where tasks[token] == nil { worker.cancel() }
        }
        await publish()
        pump()
    }

    func setAllowCellular(_ allowed: Bool) async {
        guard allowed != allowCellular else { return }
        allowCellular = allowed
        parked.removeAll()
        guard restored else { return }
        var next = records
        var retired: [UUID] = []
        for index in next.indices where next[index].phase == .transferring {
            let token = next[index].token
            retired.append(token)
            if let task = tasks.removeValue(forKey: token) { retire(task) }
            next[index].phase = .queued
            next[index].token = UUID()
            next[index].metadata = nil
            // A policy replacement is not a network failure and does not spend an extra attempt.
            next[index].attempts = max(0, next[index].attempts - 1)
        }
        if commit(next) { retired.forEach { staging.remove($0) } }
        await publish()
        pump()
    }

    func connectivityChanged() async { parked.removeAll(); await publish(); pump() }

    private func pump() {
        guard restored, foreground, !storageFailure else { return }
        wake?.cancel()
        wake = nil
        for record in records where record.phase == .queued || record.phase == .staged {
            guard tasks.count + workers.count + retiring.count < 2 else { break }
            guard workers[record.token] == nil, !parked.contains(record.token) else { continue }
            if let date = record.retryAt, date > now() { continue }
            let fence = DownloadPublicationFence()
            fences[record.token] = fence
            workers[record.token] = Task { [weak self] in await self?.run(record.token, fence: fence) }
        }
        if let date = records.filter({ $0.phase == .queued }).compactMap(\.retryAt).filter({ $0 > now() }).min() {
            let delay = date.timeIntervalSince(now())
            wake = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                await self?.wakeUp()
            }
        }
    }

    private func wakeUp() { pump() }

    private func run(_ token: UUID, fence: DownloadPublicationFence) async {
        defer {
            workers.removeValue(forKey: token)
            cancelledWork.remove(token)
            fences.removeValue(forKey: token)
            pump()
        }
        guard let record = records.first(where: { $0.token == token }), let track = tracks[record.id] else { return }
        var startedAttempt = false
        do {
            // Downloading the song that is playing: join the cache copy being written rather than fetching it twice.
            var complete = await store.hasCompleteCopy(of: record.id, allowOpus: allowOpus)
            if !complete, record.phase != .staged {
                complete = await store.waitForCopyInProgress(of: record.id, allowOpus: allowOpus, seconds: Self.copyInProgressWait)
            }
            try check(token)
            if complete {
                try check(token)
                let result = try await promotion(record.id, fence)
                switch result {
                case .moved, .alreadyThere: await succeeded(token); return
                case .notFound: break
                }
            }
            try check(token)
            if record.phase == .staged {
                guard let receipt = try staging.load(token), let metadata = record.metadata,
                      metadata.fileExtension == receipt.fileExtension,
                      metadata.bytes == 0 || metadata.bytes == receipt.bytes else { throw BackgroundDownloadFailure.invalidMedia }
                let part = AudioDownloader.Part(url: staging.media(token), bytes: receipt.bytes, fileExtension: receipt.fileExtension ?? "")
                try await publication(track, part, metadata, fence)
                try check(token)
                await succeeded(token)
                return
            }
            guard !connectivity.isOffline, allowCellular || !connectivity.isExpensivePath else { parked.insert(token); return }
            guard record.attempts < 3 else { await failed(token, .interrupted); return }
            guard mutate(token, { $0.attempts += 1; $0.retryAt = nil }) else { await publish(); return }
            startedAttempt = true
            let plan = try await planner(track)
            try check(token)
            guard foreground else { throw CancellationError() }
            let request = try plan.request(allowCellular: allowCellular, now: now())
            guard mutate(token, {
                $0.metadata = plan.metadata; $0.expiresAt = plan.expiresAt
                $0.phase = .transferring; $0.allowCellular = allowCellular
            }) else { await publish(); return }
            let id = session.create(request, token: token)
            tasks[token] = id
            session.resume(id)
            log.info("event=background_download outcome=submitted")
            await publish()
        } catch {
            guard records.contains(where: { $0.token == token }) else { return }
            if Task.isCancelled {
                if record.phase != .staged, startedAttempt, !cancelledWork.contains(token) {
                    _ = mutate(token) { $0.attempts = max(0, $0.attempts - 1); $0.phase = .queued }
                }
                await publish()
            } else if startedAttempt, record.phase != .staged, connectivity.isOffline {
                // Losing the network mid-plan is not the song's fault; it resumes when connectivity returns.
                _ = mutate(token) { $0.attempts = max(0, $0.attempts - 1); $0.phase = .queued }
                parked.insert(token)
                log.info("event=background_download outcome=parked cause=offline")
                await publish()
            } else if startedAttempt, record.phase != .staged, Self.isTransient(error),
                      transientRetries[record.id, default: 0] < transientBackoff.count {
                let retry = transientRetries[record.id, default: 0]
                transientRetries[record.id] = retry + 1
                let delay = transientBackoff[retry]
                _ = mutate(token) {
                    $0.attempts = max(0, $0.attempts - 1)
                    $0.phase = .queued
                    $0.retryAt = self.now().addingTimeInterval(delay)
                }
                log.notice("event=background_download outcome=deferred cause=\(Self.cause(error), privacy: .public) retry=\(retry + 1, privacy: .public)")
                await publish()
            } else {
                if !startedAttempt, record.phase != .staged {
                    _ = mutate(token) { $0.attempts = min(3, $0.attempts + 1) }
                }
                let failure: BackgroundDownloadFailure
                if case PlaybackStreamError.expired = error { failure = .expired }
                else { failure = (error as? BackgroundDownloadFailure) ?? (record.phase == .staged ? .publication : .transport) }
                await failed(token, failure)
            }
        }
    }

    /// Errors that say the network or the provider was busy, not that the song cannot be downloaded.
    static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case PlaybackStreamError.timedOut, PlaybackStreamError.noAudio: return true
        case PlaybackStreamError.httpStatus(let status): return status == 429 || status >= 500
        case is CancellationError: return true
        case let url as URLError:
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed].contains(url.code)
        default: return false
        }
    }

    private static func cause(_ error: any Error) -> String {
        switch error {
        case PlaybackStreamError.timedOut: "timeout"
        case PlaybackStreamError.noAudio: "no_audio"
        case PlaybackStreamError.httpStatus: "http"
        case is CancellationError: "superseded"
        case is URLError: "network"
        default: "other"
        }
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !storageFailure, records.contains(where: { $0.token == token }) else { throw CancellationError() }
    }

    private func succeeded(_ token: UUID) async {
        guard let record = records.first(where: { $0.token == token }) else { return }
        guard await store.isDownloaded(record.id) else { await failed(token, .publication); return }
        guard records.contains(where: { $0.token == token }) else { return }
        guard commit(records.filter { $0.token != token }) else { await publish(); return }
        transientRetries.removeValue(forKey: record.id)
        staging.remove(token)
        tasks.removeValue(forKey: token)
        log.info("event=background_download outcome=published")
        onTierChange?(record.id, true)
        await publish()
    }

    private func failed(_ token: UUID, _ failure: BackgroundDownloadFailure) async {
        guard let record = records.first(where: { $0.token == token }), record.phase != .failed else { return }
        if let task = tasks.removeValue(forKey: token) { retire(task) }
        var next = records
        guard let index = next.firstIndex(where: { $0.token == token }) else { return }
        // Publication errors retain the safe delivery for explicit retry; they never redownload good bytes automatically.
        if record.phase == .staged || record.attempts >= 3 {
            next[index].phase = .failed
        } else {
            next[index].phase = .queued
            next[index].token = UUID()
            next[index].metadata = nil
            next[index].retryAt = now().addingTimeInterval(backoff[min(max(record.attempts - 1, 0), backoff.count - 1)])
        }
        next[index].failure = failure
        if commit(next), next[index].token != token { staging.remove(token) }
        log.notice("event=background_download outcome=failed reason=\(failure.rawValue, privacy: .public)")
        await publish()
        pump()
    }

    private func receive(_ event: BackgroundDownloadEvent) async {
        if case .completed(let id) = event {
            retiring.remove(id)
            if restoring { completedDuringRestore.insert(id) }
            if restored, !storageFailure, let token = tasks.first(where: { $0.value == id })?.key {
                tasks.removeValue(forKey: token)
                if (try? staging.load(token)) != nil { await receive(.delivered(token)) }
                else { await failed(token, .interrupted) }
            }
            pump()
            return
        }
        if case .drained = event {
            // Delegate delivery has already synchronized bytes and atomically saved its URL-free receipt.
            await BackgroundDownloadCompletion.didDrain()
            return
        }
        guard restored, !storageFailure else { return }
        switch event {
        case .progress(let token, let written, let expected, let taskID):
            guard taskID == nil || tasks[token] == taskID else { return }
            guard records.contains(where: { $0.token == token && $0.phase == .transferring }) else { return }
            let fraction = expected > 0 ? min(0.99, max(0, Double(written) / Double(expected))) : 0
            if Int(fraction * 100) != Int((fractions[token] ?? -1) * 100) {
                fractions[token] = fraction
                await publish()
            }
        case .delivered(let token, let taskID):
            guard let record = records.first(where: { $0.token == token }) else { staging.remove(token); return }
            guard taskID == nil || tasks[token] == taskID else { return }
            guard record.phase == .transferring else { return }
            tasks.removeValue(forKey: token)
            _ = mutate(token) { $0.phase = .staged }
            await publish()
            pump()
        case .failed(let token, let failure, let taskID):
            guard taskID == nil || tasks[token] == taskID else { return }
            guard records.contains(where: { $0.token == token && $0.phase == .transferring }) else { return }
            if (try? staging.load(token)) != nil {
                await receive(.delivered(token))
            } else { await failed(token, failure) }
        case .drained, .completed: break
        }
    }

    private func retire(_ id: Int) {
        if !completedDuringRestore.contains(id) { retiring.insert(id) }
        session.cancel(id)
    }

    private func mutate(_ token: UUID, _ update: (inout BackgroundPendingDownload) -> Void) -> Bool {
        var next = records
        guard let index = next.firstIndex(where: { $0.token == token }) else { return false }
        update(&next[index])
        return commit(next)
    }

    private func commit(_ next: [BackgroundPendingDownload]) -> Bool {
        var record = DownloadQueueRecord(trackIDs: next.map(\.id))
        record.version = 2
        record.pending = next
        do {
            try save(record, queueFile)
            records = next
            storageFailure = false
            return true
        } catch {
            storageFailure = true
            log.error("event=background_download outcome=queue_write_failed")
            return false
        }
    }

    private func publish() async {
        await onStorageError?(storageFailure)
        await onChange?(items)
    }
}
