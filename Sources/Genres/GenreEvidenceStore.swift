import Foundation
import Observation
import OSLog

/// Which MusicBrainz entity supplied a recording's families; a bounded metrics dimension.
enum GenreEvidenceSource: String, Codable, Sendable {
    case recording, releaseGroup, artist, none
}

struct GenreShare: Equatable, Hashable, Sendable, Identifiable {
    var family: GenreFamily
    var share: Double
    var id: String { family.rawValue }
}

/// A recording's top families with shares that sum to one, or an empty list when nothing mapped to a family.
struct GenreDistribution: Equatable, Sendable {
    static let maximumFamilies = 3
    static let unclassified = GenreDistribution(shares: [], source: .none)

    var shares: [GenreShare]
    var source: GenreEvidenceSource

    var dominant: GenreFamily? { shares.first?.family }
    var isClassified: Bool { !shares.isEmpty }
    var families: [GenreFamily] { shares.map(\.family) }

    func share(of family: GenreFamily) -> Double {
        shares.first { $0.family == family }?.share ?? 0
    }
}

extension GenreDistribution: Codable {
    private enum CodingKeys: String, CodingKey { case shares, source }
    private struct RawShare: Codable { var family: String; var share: Double }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A family this build does not know is dropped rather than failing the whole file; the shares are renormalised.
        let raw = (try? values.decodeIfPresent([RawShare].self, forKey: .shares)) ?? []
        let known = raw.compactMap { entry -> GenreShare? in
            guard let family = GenreFamily(rawValue: entry.family), entry.share.isFinite, entry.share > 0 else { return nil }
            return GenreShare(family: family, share: entry.share)
        }
        let total = known.reduce(0) { $0 + $1.share }
        shares = total > 0 ? Array(known.map { GenreShare(family: $0.family, share: $0.share / total) }.prefix(Self.maximumFamilies)) : []
        let source = (try? values.decodeIfPresent(GenreEvidenceSource.self, forKey: .source)) ?? .none
        self.source = shares.isEmpty ? .none : source
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shares.map { RawShare(family: $0.family.rawValue, share: $0.share) }, forKey: .shares)
        try container.encode(source, forKey: .source)
    }
}

struct GenreRecordingRecord: Codable, Equatable, Sendable {
    var key: LyricsRequestKey
    var distribution: GenreDistribution
    var checkedAt: Date
    /// Negative results expire so a later MusicBrainz edit can be picked up; positive results live until LRU eviction.
    var expiresAt: Date?
    var lastUsedAt: Date

    func isReusable(at date: Date) -> Bool {
        guard checkedAt <= date else { return false }
        if let expiresAt { return date < expiresAt }
        return true
    }
}

struct GenreArtistRecord: Codable, Equatable, Sendable {
    /// MusicBrainz artist MBID; most artists recur across many songs, so this cache saves a request per song.
    var id: String
    var distribution: GenreDistribution
    var checkedAt: Date
    var expiresAt: Date
    var lastUsedAt: Date

    func isReusable(at date: Date) -> Bool { checkedAt <= date && date < expiresAt }
}

/// On-disk shape of `genres.json`; a versioned envelope so a future build can migrate or ignore it.
struct GenreEvidenceSnapshot: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var version = formatVersion
    var taxonomyVersion = GenreTaxonomy.version
    var recordings: [GenreRecordingRecord] = []
    var artists: [GenreArtistRecord] = []

    private enum CodingKeys: String, CodingKey { case version, taxonomyVersion, recordings, artists }

    init() { }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        taxonomyVersion = (try? values.decodeIfPresent(Int.self, forKey: .taxonomyVersion)) ?? 0
        // One malformed record must not discard the rest of the store.
        recordings = ((try? values.decodeIfPresent([Lenient<GenreRecordingRecord>].self, forKey: .recordings)) ?? []).compactMap(\.value)
        artists = ((try? values.decodeIfPresent([Lenient<GenreArtistRecord>].self, forKey: .artists)) ?? []).compactMap(\.value)
    }

    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }
}

