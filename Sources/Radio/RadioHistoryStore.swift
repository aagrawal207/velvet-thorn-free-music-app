import Foundation
import Observation
import OSLog

@MainActor @Observable
final class RadioHistoryStore {
    static let capacity = 20
    static let maximumBytes = 1 << 20

    private struct Document: Codable {
        var version = 1
        var historyEpoch: UUID?
        var entries: [RadioHistoryEntry] = []
    }

    private(set) var entries: [RadioHistoryEntry] = []
    private(set) var errorMessage: String?
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var baseline: Data?
    @ObservationIgnored private var historyEpoch: UUID?
    @ObservationIgnored private var enabled = true
    @ObservationIgnored private var blocked = false
    @ObservationIgnored private var clearPending = false
    @ObservationIgnored private var isDeferred: Bool
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "RadioHistory")

    /// Nil is memory-only; the coordinator supplies storage beside the active library.
    init(url: URL? = nil, historyEpoch: UUID? = nil, deferLoading: Bool = false) {
        self.url = url
        self.historyEpoch = historyEpoch
        self.isDeferred = deferLoading
        if !deferLoading { reload(historyEpoch: historyEpoch, enabled: true) }
    }

    func synchronize(historyEpoch: UUID?, enabled: Bool) {
        if isDeferred {
            reload(historyEpoch: historyEpoch, enabled: enabled)
            return
        }
        updatePrivacy(historyEpoch: historyEpoch, enabled: enabled)
        if clearPending, !blocked { save([]) }
    }

    func record(seed: RadioSeed, tuning: RadioTuning, historyEpoch: UUID?, enabled: Bool, now: Date = Date()) {
        synchronize(historyEpoch: historyEpoch, enabled: enabled)
        guard enabled, !blocked, !clearPending else { return }
        let entry = RadioHistoryEntry(seed: seed, tuning: tuning, startedAt: now)
        do { try Self.validate(entry) }
        catch {
            errorMessage = "This radio couldn’t be saved."
            log.error("event=radio_history operation=record outcome=invalid")
            return
        }
        let next = [entry] + entries.filter { $0.id != seed.id }
        save(Array(next.prefix(Self.capacity)))
    }

    func remove(id: String) {
        guard enabled, !blocked, !clearPending, entries.contains(where: { $0.id == id }) else { return }
        save(entries.filter { $0.id != id })
    }

    func reload(historyEpoch: UUID?, enabled: Bool) {
        // An unreadable library has no trustworthy epoch; the first successful library load supplies the baseline.
        if isDeferred {
            self.historyEpoch = historyEpoch
            isDeferred = false
        }
        guard url != nil else {
            blocked = false
            errorMessage = nil
            synchronize(historyEpoch: historyEpoch, enabled: enabled)
            return
        }
        updatePrivacy(historyEpoch: historyEpoch, enabled: enabled)
        do {
            let data = try readDisk()
            let document = try data.map(Self.decode) ?? Document(historyEpoch: historyEpoch)
            if document.historyEpoch != historyEpoch || (!enabled && !document.entries.isEmpty) {
                clearPending = true
                entries = []
            }
            baseline = data
            blocked = false
            if clearPending {
                save([])
            } else {
                entries = document.entries
                errorMessage = nil
                log.info("event=radio_history operation=load outcome=success")
            }
        } catch {
            blocked = true
            errorMessage = "Radio history couldn’t be read. The saved file was kept."
            log.error("event=radio_history operation=load outcome=preserved")
        }
    }

    private func updatePrivacy(historyEpoch: UUID?, enabled: Bool) {
        if self.historyEpoch != historyEpoch || (self.enabled && !enabled) {
            // Erasure is visible immediately, and survives failed writes and subsequent reloads.
            clearPending = true
            entries = []
        }
        self.historyEpoch = historyEpoch
        self.enabled = enabled
    }

    private func save(_ next: [RadioHistoryEntry]) {
        guard !blocked else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(historyEpoch: historyEpoch, entries: next))
            guard data.count <= Self.maximumBytes else { throw LibraryStorageError.tooLarge }
            if let url {
                guard try readDisk() == baseline else { throw LibraryStorageError.changedOnDisk }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                baseline = data
            }
            entries = next
            clearPending = false
            errorMessage = nil
            log.info("event=radio_history operation=write outcome=success count=\(next.count)")
        } catch {
            blocked = true
            errorMessage = "Radio history couldn’t be saved. Reload to try again."
            log.error("event=radio_history operation=write outcome=preserved")
        }
    }

    private static func validate(_ entry: RadioHistoryEntry) throws {
        guard entry.seed.isValid, LibraryValidation.isValidDate(entry.startedAt) else {
            throw LibraryStorageError.invalidData("radio history")
        }
        if case .song(let track) = entry.seed {
            try LibraryValidation.validateSearchSelection(.track(track))
        }
    }

    private static func decode(_ data: Data) throws -> Document {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let document = try decoder.decode(Document.self, from: data)
        guard document.version == 1, document.entries.count <= capacity,
              Set(document.entries.map(\.id)).count == document.entries.count else {
            throw LibraryStorageError.invalidData("radio history")
        }
        try document.entries.forEach(validate)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys).isSubset(of: ["version", "historyEpoch", "entries"]),
              let rows = raw["entries"] as? [[String: Any]], rows.count == document.entries.count else {
            throw LibraryStorageError.invalidData("radio history payload")
        }
        for (row, entry) in zip(rows, document.entries) {
            guard Set(row.keys) == ["seed", "tuning", "startedAt"],
                  let seed = row["seed"], let tuning = row["tuning"] else {
                throw LibraryStorageError.invalidData("radio history entry")
            }
            // Reject opaque provider payloads instead of silently discarding them during typed decoding.
            try LibraryValidation.validateCanonicalPayload(seed, matching: entry.seed, context: "radio seed")
            try LibraryValidation.validateCanonicalPayload(tuning, matching: entry.tuning, context: "radio tuning")
        }
        return document
    }

    private func readDisk() throws -> Data? {
        guard var url else { return nil }
        guard url.isFileURL else { throw LibraryStorageError.invalidDirectory }
        url.removeAllCachedResourceValues()
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw LibraryStorageError.invalidData("radio history file")
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
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain, failure.code == Int(POSIXErrorCode.ENOENT.rawValue) { return nil }
            if failure.domain == NSCocoaErrorDomain,
               failure.code == CocoaError.Code.fileReadNoSuchFile.rawValue || failure.code == CocoaError.Code.fileNoSuchFile.rawValue {
                // A missing-file wrapper must not turn a permission or non-directory failure into an empty store.
                guard let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
                if underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(POSIXErrorCode.ENOENT.rawValue) { return nil }
            }
            throw error
        }
    }
}
