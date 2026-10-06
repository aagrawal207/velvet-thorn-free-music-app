import Foundation
import OSLog

/// Memory plus on-disk cache in front of the details fetcher. Facts are static enough to keep until a refresh;
/// a recording without any facts is retried after fifteen minutes.
actor TrackDetailsStore: TrackDetailsProviding {
    struct Configuration: Sendable {
        var memoryCapacity = 64
        var diskCapacity = 500
        var missingLifetime: TimeInterval = 15 * 60
    }

    private struct Entry {
        let details: TrackDetails
        var access: UInt64
    }

    static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "SongDetails")
    static let directoryName = "Details"
    private let directory: URL?
    private let fetcher: any TrackDetailsFetching
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private let isOffline: @Sendable () async -> Bool
    private var memory: [String: Entry] = [:]
    private var missing: [String: Date] = [:]
    private var flights: [String: Task<TrackDetails?, Never>] = [:]
    private var access: UInt64 = 0

    /// `Caches/Details` in the app container; nil keeps the store memory-only (fixtures, unit hosts).
    static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(directoryName, isDirectory: true)
    }

    init(directory: URL?, fetcher: any TrackDetailsFetching, configuration: Configuration = Configuration(),
         now: @escaping @Sendable () -> Date = { Date() }, isOffline: @escaping @Sendable () async -> Bool = { false }) {
        self.directory = directory
        self.fetcher = fetcher
        self.configuration = configuration
        self.now = now
        self.isOffline = isOffline
    }

    var memoryCount: Int { memory.count }

    func details(for track: Track, refresh: Bool) async -> TrackDetails? {
        let id = track.id
        if !refresh {
            if let entry = memory[id] {
                touch(id, entry)
                Self.logger.debug("event=detailsLookup source=memory hit=1 refresh=0")
                return entry.details
            }
            if let until = missing[id], until > now() {
                Self.logger.debug("event=detailsLookup source=none hit=0 refresh=0 missingCached=1")
                return nil
            }
            if let stored = loadFromDisk(id) {
                insert(stored)
                Self.logger.debug("event=detailsLookup source=disk hit=1 refresh=0")
                return stored
            }
        }
        if let flight = flights[id] { return await flight.value }
        let offline = await isOffline()
        if offline {
            let cached = memory[id]?.details ?? loadFromDisk(id)
            Self.logger.info("event=detailsLookup source=\(cached == nil ? "none" : "cache", privacy: .public) hit=\(cached == nil ? 0 : 1) refresh=\(refresh ? 1 : 0) offline=1")
            return cached
        }
        let task = Task<TrackDetails?, Never> { await fetcher.fetch(track, refresh: refresh) }
        flights[id] = task
        let fetched = await task.value
        flights.removeValue(forKey: id)
        if let fetched {
            insert(fetched)
            missing.removeValue(forKey: id)
            writeToDisk(fetched)
            Self.logger.info("event=detailsLookup source=network hit=1 refresh=\(refresh ? 1 : 0) offline=0")
            return fetched
        }
        // A refresh that finds nothing keeps the facts already shown instead of blanking the screen.
        let previous = memory[id]?.details ?? loadFromDisk(id)
        if previous == nil, configuration.missingLifetime > 0 {
            missing[id] = now().addingTimeInterval(configuration.missingLifetime)
            missing = missing.filter { $0.value > now() }
        }
        Self.logger.info("event=detailsLookup source=network hit=0 refresh=\(refresh ? 1 : 0) offline=0 keptPrevious=\(previous == nil ? 0 : 1)")
        return previous
    }

    // MARK: - Memory

    private func touch(_ id: String, _ entry: Entry) {
        access &+= 1
        var updated = entry
        updated.access = access
        memory[id] = updated
    }

    private func insert(_ details: TrackDetails) {
        guard configuration.memoryCapacity > 0 else { return }
        access &+= 1
        memory[details.recordingID] = Entry(details: details, access: access)
        while memory.count > configuration.memoryCapacity {
            guard let oldest = memory.min(by: { $0.value.access < $1.value.access })?.key else { break }
            memory.removeValue(forKey: oldest)
        }
    }

    // MARK: - Disk

    /// Keeps letters, digits, "-" and "_" so provider prefixes ("saavn:") and odd ids still map to one file.
    static func fileName(for recordingID: String) -> String {
        var name = ""
        for scalar in recordingID.unicodeScalars {
            let isPlain = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
            name.unicodeScalars.append(isPlain ? scalar : "_")
        }
        return String(name.prefix(120)) + ".json"
    }

    static func fileURL(for recordingID: String, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName(for: recordingID), isDirectory: false)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func loadFromDisk(_ id: String) -> TrackDetails? {
        guard let directory else { return nil }
        let url = Self.fileURL(for: id, in: directory)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1_024,
              let data = try? Data(contentsOf: url) else { return nil }
        guard let details = try? Self.decoder().decode(TrackDetails.self, from: data), details.recordingID == id else {
            try? FileManager.default.removeItem(at: url)
            Self.logger.info("event=detailsDiskRead ok=0")
            return nil
        }
        return details
    }

    private func writeToDisk(_ details: TrackDetails) {
        guard let directory, configuration.diskCapacity > 0 else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder().encode(details)
            try data.write(to: Self.fileURL(for: details.recordingID, in: directory), options: .atomic)
            let evicted = Self.enforceFileLimit(in: directory, capacity: configuration.diskCapacity, manager: manager)
            Self.logger.info("event=detailsDiskWrite ok=1 evicted=\(evicted)")
        } catch {
            Self.logger.info("event=detailsDiskWrite ok=0")
        }
    }

    /// Oldest files by modification date leave first once the folder exceeds its bound.
    static func enforceFileLimit(in directory: URL, capacity: Int, manager: FileManager = .default) -> Int {
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return 0 }
        let files = urls.filter { $0.pathExtension == "json" }
        guard files.count > capacity else { return 0 }
        struct Dated { let url: URL; let modified: Date }
        var dated: [Dated] = []
        for url in files {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            dated.append(Dated(url: url, modified: values?.contentModificationDate ?? Date.distantPast))
        }
        dated.sort { left, right in
            if left.modified != right.modified { return left.modified < right.modified }
            return left.url.lastPathComponent < right.url.lastPathComponent
        }
        var removed = 0
        for entry in dated.prefix(files.count - capacity) {
            do {
                try manager.removeItem(at: entry.url)
                removed += 1
            } catch { continue }
        }
        return removed
    }
}
