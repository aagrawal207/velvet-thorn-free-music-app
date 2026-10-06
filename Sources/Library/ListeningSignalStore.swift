import Foundation
import Observation
import OSLog

/// Device-local skip and completion signals, kept beside the library and never synced or backed up.
/// The library's history epoch fences erasure and loading, as it does for `RadioHistoryStore`.
@MainActor @Observable
final class ListeningSignalStore {
    static let fileName = "listening-signals.json"
    static let capacity = 2_048
    static let retention: TimeInterval = 90 * 86_400
    static let maximumBytes = 1 << 20
    static let maximumTextCharacters = 200
    static let maximumArtists = 16
    static let maximumTrackIDBytes = 512
    private static let maximumListenedSeconds: TimeInterval = 7 * 86_400
    private static let signalKeys: Set<String> = ["trackID", "title", "artists", "endedAt", "listenedSeconds",
                                                  "duration", "ending", "origin", "rapid"]

    private struct Document: Codable {
        var version = 1
        var historyEpoch: UUID?
        var signals: [ListeningSignal] = []
    }

    /// Durable signals, oldest first.
    private(set) var signals: [ListeningSignal] = []
    /// Advances after each durable change, and at once when a privacy boundary erases signals.
    private(set) var revision: UInt64 = 0
    private(set) var errorMessage: String?
    /// A preserved unreadable file or a failed write; nothing is recorded until a reload succeeds.
    private(set) var isBlocked = false

    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var baseline: Data?
    @ObservationIgnored private var diskHoldsSignals = false
    @ObservationIgnored private var historyEpoch: UUID?
    @ObservationIgnored private var enabled = true
    @ObservationIgnored private var clearPending = false
    @ObservationIgnored private var isDeferred: Bool
    @ObservationIgnored private var unsaved: [ListeningSignal] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "ListeningSignals")

    /// Nil is memory-only and publishes at once; the coordinator supplies storage beside the active library.
    init(url: URL? = nil, historyEpoch: UUID? = nil, deferLoading: Bool = false,
         saveDelay: Duration = .seconds(2), now: @escaping () -> Date = { Date() }) {
        self.url = url
        self.historyEpoch = historyEpoch
        self.isDeferred = deferLoading
        self.saveDelay = saveDelay
        self.now = now
        if !deferLoading { reload(historyEpoch: historyEpoch, enabled: true) }
    }

    isolated deinit { saveTask?.cancel() }

    func synchronize(historyEpoch: UUID?, enabled: Bool) {
        if isDeferred {
            reload(historyEpoch: historyEpoch, enabled: enabled)
            return
        }
        updatePrivacy(historyEpoch: historyEpoch, enabled: enabled)
        if clearPending, !isBlocked { persist() }
    }

    /// Queues the signal for the next coalesced write. History off, a deferred epoch or a blocked file drop it.
    @discardableResult
    func record(_ signal: ListeningSignal, historyEpoch: UUID?, enabled: Bool) -> Bool {
        // A deferred store must not adopt the epoch of a library that failed to load.
        if !isDeferred { synchronize(historyEpoch: historyEpoch, enabled: enabled) }
        let kept = enabled && !isDeferred && !isBlocked && !clearPending ? Self.sanitized(signal) : nil
        let reason = !enabled ? "history_off" : (kept == nil ? "blocked" : "none")
        let ending = signal.ending.rawValue, origin = signal.origin.rawValue, strength = signal.strengthName
        let rapid = signal.rapid ? 1 : 0, recorded = kept == nil ? 0 : 1
        log.info("event=listening_signal ending=\(ending, privacy: .public) origin=\(origin, privacy: .public) rapid=\(rapid) strength=\(strength, privacy: .public) recorded=\(recorded) reason=\(reason, privacy: .public)")
        guard let kept else { return false }
        unsaved.append(kept)
        if url == nil { persist() } else { scheduleSave() }
        return true
    }

    /// Writes coalesced signals now, before the process may be suspended or ended.
    func flush() {
        guard saveTask != nil || !unsaved.isEmpty || clearPending else { return }
        persist()
    }

    func reload(historyEpoch: UUID?, enabled: Bool) {
        // An unreadable library has no trustworthy epoch; the first successful library load supplies the baseline.
        if isDeferred {
            self.historyEpoch = historyEpoch
            isDeferred = false
        }
        guard url != nil else {
            isBlocked = false
            errorMessage = nil
            synchronize(historyEpoch: historyEpoch, enabled: enabled)
            return
        }
        updatePrivacy(historyEpoch: historyEpoch, enabled: enabled)
        do {
            let data = try readDisk()
            let document = try data.map(Self.decode) ?? Document(historyEpoch: historyEpoch)
            baseline = data
            diskHoldsSignals = !document.signals.isEmpty
            isBlocked = false
            if document.historyEpoch != historyEpoch || (!enabled && !document.signals.isEmpty) { erase() }
            if clearPending {
                persist()
                return
            }
            let loaded = Self.retained(document.signals, now: now())
            if loaded != signals {
                signals = loaded
                revision &+= 1
            }
            errorMessage = nil
            let count = loaded.count
            log.info("event=listening_signal_store outcome=loaded count=\(count)")
            if count != document.signals.count || !unsaved.isEmpty { scheduleSave() }
        } catch LibraryStorageError.newerVersion {
            blockLoad("Skip history was saved by a newer version of Velvet Thorn. The file on this device was kept.")
        } catch {
            blockLoad("Skip history on this device couldn’t be read. The file was kept.")
        }
    }

    private func blockLoad(_ message: String) {
        saveTask?.cancel()
        saveTask = nil
        unsaved = []
        isBlocked = true
        errorMessage = message
        log.error("event=listening_signal_store outcome=blocked count=0")
    }

    private func updatePrivacy(historyEpoch: UUID?, enabled: Bool) {
        if self.historyEpoch != historyEpoch || (self.enabled && !enabled) { erase() }
        self.historyEpoch = historyEpoch
        self.enabled = enabled
    }

    /// Erasure is visible at once; a file that may still hold signals stays pending through failed writes and reloads.
    private func erase() {
        saveTask?.cancel()
        saveTask = nil
        let removed = !signals.isEmpty || !unsaved.isEmpty
        unsaved = []
        if !signals.isEmpty {
            signals = []
            revision &+= 1
        }
        if isBlocked || diskHoldsSignals { clearPending = true }
        else if removed { log.info("event=listening_signal_store outcome=erased count=0") }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { @MainActor [weak self] in
            // Skips arrive in bursts while flicking through a queue; one write covers the burst.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        saveTask?.cancel()
        saveTask = nil
        guard !isBlocked, !isDeferred else { return }
        let erasing = clearPending
        var next = erasing ? [] : Self.retained(signals + unsaved, now: now())
        do {
            if let url, !next.isEmpty || diskHoldsSignals {
                var data = try Self.encode(Document(historyEpoch: historyEpoch, signals: next))
                // Unusually long names could outgrow the read cap; the oldest signals give way first.
                while data.count > Self.maximumBytes, !next.isEmpty {
                    next.removeFirst(max(1, next.count / 8))
                    data = try Self.encode(Document(historyEpoch: historyEpoch, signals: next))
                }
                guard try readDisk() == baseline else { throw LibraryStorageError.changedOnDisk }
                try Self.install(data, at: url)
                baseline = data
                diskHoldsSignals = !next.isEmpty
            }
            unsaved = []
            clearPending = false
            errorMessage = nil
            if next != signals {
                signals = next
                revision &+= 1
            }
            let count = next.count
            log.info("event=listening_signal_store outcome=\(erasing ? "erased" : "saved", privacy: .public) count=\(count)")
        } catch {
            unsaved = []
            isBlocked = true
            errorMessage = erasing ? "Skip history is hidden, but its file on this device couldn’t be cleared."
                : "Skip history couldn’t be saved on this device. The saved file was kept."
            let count = signals.count
            log.error("event=listening_signal_store outcome=failed count=\(count)")
        }
    }

    private static func retained(_ signals: [ListeningSignal], now: Date) -> [ListeningSignal] {
        let cutoff = now.addingTimeInterval(-retention)
        return Array(signals.filter { $0.endedAt >= cutoff }.suffix(capacity))
    }

    private static func sanitized(_ signal: ListeningSignal) -> ListeningSignal? {
        var signal = signal
        signal.title = String(signal.title.prefix(maximumTextCharacters))
        signal.artists = signal.artists.prefix(maximumArtists).map { String($0.prefix(maximumTextCharacters)) }
        signal.duration = PlaybackTiming.validDuration(signal.duration)
        return isValid(signal) ? signal : nil
    }

    private static func isValid(_ signal: ListeningSignal) -> Bool {
        LibraryValidation.isValidID(signal.trackID) && signal.trackID.utf8.count <= maximumTrackIDBytes
            && signal.title.count <= maximumTextCharacters && signal.artists.count <= maximumArtists
            && signal.artists.allSatisfy { $0.count <= maximumTextCharacters }
            && LibraryValidation.isValidDate(signal.endedAt)
            && signal.listenedSeconds.isFinite && signal.listenedSeconds >= 0
            && signal.listenedSeconds <= maximumListenedSeconds
            && (signal.duration.map { PlaybackTiming.validDuration($0) != nil } ?? true)
    }

    private static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    private static func decode(_ data: Data) throws -> Document {
        let version = try JSONDecoder().decode(LibraryPersistence.VersionHeader.self, from: data).version
        guard version <= 1 else { throw LibraryStorageError.newerVersion }
        guard version == 1 else { throw LibraryStorageError.unsupportedVersion }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let document = try decoder.decode(Document.self, from: data)
        guard document.signals.count <= capacity, document.signals.allSatisfy(isValid) else {
            throw LibraryStorageError.invalidData("listening signals")
        }
        // Unknown fields fail closed instead of vanishing silently on the next rewrite.
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys).isSubset(of: ["version", "historyEpoch", "signals"]),
              let rows = raw["signals"] as? [[String: Any]], rows.count == document.signals.count,
              rows.allSatisfy({ Set($0.keys).isSubset(of: signalKeys) }) else {
            throw LibraryStorageError.invalidData("listening signals payload")
        }
        return document
    }

    /// The exclusion is set before the rename, so no installed copy is ever eligible for backup.
    private static func install(_ data: Data, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try temporary.setResourceValues(values)
            let failure = temporary.withUnsafeFileSystemRepresentation { source -> Int32? in
                url.withUnsafeFileSystemRepresentation { destination -> Int32? in
                    guard let source, let destination else { return EINVAL }
                    return rename(source, destination) == 0 ? nil : errno
                }
            }
            if let failure { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func readDisk() throws -> Data? {
        guard var url else { return nil }
        guard url.isFileURL else { throw LibraryStorageError.invalidDirectory }
        url.removeAllCachedResourceValues()
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw LibraryStorageError.invalidData("listening signals file")
            }
            if let size = values.fileSize, size > Self.maximumBytes { throw LibraryStorageError.tooLarge }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while let chunk = try handle.read(upToCount: min(65_536, Self.maximumBytes - data.count + 1)), !chunk.isEmpty {
                guard chunk.count <= Self.maximumBytes - data.count else { throw LibraryStorageError.tooLarge }
                data.append(chunk)
            }
            return data
        } catch {
            // A permission or not-a-directory failure must not become permission to create a replacement file.
            if MomentMixFilePersistence.isMissingFile(error) { return nil }
            throw error
        }
    }
}
