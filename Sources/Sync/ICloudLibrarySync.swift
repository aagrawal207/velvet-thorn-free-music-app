import Foundation
import Observation
import OSLog

@MainActor @Observable
final class ICloudLibrarySync {
    private(set) var isEnabled = false
    private(set) var isSyncing = false
    private(set) var statusText = "iCloud sync is off"
    private(set) var lastSyncDate: Date?
    private(set) var errorMessage: String?
    @ObservationIgnored var onFailureNotification: (@MainActor (String?) -> Void)?

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let transport: any LibrarySyncTransport
    @ObservationIgnored private let configurationStore: any LibrarySyncConfigurationPersisting
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let operationTimeout: Duration
    @ObservationIgnored private let usesLiveTransport: Bool
    @ObservationIgnored private var configuration = LibrarySyncDeviceConfiguration()
    @ObservationIgnored private var configurationLoadError: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var allowAccountRebind = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lease: LibrarySyncLease?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending: Trigger?
    @ObservationIgnored private var localChangeGeneration = UUID()
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: Duration?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var automaticFailure: LibrarySyncFailure?
    @ObservationIgnored private var nextAutomaticAttempt: TimeInterval?
    @ObservationIgnored private let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored private var notifiedFailures: Set<LibrarySyncFailure> = []
    @ObservationIgnored private var manualOperation = false
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "LibrarySync")

    private enum Trigger: String { case activation, localChange, filesChanged, retry, manual }

    init(library: LibraryStore, transport: (any LibrarySyncTransport)? = nil,
         configuration: (any LibrarySyncConfigurationPersisting)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }, debounce: Duration = .milliseconds(750),
         operationTimeout: Duration = .seconds(45), retryDelays: [Duration] = [.seconds(5), .seconds(30)],
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.library = library
        self.transport = transport ?? ICloudDriveLibraryTransport()
        self.configurationStore = configuration ?? LibrarySyncDeviceConfigurationStore(fileURL: library.syncDeviceConfigurationURL)
        self.usesLiveTransport = transport == nil || transport is ICloudDriveLibraryTransport
        self.now = now
        self.debounce = debounce
        self.operationTimeout = operationTimeout
        self.retryDelays = Array(retryDelays.prefix(2))
        self.uptime = uptime
        do {
            self.configuration = try configurationStore.load()
            isEnabled = self.configuration.enabled
            lastSyncDate = self.configuration.lastSyncDate
            if isEnabled { statusText = "Waiting to sync with iCloud" }
        } catch {
            configurationLoadError = error.localizedDescription
            errorMessage = "Velvet Thorn couldn’t read this device’s sync settings. \(error.localizedDescription)"
            statusText = "Sync settings need attention"
        }
        library.onSyncChange = { [weak self] in
            self?.localChangeGeneration = UUID()
            self?.refresh(trigger: .localChange)
        }
    }

    func start() {
        #if DEBUG
        // Default enablement must not activate native iCloud in fixture or unit-test hosts.
        guard !usesLiveTransport || (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && !ProcessInfo.processInfo.arguments.contains("--uitesting")) else { return }
        #endif
        guard !started else { return }
        started = true
        installObservers()
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        invalidateWork()
        guard configurationLoadError == nil else { return }
        var candidate = configuration
        candidate.enabled = enabled
        do {
            try configurationStore.save(candidate)
            configuration = candidate
            isEnabled = enabled
            allowAccountRebind = enabled
            errorMessage = nil
            resetFailures()
            statusText = enabled ? "Waiting to sync with iCloud" : "iCloud sync is off. Your library is on this device."
            if enabled {
                if started { installObservers(); refresh() }
            } else {
                transport.stopObserving()
            }
        } catch {
            isEnabled = false
            allowAccountRebind = false
            transport.stopObserving()
            errorMessage = "Velvet Thorn couldn’t save this device’s sync setting. \(error.localizedDescription)"
            statusText = "Sync is paused"
        }
    }

    func refresh() {
        refresh(trigger: .activation)
    }

    private func refresh(trigger: Trigger) {
        guard started, isEnabled, configurationLoadError == nil else { return }
        if task != nil { refreshPending = trigger; return }
        if trigger == .activation {
            resetRetryBudget()
        } else if let automaticFailure {
            // Checkpoints cannot turn an exhausted retry budget into a perpetual five-second retry loop.
            guard retryTask == nil, trigger == .filesChanged || (trigger == .localChange && automaticFailure.isTransient),
                  nextAutomaticAttempt.map({ uptime() >= $0 }) ?? false else { return }
            resetRetryBudget()
        }
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.debounceTask = nil
            _ = self?.beginSync(trigger: trigger)
        }
    }

    func syncNow() async {
        guard isEnabled, configurationLoadError == nil, started || !usesLiveTransport else { return }
        debounceTask?.cancel()
        debounceTask = nil
        if let task { manualOperation = true; await task.value; return }
        resetRetryBudget()
        let operation = beginSync(trigger: .manual)
        await operation?.value
    }

    private func beginSync(trigger: Trigger) -> Task<Void, Never>? {
        guard isEnabled, task == nil, configurationLoadError == nil, started || !usesLiveTransport else { return task }
        generation = UUID()
        let operationID = generation
        let lease = LibrarySyncLease()
        self.lease = lease
        refreshPending = nil
        manualOperation = trigger == .manual
        isSyncing = true
        statusText = "Checking iCloud Drive…"
        log.info("event=sync_started trigger=\(trigger.rawValue, privacy: .public) retry=\(self.retryCount)")
        let transport = self.transport
        let library = self.library
        let now = self.now
        let began = ContinuousClock.now
        let operation = Task { @MainActor [weak self] in
            defer { self?.finished(operationID, elapsed: began.duration(to: .now)) }
            do {
                let account = try await transport.accountIdentifier()
                guard let scope = try self?.acceptAccount(account, operationID: operationID, lease: lease) else { return }
                self?.statusText = "Reading your iCloud library…"
                let read = try await transport.read(in: scope)
                guard self?.isCurrent(operationID, scope: scope) == true else { return }
                let time = now()
                let preparation = Task.detached(priority: .utility) { try Self.mergeFiles(read.files, now: time) }
                let remote = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                guard self?.isCurrent(operationID, scope: scope) == true else { return }
                let confirmedAccount = try await transport.accountIdentifier()
                guard try self?.confirmAccount(confirmedAccount, operationID: operationID, scope: scope) == true else { return }
                if read.pendingDownloads > 0 {
                    self?.resetRetryBudget()
                    self?.log.info("event=sync_waiting reason=downloads count=\(min(read.pendingDownloads, LibrarySyncCodec.maximumFiles))")
                    self?.statusText = "Waiting for iCloud to download your library…"
                    return
                }
                let localGeneration = self?.localChangeGeneration
                let prepared = try await library.prepareCloudMerge(remote)
                guard self?.isCurrent(operationID, scope: scope) == true else { return }
                let mergeAccount = try await transport.accountIdentifier()
                guard try self?.confirmAccount(mergeAccount, operationID: operationID, scope: scope) == true else { return }
                // Retire stale preparation before LibraryStore reports the expected race as a storage/banner failure.
                guard self?.localChangeGeneration == localGeneration else { throw LibrarySyncError.localChangedDuringSync }
                guard let data = try self?.applyAndEncode(prepared, operationID: operationID, scope: scope) else { return }
                try await transport.publish(data, in: scope, replacing: read.publication)
                guard self?.isCurrent(operationID, scope: scope) == true else { return }
                let publishedAccount = try await transport.accountIdentifier()
                guard try self?.confirmAccount(publishedAccount, operationID: operationID, scope: scope) == true else { return }
                try self?.succeeded(operationID, scope: scope)
            } catch {
                self?.failed(error, operationID: operationID)
            }
        }
        task = operation
        let timeout = operationTimeout
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled, self?.generation == operationID else { return }
            guard let self else { return }
            let manual = self.manualOperation
            self.invalidateWork()
            self.manualOperation = manual
            self.log.info("event=sync_timeout duration_ms=\(Int(began.duration(to: .now) / .milliseconds(1)))")
            self.recordFailure(.timeout, message: "iCloud is taking too long to respond. Your library is on this device. Try syncing again.")
            self.scheduleRetry()
        }
        return operation
    }

    private func acceptAccount(_ account: String?, operationID: UUID, lease: LibrarySyncLease) throws -> LibrarySyncScope? {
        guard generation == operationID, isEnabled, lease.isValid else { return nil }
        try verifyConfiguration()
        guard let account else {
            library.invalidateListeningCheckpointPreparations()
            log.info("event=sync_waiting reason=account count=0")
            statusText = "Sign in to iCloud and turn on iCloud Drive to sync."
            return nil
        }
        let matchesBound = try configuration.boundAccount.map { try transport.accountsMatch($0, account) } ?? false
        if configuration.boundAccount != nil, !matchesBound, !allowAccountRebind {
            pauseForAccountChange()
            return nil
        }
        if !matchesBound {
            var candidate = configuration
            if candidate.boundAccount != nil { candidate.replicaID = UUID() }
            candidate.boundAccount = account
            library.invalidateListeningCheckpointPreparations()
            candidate.lastSyncDate = nil
            try configurationStore.save(candidate)
            configuration = candidate
            lastSyncDate = nil
        }
        allowAccountRebind = false
        return LibrarySyncScope(accountIdentifier: configuration.boundAccount!, replicaID: configuration.replicaID, lease: lease)
    }

    private func confirmAccount(_ account: String?, operationID: UUID, scope: LibrarySyncScope) throws -> Bool {
        guard isCurrent(operationID, scope: scope) else { return false }
        try verifyConfiguration()
        guard let account else {
            library.invalidateListeningCheckpointPreparations()
            throw LibrarySyncError.unavailable
        }
        guard try transport.accountsMatch(account, scope.accountIdentifier) else {
            library.invalidateListeningCheckpointPreparations()
            throw LibrarySyncError.accountChanged
        }
        return true
    }

    private func verifyConfiguration() throws {
        guard try configurationStore.load() == configuration else { throw LibraryStorageError.changedOnDisk }
    }

    private func isCurrent(_ operationID: UUID, scope: LibrarySyncScope) -> Bool {
        generation == operationID && isEnabled && scope.lease.isValid
            && configuration.boundAccount == scope.accountIdentifier && configuration.replicaID == scope.replicaID
    }

    private func applyAndEncode(_ prepared: LibraryCloudMergePreparation, operationID: UUID, scope: LibrarySyncScope) throws -> Data? {
        guard isCurrent(operationID, scope: scope) else { return nil }
        try library.applyCloudMerge(prepared)
        guard isCurrent(operationID, scope: scope) else { return nil }
        let replica = try library.cloudReplica(replicaID: scope.replicaID)
        statusText = "Saving your library to iCloud Drive…"
        return try LibrarySyncCodec.encodeReplica(replica)
    }

    private func succeeded(_ operationID: UUID, scope: LibrarySyncScope) throws {
        guard isCurrent(operationID, scope: scope) else { return }
        var candidate = configuration
        let time = now()
        guard LibraryValidation.isValidDate(time) else { throw LibrarySyncError.invalidData("device clock") }
        candidate.lastSyncDate = time
        try configurationStore.save(candidate)
        configuration = candidate
        lastSyncDate = candidate.lastSyncDate
        errorMessage = nil
        log.info("event=sync_succeeded retries=\(self.retryCount)")
        resetFailures()
        statusText = "Handed to iCloud. Other devices may update later."
    }

    private func failed(_ error: any Error, operationID: UUID) {
        guard generation == operationID, isEnabled else { return }
        if let error = error as? LibrarySyncError, error == .accountChanged { pauseForAccountChange(); return }
        let reason = LibrarySyncFailure.reason(for: error)
        if reason == .cancelled {
            log.info("event=sync_cancelled")
            statusText = "Sync was cancelled. Try syncing again."
            return
        }
        recordFailure(reason, message: error.localizedDescription)
    }

    private func recordFailure(_ reason: LibrarySyncFailure, message: String) {
        automaticFailure = reason
        refreshPending = nil
        statusText = reason.status
        let willRetry = reason.isTransient && retryCount < retryDelays.count && started
        if willRetry && !manualOperation { statusText += ". Retrying shortly." }
        retryDelay = willRetry ? retryDelays[retryCount] : nil
        nextAutomaticAttempt = uptime() + 300
        let sustained = !willRetry
        let visible = manualOperation || !reason.isTransient || sustained
        if visible { errorMessage = message }
        let notify = visible && (manualOperation || !notifiedFailures.contains(reason))
        log.error("event=sync_failed reason=\(reason.rawValue, privacy: .public) retry=\(self.retryCount) will_retry=\(willRetry) notified=\(notify)")
        if notify {
            notifiedFailures.insert(reason)
            onFailureNotification?(message)
        }
    }

    private func scheduleRetry() {
        guard let delay = retryDelay, started, isEnabled else { return }
        retryDelay = nil
        retryCount += 1
        let operationID = generation
        log.info("event=sync_retry_scheduled attempt=\(self.retryCount) delay_ms=\(Int(delay / .milliseconds(1)))")
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == operationID else { return }
            self.retryTask = nil
            _ = self.beginSync(trigger: .retry)
        }
    }

    private func resetRetryBudget() {
        retryTask?.cancel()
        retryTask = nil
        retryDelay = nil
        retryCount = 0
        automaticFailure = nil
        nextAutomaticAttempt = nil
    }

    private func resetFailures() {
        resetRetryBudget()
        notifiedFailures.removeAll()
        onFailureNotification?(nil)
    }

    private func pauseForAccountChange() {
        invalidateWork()
        isEnabled = false
        allowAccountRebind = false
        lastSyncDate = nil
        transport.stopObserving()
        var candidate = configuration
        candidate.enabled = false
        candidate.lastSyncDate = nil
        do { try configurationStore.save(candidate); configuration = candidate; errorMessage = nil }
        catch { errorMessage = "Velvet Thorn couldn’t save the paused sync setting. \(error.localizedDescription)" }
        statusText = "Your Apple Account changed. Turn sync on to use this account."
        resetFailures()
        log.info("event=sync_paused reason=account_changed")
    }

    private func finished(_ operationID: UUID, elapsed: Duration) {
        guard generation == operationID else { return }
        log.info("event=sync_finished duration_ms=\(Int(elapsed / .milliseconds(1)))")
        timeoutTask?.cancel()
        timeoutTask = nil
        lease?.invalidate()
        lease = nil
        task = nil
        isSyncing = false
        if retryDelay != nil { scheduleRetry() }
        else if let pending = refreshPending { refreshPending = nil; refresh(trigger: pending) }
    }

    private func invalidateWork() {
        library.invalidateListeningCheckpointPreparations()
        generation = UUID()
        lease?.invalidate()
        lease = nil
        task?.cancel()
        task = nil
        debounceTask?.cancel()
        debounceTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        retryTask?.cancel()
        retryTask = nil
        retryDelay = nil
        refreshPending = nil
        isSyncing = false
    }

    private func installObservers() {
        transport.startObserving { [weak self] event in
            guard let self else { return }
            if case .identityChanged = event {
                self.invalidateWork()
                self.allowAccountRebind = false
                if self.isEnabled { self.statusText = "Checking your Apple Account…" }
            }
            self.refresh(trigger: event == .identityChanged ? .activation : .filesChanged)
        }
    }

    nonisolated private static func mergeFiles(_ files: [LibrarySyncRemoteFile], now: Date) throws -> LibrarySyncState {
        guard files.count <= LibrarySyncCodec.maximumFiles else { throw LibrarySyncError.tooLarge }
        var bytes = 0
        var merged = LibrarySyncState()
        for file in files {
            try Task.checkCancellation()
            guard file.data.count <= LibrarySyncCodec.maximumBatchBytes - bytes else { throw LibrarySyncError.tooLarge }
            bytes += file.data.count
            let replica = try LibrarySyncCodec.decodeReplica(file.data, expectedReplicaID: file.replicaID, now: now)
            merged = try LibrarySyncMerge.joined(merged, replica.state)
        }
        return merged
    }

    isolated deinit {
        lease?.invalidate()
        task?.cancel()
        debounceTask?.cancel()
        timeoutTask?.cancel()
        retryTask?.cancel()
        transport.stopObserving()
    }
}