/// Disk half of the store: reads and atomic writes off the main actor, fenced by the store's revision.
actor GenreEvidenceDisk {
    static let maximumFileBytes = 6 << 20
    private let url: URL

    init(url: URL) { self.url = url }

    func load() -> GenreEvidenceSnapshot? {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maximumFileBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(GenreEvidenceSnapshot.self, from: data),
              snapshot.version <= GenreEvidenceSnapshot.formatVersion else { return nil }
        return snapshot
    }

    func save(_ snapshot: GenreEvidenceSnapshot) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Device-local genre evidence for played recordings and their artists. Bounded by count with least-recently-used
/// eviction, saved to `Application Support/GanaBajana/genres.json`, never part of iCloud library sync.
@MainActor @Observable
final class GenreEvidenceStore {
    static let maximumRecordings = 5_000
    static let maximumArtists = 2_000
    static let negativeLifetime: TimeInterval = 30 * 86_400
    static let artistLifetime: TimeInterval = 30 * 86_400
    static let fileName = "genres.json"
    static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Genres")

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GanaBajana", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Reusable evidence keyed like the language cache: a changed recording identity cannot borrow another version's genres.
    private(set) var distributions: [LyricsRequestKey: GenreDistribution] = [:]
    private(set) var isLoaded: Bool
    /// Bumps on every accepted change so callers can cache derived profiles cheaply.
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private var recordings: [LyricsRequestKey: GenreRecordingRecord] = [:]
    @ObservationIgnored private var artists: [String: GenreArtistRecord] = [:]
    @ObservationIgnored private let disk: GenreEvidenceDisk?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let maximumRecordings: Int
    @ObservationIgnored private let maximumArtists: Int
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var storageRevision: UInt64 = 0
    @ObservationIgnored private var dirty = false
    @ObservationIgnored var onChanged: (@MainActor () -> Void)?

    init(url: URL?, now: @escaping @Sendable () -> Date = { Date() },
         maximumRecordings: Int = GenreEvidenceStore.maximumRecordings, maximumArtists: Int = GenreEvidenceStore.maximumArtists) {
        disk = url.map { GenreEvidenceDisk(url: $0) }
        self.now = now
        self.maximumRecordings = max(1, min(Self.maximumRecordings, maximumRecordings))
        self.maximumArtists = max(1, min(Self.maximumArtists, maximumArtists))
        isLoaded = url == nil
    }

    isolated deinit {
        loadTask?.cancel()
    }

    var recordingCount: Int { recordings.count }
    var artistCount: Int { artists.count }

    /// Reads the file once; later calls return once the first read has finished.
    func load() async {
        if isLoaded { return }
        if let loadTask { await loadTask.value; return }
        guard let disk else { isLoaded = true; return }
        let task = Task { [weak self] in
            let snapshot = await disk.load()
            guard !Task.isCancelled else { return }
            self?.finishLoad(snapshot)
        }
        loadTask = task
        await task.value
    }

    private func finishLoad(_ snapshot: GenreEvidenceSnapshot?) {
        loadTask = nil
        defer { isLoaded = true }
        guard let snapshot else {
            Self.log.info("event=genre_store_load outcome=missing recordings=0 artists=0")
            return
        }
        // A newer taxonomy re-maps lazily: dropping the entries makes each play a fresh, once-per-recording classification.
        guard snapshot.taxonomyVersion == GenreTaxonomy.version else {
            Self.log.info("event=genre_store_load outcome=taxonomy_changed recordings=0 artists=0")
            isLoaded = true
            markDirty()
            return
        }
        let current = now()
        for record in snapshot.recordings where recordings[record.key] == nil && record.isReusable(at: current) {
            recordings[record.key] = record
        }
        for record in snapshot.artists where artists[record.id] == nil && record.isReusable(at: current) {
            artists[record.id] = record
        }
        enforceBounds()
        publish()
        Self.log.info("event=genre_store_load outcome=loaded recordings=\(self.recordings.count) artists=\(self.artists.count)")
        // Evidence recorded while the file was still loading waited for this moment to be written.
        isLoaded = true
        if dirty { scheduleSave() }
    }

    func distribution(for track: Track) -> GenreDistribution? {
        distributions[LyricsRequestKey(track)]
    }

    /// True when no reusable evidence exists yet; the loader checks this before spending MusicBrainz requests.
    func needsClassification(_ key: LyricsRequestKey) -> Bool {
        guard let record = recordings[key] else { return true }
        return !record.isReusable(at: now())
    }

    func artistDistribution(id: String) -> GenreDistribution? {
        guard let record = artists[id], record.isReusable(at: now()) else { return nil }
        return record.distribution
    }

    func record(_ distribution: GenreDistribution, for key: LyricsRequestKey) {
        let current = now()
        guard LibraryValidation.isValidDate(current) else { return }
        let expiry = distribution.isClassified ? nil : current.addingTimeInterval(Self.negativeLifetime)
        recordings[key] = GenreRecordingRecord(key: key, distribution: distribution, checkedAt: current,
                                               expiresAt: expiry, lastUsedAt: current)
        enforceBounds()
        publish()
        markDirty()
    }

    func recordArtist(_ distribution: GenreDistribution, id: String) {
        let current = now()
        guard LibraryValidation.isValidDate(current), !id.isEmpty else { return }
        artists[id] = GenreArtistRecord(id: id, distribution: distribution, checkedAt: current,
                                        expiresAt: current.addingTimeInterval(Self.artistLifetime), lastUsedAt: current)
        enforceBounds()
        markDirty()
    }

    /// Marks recordings as in use so LRU eviction keeps the songs the listener still plays.
    func touch(_ keys: [LyricsRequestKey]) {
        let current = now()
        var changed = false
        for key in keys {
            guard var record = recordings[key], record.lastUsedAt < current else { continue }
            record.lastUsedAt = current
            recordings[key] = record
            changed = true
        }
        if changed { markDirty() }
    }

    /// Forgets every entry and deletes the file; used when the listener clears listening history.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        saveTask?.cancel()
        saveTask = nil
        recordings = [:]
        artists = [:]
        dirty = false
        isLoaded = true
        storageRevision &+= 1
        if let disk { Task(priority: .utility) { await disk.remove() } }
        publish()
    }

    /// Flushes a pending save; tests and pause paths use it so a relaunch sees the latest evidence.
    func flush() async {
        if let saveTask { await saveTask.value }
        guard dirty else { return }
        saveTask?.cancel()
        saveTask = nil
        await write()
    }

    func snapshot() -> GenreEvidenceSnapshot {
        var snapshot = GenreEvidenceSnapshot()
        snapshot.recordings = recordings.values.sorted { $0.lastUsedAt > $1.lastUsedAt }
        snapshot.artists = artists.values.sorted { $0.lastUsedAt > $1.lastUsedAt }
        return snapshot
    }

    private func enforceBounds() {
        if recordings.count > maximumRecordings {
            let victims = recordings.values.sorted {
                $0.lastUsedAt == $1.lastUsedAt ? $0.key.id < $1.key.id : $0.lastUsedAt < $1.lastUsedAt
            }.prefix(recordings.count - maximumRecordings)
            for victim in victims { recordings.removeValue(forKey: victim.key) }
        }
        if artists.count > maximumArtists {
            let victims = artists.values.sorted {
                $0.lastUsedAt == $1.lastUsedAt ? $0.id < $1.id : $0.lastUsedAt < $1.lastUsedAt
            }.prefix(artists.count - maximumArtists)
            for victim in victims { artists.removeValue(forKey: victim.id) }
        }
    }

    private func publish() {
        let projected = recordings.mapValues(\.distribution)
        guard projected != distributions else { return }
        distributions = projected
        revision &+= 1
        onChanged?()
    }

    private func markDirty() {
        dirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        guard disk != nil, isLoaded, saveTask == nil else { return }
        saveTask = Task(priority: .utility) { [weak self] in
            // Classification arrives in bursts of one request per second; coalescing writes keeps the file quiet.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.write()
        }
    }

    private func write() async {
        saveTask = nil
        guard let disk, dirty else { return }
        dirty = false
        storageRevision &+= 1
        let revision = storageRevision
        let snapshot = snapshot()
        let saved = await disk.save(snapshot)
        guard storageRevision == revision else { return }
        Self.log.info("event=genre_store_save ok=\(saved ? 1 : 0) recordings=\(snapshot.recordings.count) artists=\(snapshot.artists.count)")
        if !saved { dirty = true }
    }
}
