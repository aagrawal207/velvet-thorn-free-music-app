import AudioToolbox
import AVFoundation
import Foundation
import OSLog
import Synchronization

/// A complete, verified audio file on disk together with the stream metadata it was downloaded with.
struct CachedAudio: Equatable, Sendable {
    let trackID: String
    let url: URL
    let duration: TimeInterval?
    let loudnessDb: Double?
    let viewCount: Int64?
    let bytes: Int64
    let storedAt: Date
    let quality: SourceAudioQuality?
    let opusPreparationVersion: Int?
    let track: Track?
    /// True for the permanent download tier, which the cache limit and eviction never touch.
    let isDownloaded: Bool
    let playbackSource: MusicSource?

    init(trackID: String, url: URL, duration: TimeInterval?, loudnessDb: Double?, viewCount: Int64?,
         bytes: Int64, storedAt: Date, quality: SourceAudioQuality? = nil, opusPreparationVersion: Int? = nil,
         track: Track? = nil, isDownloaded: Bool = false, playbackSource: MusicSource? = nil) {
        self.trackID = trackID
        self.url = url
        self.duration = duration
        self.loudnessDb = loudnessDb
        self.viewCount = viewCount
        self.bytes = bytes
        self.storedAt = storedAt
        self.quality = quality
        self.opusPreparationVersion = opusPreparationVersion
        self.track = Self.displayMetadata(track, for: trackID)
        self.isDownloaded = isDownloaded
        self.playbackSource = playbackSource
    }

    var stream: ResolvedStream {
        ResolvedStream(url: url, duration: duration, expiresAt: nil, loudnessDb: loudnessDb, viewCount: viewCount,
                       quality: quality, playbackSource: playbackSource)
    }

    static func displayMetadata(_ track: Track?, for id: String) -> Track? {
        guard let track, track.id == id, (try? LibraryValidation.validateTrack(track)) != nil,
              let data = try? JSONEncoder().encode(track), data.count <= 48 << 10 else { return nil }
        return track
    }
}

/// Whole-file audio cache in the app's purgeable Caches directory. Each immutable encoding has its own JSON sidecar;
/// only size-verified pairs are playable; active preparation bytes are reported separately from the song count.
/// A second, permanent tier under Application Support holds downloads: same file layout, never counted or evicted.
actor AudioCache {
    typealias OpusPreparation = @Sendable (URL, URL) async throws -> OpusNativeAudio.Inspection
    typealias LocalDurationLoader = @Sendable (URL) async throws -> TimeInterval
    private typealias IndexedEntry = (trackID: String, entry: CachedAudio, accessedAt: Date)
    /// Lookup order: a downloaded copy wins over a temporary one so playback and export use the permanent file.
    enum Tier: CaseIterable, Sendable { case downloads, cache }

    struct Usage: Equatable, Sendable {
        let bytes: Int64
        let songCount: Int
        let retainedBytes: Int64
        let retainedSongCount: Int
        let capacityBytes: Int64
        let maximumSongs: Int
        let pendingDownloads: Int
        let downloadedBytes: Int64
        let downloadedSongCount: Int

        init(bytes: Int64, songCount: Int, retainedBytes: Int64, retainedSongCount: Int, capacityBytes: Int64,
             maximumSongs: Int, pendingDownloads: Int, downloadedBytes: Int64 = 0, downloadedSongCount: Int = 0) {
            self.bytes = bytes
            self.songCount = songCount
            self.retainedBytes = retainedBytes
            self.retainedSongCount = retainedSongCount
            self.capacityBytes = capacityBytes
            self.maximumSongs = maximumSongs
            self.pendingDownloads = pendingDownloads
            self.downloadedBytes = downloadedBytes
            self.downloadedSongCount = downloadedSongCount
        }
    }

    enum DownloadTierChange: Equatable, Sendable {
        case moved(bytes: Int64), alreadyThere(bytes: Int64), notFound
    }

    enum DownloadDeletion: Equatable, Sendable {
        case deleted(bytes: Int64), demotedInUse(bytes: Int64), notFound
    }

    struct WritePermit: Sendable {
        fileprivate let generation: UUID
    }

    enum ManagementError: LocalizedError {
        case clearing
        case invalidDirectory
        case unexpectedFile
        case limitNotApplied
        case admissionDeferred

        var errorDescription: String? {
            switch self {
            case .clearing: "The audio cache is busy. Please try again in a moment."
            case .invalidDirectory: "The temporary audio folder could not be opened safely."
            case .unexpectedFile: "An unexpected item in the audio cache could not be removed safely."
            case .limitNotApplied: "This playback provider could not apply the requested audio cache limit."
            case .admissionDeferred: "This suggested song wasn’t cached so previously listened audio can stay available."
            }
        }
    }

    struct Sidecar: Codable, Equatable, Sendable {
        var duration: TimeInterval?
        var loudnessDb: Double?
        var viewCount: Int64?
        var bytes: Int64
        var storedAt: Date
        var fileExtension: String?
        var quality: SourceAudioQuality?
        var opusPreparationVersion: Int?
        var track: Track?
        /// Written only as true in the download tier; absent keeps legacy sidecars byte-compatible.
        var downloaded: Bool?
        var playbackSource: MusicSource?

        init(duration: TimeInterval? = nil, loudnessDb: Double? = nil, viewCount: Int64? = nil, bytes: Int64, storedAt: Date,
             fileExtension: String? = nil, quality: SourceAudioQuality? = nil, opusPreparationVersion: Int? = nil,
             track: Track? = nil, downloaded: Bool? = nil, playbackSource: MusicSource? = nil) {
            self.duration = duration
            self.loudnessDb = loudnessDb
            self.viewCount = viewCount
            self.bytes = bytes
            self.storedAt = storedAt
            self.fileExtension = fileExtension
            self.quality = quality
            self.opusPreparationVersion = opusPreparationVersion
            self.track = track.flatMap { CachedAudio.displayMetadata($0, for: $0.id) }
            self.downloaded = downloaded == true ? true : nil
            self.playbackSource = playbackSource
        }

        private enum CodingKeys: String, CodingKey {
            case duration, loudnessDb, viewCount, bytes, storedAt, fileExtension, quality, opusPreparationVersion, track, downloaded
            case playbackSource
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration)
            loudnessDb = try values.decodeIfPresent(Double.self, forKey: .loudnessDb)
            viewCount = try values.decodeIfPresent(Int64.self, forKey: .viewCount)
            bytes = try values.decode(Int64.self, forKey: .bytes)
            storedAt = try values.decode(Date.self, forKey: .storedAt)
            fileExtension = try values.decodeIfPresent(String.self, forKey: .fileExtension)
            // Optional diagnostics must not invalidate an otherwise complete, playable cache entry.
            quality = try? values.decodeIfPresent(SourceAudioQuality.self, forKey: .quality)
            playbackSource = try? values.decodeIfPresent(MusicSource.self, forKey: .playbackSource)
            opusPreparationVersion = try values.decodeIfPresent(Int.self, forKey: .opusPreparationVersion)
            track = try? values.decodeIfPresent(Track.self, forKey: .track)
            downloaded = (try? values.decodeIfPresent(Bool.self, forKey: .downloaded)) == true ? true : nil
        }
    }

    private struct Flight {
        let trackID: String
        let token: UUID
        let task: Task<CachedAudio, Error>
        var waiters: Set<UUID>
        var foregroundWaiters: Set<UUID> = []
        var speculativeWaiters: Set<UUID> = []
        var isSpeculative: Bool { waiters.isSubset(of: speculativeWaiters) }
    }

    static let defaultDirectory = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory).appendingPathComponent("Audio", isDirectory: true)
    /// Application Support is not purgeable; backup exclusion keeps multi-gigabyte audio out of iCloud and iTunes.
    static let defaultDownloadsDirectory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory).appendingPathComponent("GanaBajana", isDirectory: true)
        .appendingPathComponent("Downloads", isDirectory: true)
    /// Larger than any plausible song; bounds a single download regardless of what the server declares.
    static let maximumFileBytes: Int64 = 64 << 20
    static let maximumOpusVariants = 2
    /// Songs with stale variants that one inventory read repairs; any remainder waits for the next read.
    static let maximumLoadDedupes = 500
    /// The download tier has no resolver hook, so its directories are registered here for URL ownership checks.
    nonisolated private static let downloadDirectories = Mutex<Set<String>>([])
    /// The resolver keeps its production cache private; the app's download manager reaches that instance here.
    nonisolated private static let installedCache = Mutex<WeakCache?>(nil)
    /// Mutation happens only inside `installedCache`'s lock; the weak reference itself needs no further protection.
    private final class WeakCache: @unchecked Sendable {
        weak var cache: AudioCache?
        init(_ cache: AudioCache) { self.cache = cache }
    }

    nonisolated let directory: URL
    nonisolated let downloadsDirectory: URL
    private var capacityBytes: Int64
    private var maximumFiles: Int
    private let downloader: AudioDownloader
    private let prepareOpus: OpusPreparation
    private let loadLocalDuration: LocalDurationLoader
    private let now: @Sendable () -> Date
    private var flights: [String: Flight] = [:]
    private var activeParts: [UUID: (trackID: String, urls: [URL])] = [:]
    private var rejected: Set<String> = []
    private var tail: Task<Void, Never>?
    private var pinned: Set<String> = []
    private var readers: [UUID: String] = [:]
    private var readerURLs: [UUID: URL] = [:]
    private var retiredReaderURLs: Set<URL> = []
    private var retentionPolicy = AudioCacheRetentionPolicy()
    private var generation = UUID()
    private var isMaintainingStorage = false
    private var retainedDuringMaintenance: Set<String> = []
    private var downloadsDirectoryPrepared = false
    /// Downloaded songs whose stale variants were in use when found; each is retried once its readers leave.
    private var pendingDedupe: Set<String> = []
    private var hasDedupedDownloadsAtLoad = false
    /// Download-tier membership from the last scan or tier move, readable without an actor hop or a disk read.
    nonisolated private let downloadedIndex = Mutex<Set<String>>([])
    nonisolated private let transferProgress = Mutex<[String: (written: Int64, expected: Int64)]>([:])
    private(set) var downloadingTrackID: String?
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "AudioCache")

    init(directory: URL? = nil, downloadsDirectory: URL? = nil, capacityBytes: Int64 = AudioCacheLimit.defaultLimit.bytes,
         maximumFiles: Int = AudioCacheLimit.defaultLimit.maximumSongs, session: URLSession? = nil,
         opusPreparation: @escaping OpusPreparation = { try await OpusNativeAudio.prepare(input: $0, output: $1) },
         localDurationLoader: LocalDurationLoader? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = (directory ?? Self.defaultDirectory).standardizedFileURL
        self.downloadsDirectory = (downloadsDirectory ?? Self.defaultDownloadsDirectory).standardizedFileURL
        self.capacityBytes = max(0, capacityBytes)
        self.maximumFiles = max(1, maximumFiles)
        downloader = AudioDownloader(session: session ?? Self.makeSession())
        prepareOpus = opusPreparation
        loadLocalDuration = localDurationLoader ?? { try await Self.nativeDuration($0) }
        self.now = now
        Self.downloadDirectories.withLock { _ = $0.insert(self.downloadsDirectory.path) }
        if directory == nil { Self.installedCache.withLock { $0 = WeakCache(self) } }
    }

    /// The cache serving the app's default directories, or nil in unit hosts that inject their own directories.
    nonisolated static var installed: AudioCache? { installedCache.withLock { $0?.cache } }

    /// Fixtures with custom directories opt in explicitly; production registers in `init`.
    nonisolated func install() { Self.installedCache.withLock { $0 = WeakCache(self) } }

    /// True when `url` is a media file inside any known download tier directory.
    nonisolated static func isDownloadedMediaURL(_ url: URL) -> Bool {
        guard url.isFileURL, AudioDownloader.mediaExtensions.contains(url.pathExtension), logicalTrackID(for: url) != nil else { return false }
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        return downloadDirectories.withLock { $0.contains(parent) }
    }

    var activeWaiterCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }
    var activeReaderCount: Int { readers.count }

    var totalBytes: Int64 { (try? usage(retaining: []).bytes) ?? 0 }

    var count: Int { Set(entries().map { $0.trackID }).count }

    /// Active preparation files count while on disk; unrelated or abandoned partial files do not count as downloads.
    func storageUsage() throws -> Usage {
        try usage(retaining: retainedTrackIDs)
    }

    func snapshot(allowOpus: Bool = true) throws -> AudioCacheSnapshot {
        do {
            var all = try verifiedEntries()
            if dedupeDownloadsAtLoad(all) { all = try verifiedEntries() }
            let retained = retainedTrackIDs
            let songs = Dictionary(grouping: all, by: \.trackID).map { id, variants in
                let ordered = variants.map(\.entry).sorted(by: Self.prefersForPlayback)
                let preferred = AudioCache.isProviderTrackID(id)
                    ? ordered.first { isEligible($0, allowOpus: allowOpus) } : nil
                return CachedSong(id: id, track: preferred?.track ?? ordered.compactMap(\.track).first,
                                  preferredAudio: preferred, bytes: ordered.reduce(0) { $0 + $1.bytes },
                                  variantCount: ordered.count, isInUse: retained.contains(id),
                                  isDownloaded: ordered.contains(where: \.isDownloaded))
            }.sorted { $0.id < $1.id }
            let result = AudioCacheSnapshot(usage: try usage(retaining: retained, entries: all), songs: songs)
            log.debug("event=audio_cache_inventory songs=\(songs.count) playable=\(songs.filter(\.isPlayable).count) downloaded=\(songs.filter(\.isDownloaded).count) metadata_missing=\(songs.filter { $0.track == nil }.count) failed=0")
            return result
        } catch {
            log.error("event=audio_cache_inventory failed=1")
            throw error
        }
    }

    func updateListeningHistory(_ events: [ListeningEvent], now: Date) {
        let ids = Set(entries().map(\.trackID)).union(retainedTrackIDs)
        retentionPolicy = AudioCacheRetentionPolicy(events: events, now: now, retaining: ids)
        log.debug("event=audio_cache_history recordings=\(self.retentionPolicy.signals.count)")
    }

    func writePermit() throws -> WritePermit {
        guard !isMaintainingStorage else { throw CancellationError() }
        return WritePermit(generation: generation)
    }

    /// A complete cached file, or nil. Reading counts as use for eviction; a size mismatch deletes the pair.
    /// Downloaded copies are found first so a permanent file is never bypassed for a temporary one.
    func entry(for trackID: String, allowOpus: Bool = true) -> CachedAudio? {
        guard Self.isValidTrackID(trackID) else { return nil }
        let keys = [Self.storageKey(for: trackID)] + opusStorageIDs(for: trackID)
        let available = keys.compactMap { loadStorage($0) }.filter { isEligible($0, allowOpus: allowOpus) }
        guard let entry = available.sorted(by: Self.prefersForPlayback).first else { return nil }
        if isMaintainingStorage { retainedDuringMaintenance.insert(trackID) }
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: entry.url.path)
        return entry
    }

    /// The lease belongs to the actual native reader, so an outer deadline cannot release its files prematurely.
    func preparedEntry(for trackID: String, allowOpus: Bool = true) async throws -> CachedAudio? {
        try await withLocalCopy(for: trackID, allowOpus: allowOpus) { $0 }
    }

    /// The caller must await its native reader's cleanup; cancellation never releases the lease ahead of that return.
    func withLocalCopy<Result: Sendable>(for trackID: String, allowOpus: Bool = true,
                                        operation: @Sendable (CachedAudio) async throws -> Result) async throws -> Result? {
        try Task.checkCancellation()
        guard Self.isValidTrackID(trackID) else { return nil }
        for _ in 0...Self.maximumOpusVariants {
            try Task.checkCancellation()
            let lease = UUID()
            readers[lease] = trackID
            if isMaintainingStorage { retainedDuringMaintenance.insert(trackID) }
            defer {
                readers.removeValue(forKey: lease)
                readerURLs.removeValue(forKey: lease)
                retireDeferredFiles()
            }
            guard let audio = entry(for: trackID, allowOpus: allowOpus) else { return nil }
            readerURLs[lease] = audio.url
            let prepared: CachedAudio
            do {
                if audio.duration != nil { prepared = audio }
                else {
                    let duration = try await loadLocalDuration(audio.url)
                    try Task.checkCancellation()
                    guard PlaybackTiming.validDuration(duration) != nil else { throw PlaybackStreamError.invalidMedia }
                    log.debug("event=audio_cache_local_inspection rejected=0")
                    prepared = CachedAudio(trackID: audio.trackID, url: audio.url, duration: duration, loudnessDb: audio.loudnessDb,
                                           viewCount: audio.viewCount, bytes: audio.bytes, storedAt: audio.storedAt,
                                           quality: audio.quality, opusPreparationVersion: audio.opusPreparationVersion, track: audio.track,
                                           isDownloaded: audio.isDownloaded, playbackSource: audio.playbackSource)
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                rejectPlaybackFile(audio.url)
                log.notice("event=audio_cache_local_inspection rejected=1")
                continue
            }
            try Task.checkCancellation()
            return try await operation(prepared)
        }
        return nil
    }

    private static func nativeDuration(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        defer { asset.cancelLoading() }
        return try await withTaskCancellationHandler {
            let duration = try await asset.load(.duration)
            try Task.checkCancellation()
            guard let seconds = PlaybackTiming.validDuration(duration.seconds) else { throw PlaybackStreamError.invalidMedia }
            return seconds
        } onCancel: { asset.cancelLoading() }
    }

    private func isEligible(_ entry: CachedAudio, allowOpus: Bool) -> Bool {
        !rejected.contains(Self.storageID(of: entry.url))
            && (entry.quality?.codec != .opus || (allowOpus && entry.opusPreparationVersion == 1))
    }

    private static func prefers(_ left: CachedAudio, _ right: CachedAudio) -> Bool {
        if SourceAudioQuality.prefers(left.quality, over: right.quality) { return true }
        if SourceAudioQuality.prefers(right.quality, over: left.quality) { return false }
        if left.storedAt != right.storedAt { return left.storedAt > right.storedAt }
        return left.url.lastPathComponent < right.url.lastPathComponent
    }

    /// The download tier wins regardless of encoding: it is the copy the listener chose to keep.
    private static func prefersForPlayback(_ left: CachedAudio, _ right: CachedAudio) -> Bool {
        if left.isDownloaded != right.isDownloaded { return left.isDownloaded }
        return prefers(left, right)
    }

    private var retainedTrackIDs: Set<String> { pinned.union(readers.values).union(retainedDuringMaintenance) }

    func pin(_ trackID: String) {
        guard Self.isValidTrackID(trackID) else { return }
        pinned.insert(trackID)
        if isMaintainingStorage { retainedDuringMaintenance.insert(trackID) }
    }

    func unpin(_ trackID: String) {
        pinned.remove(trackID)
        retireDeferredFiles()
    }

    /// Replaces the pinned set so the caller does not have to remember what it pinned earlier.
    func pin(only trackIDs: Set<String>) {
        pinned = trackIDs.filter(Self.isValidTrackID)
        if isMaintainingStorage { retainedDuringMaintenance.formUnion(pinned) }
        retireDeferredFiles()
    }

    /// A copy the player could not use is corrupt in either tier; a protected one is only marked rejected.
    func remove(trackID: String) {
        guard Self.isValidTrackID(trackID) else { return }
        for tier in Tier.allCases {
            guard let files = try? tierFiles(tier) else { continue }
            if isProtected(trackID) {
                for file in files where file.trackID == trackID && file.url.pathExtension == "json" {
                    rejected.insert(Self.storageID(of: file.url))
                }
                continue
            }
            for file in files where file.trackID == trackID { try? Self.removeCacheFile(file.url) }
        }
    }

    /// Rejected encodings stay on disk while pinned, but cannot win a subsequent resolution.
    func rejectPlaybackFile(_ url: URL) {
        guard let tier = tier(containing: url),
              AudioDownloader.mediaExtensions.contains(url.pathExtension),
              let id = Self.logicalTrackID(for: url) else { return }
        let key = Self.storageID(of: url)
        rejected.insert(key)
        if !isProtected(id) { removeStorage(key, tier: tier) }
    }

    private func tier(containing url: URL) -> Tier? {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return Tier.allCases.first { self.directory(for: $0) == parent }
    }

    private func directory(for tier: Tier) -> URL { tier == .cache ? directory : downloadsDirectory }

    func removeAll() async {
        do { _ = try await clearUnused() }
        catch { log.error("event=audio_cache_clear_failed") }
    }

    /// The live snapshot runs after writers stop; reads and pin changes during that wait also retain their files.
    func clearUnused(retaining liveTrackIDs: @Sendable () async -> Set<String> = { [] }) async throws -> Usage {
        try await beginStorageMaintenance()
        defer { endStorageMaintenance() }
        await retainLiveFiles(liveTrackIDs)
        retirePendingDedupes()

        let activePaths = Set(activeParts.values.flatMap { $0.urls }.map(Self.comparablePath))
        for file in try cacheFiles() where !activePaths.contains(Self.comparablePath(file.url))
            && (file.url.pathExtension == "part" || !retainedDuringMaintenance.contains(file.trackID)) {
            try Self.removeCacheFile(file.url)
        }
        let result = try usage(retaining: retainedDuringMaintenance)
        log.info("event=audio_cache_cleared retained_songs=\(result.retainedSongCount) retained_bytes=\(result.retainedBytes)")
        return result
    }

    func removeSong(id: String, retaining liveTrackIDs: @Sendable () async -> Set<String> = { [] }) async throws -> AudioCacheRemoval {
        guard Self.isValidTrackID(id) else { throw PlaybackStreamError.invalidID }
        do {
            try await beginStorageMaintenance()
            defer { endStorageMaintenance() }
            await retainLiveFiles(liveTrackIDs)
            try Task.checkCancellation()
            retirePendingDedupes()
            let files = try cacheFiles().filter { $0.trackID == id }
            let outcome: CachedSongRemoval
            if files.isEmpty { outcome = .notFound }
            else if retainedDuringMaintenance.contains(id) { outcome = .inUse }
            else {
                for file in files { try Self.removeCacheFile(file.url) }
                rejected.subtract(files.map { Self.storageID(of: $0.url) })
                outcome = .removed
            }
            let result = AudioCacheRemoval(outcome: outcome, usage: try usage(retaining: retainedDuringMaintenance))
            log.info("event=audio_cache_remove removed=\(outcome == .removed ? 1 : 0) not_found=\(outcome == .notFound ? 1 : 0) in_use=\(outcome == .inUse ? 1 : 0) failed=0")
            return result
        } catch {
            log.error("event=audio_cache_remove removed=0 not_found=0 in_use=0 failed=1")
            throw error
        }
    }

    func cancelDownloads() async {
        do {
            try await beginStorageMaintenance()
            endStorageMaintenance()
        } catch { }
    }

    func updatePolicy(capacityBytes: Int64, maximumFiles: Int,
                      retaining liveTrackIDs: @Sendable () async -> Set<String> = { [] }) async throws -> Usage {
        try await beginStorageMaintenance()
        defer { endStorageMaintenance() }
        await retainLiveFiles(liveTrackIDs)
        retirePendingDedupes()
        let previousCapacity = self.capacityBytes
        let previousMaximum = self.maximumFiles
        self.capacityBytes = max(0, capacityBytes)
        self.maximumFiles = max(1, maximumFiles)
        do {
            try evictToPolicy(retaining: retainedDuringMaintenance)
            let result = try usage(retaining: retainedDuringMaintenance)
            log.info("event=audio_cache_limit_applied capacity=\(result.capacityBytes) maximum_songs=\(result.maximumSongs)")
            return result
        } catch {
            self.capacityBytes = previousCapacity
            self.maximumFiles = previousMaximum
            log.error("event=audio_cache_limit_failed")
            throw error
        }
    }

    private func beginStorageMaintenance() async throws {
        try Task.checkCancellation()
        guard !isMaintainingStorage else { throw ManagementError.clearing }
        isMaintainingStorage = true
        generation = UUID()
        retainedDuringMaintenance = pinned.union(readers.values)
        let pending = Array(flights.values)
        let previousTail = tail
        flights.removeAll()
        pending.forEach { $0.task.cancel() }
        // The tail includes cancelled writers whose last waiter already left the flights dictionary.
        await previousTail?.value
        tail = nil
        downloadingTrackID = nil
    }

    private func endStorageMaintenance() {
        isMaintainingStorage = false
        retainedDuringMaintenance.removeAll()
    }

    private func retainLiveFiles(_ liveTrackIDs: @Sendable () async -> Set<String>) async {
        let live = await liveTrackIDs()
        retainedDuringMaintenance.formUnion(live.filter(Self.isValidTrackID))
        retainedDuringMaintenance.formUnion(pinned)
        retainedDuringMaintenance.formUnion(readers.values)
    }

    func waitForCopyInProgress(of trackID: String, allowOpus: Bool, seconds: TimeInterval) async -> Bool {
        guard let work = flights[trackID]?.task else { return false }
        // The writer's own outcome does not matter here; only the published entry does.
        _ = try? await PlaybackDeadline.run(seconds: seconds) { try await work.value }
        return hasCompleteCopy(of: trackID, allowOpus: allowOpus)
    }

    /// Downloads `remote` completely, verifies its length against the declared size, and publishes it for `trackID`.
    /// Concurrent requests for one track share a download; different tracks download one at a time.
    func store(trackID: String, from remote: URL, stream: ResolvedStream, permit: WritePermit? = nil,
               track: Track? = nil, speculative: Bool = false) async throws -> CachedAudio {
        try Task.checkCancellation()
        guard !isMaintainingStorage, permit == nil || permit?.generation == generation else { throw CancellationError() }
        guard Self.isValidTrackID(trackID) else { throw PlaybackStreamError.invalidID }
        _ = try directoryContents()
        let startedGeneration = generation
        if let existing = loadStorage(Self.storageKey(for: trackID)) {
            guard existing.quality?.codec != .opus else { throw OpusPreparationError.invalidOutput }
            return existing
        }
        // A downloaded song has one home: its file answers even when that file is not the base encoding.
        if let downloaded = downloadedKeeper(for: trackID) { return downloaded.entry }
        let waiter = UUID()
        let token: UUID
        let work: Task<CachedAudio, Error>
        if var flight = flights[trackID] {
            flight.waiters.insert(waiter)
            if speculative { flight.speculativeWaiters.insert(waiter) }
            flights[trackID] = flight
            token = flight.token
            work = flight.task
        } else {
            token = UUID()
            let predecessor = tail
            let downloader = self.downloader
            let limit = min(Self.maximumFileBytes, max(capacityBytes, 1))
            let temporary = partURL(trackID)
            work = Task.detached(priority: .utility) { [self] in
                do {
                    await predecessor?.value
                    try Task.checkCancellation()
                    guard await self.began(trackID, token: token, parts: [temporary]) else { throw CancellationError() }
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let part = try await downloader.receive(trackID: trackID, from: remote, into: directory,
                        limit: limit, temporary: temporary, reserve: { bytes in
                            try await self.reserveDownload(trackID: trackID, token: token, generation: startedGeneration,
                                                           bytes: bytes, temporary: temporary)
                        }, progress: { written, expected in
                            self.recordTransferProgress(trackID, written: written, expected: expected)
                        })
                    let cached = try await self.commitDownload(part, trackID: trackID, token: token,
                                                               generation: startedGeneration, stream: stream, track: track)
                    await self.finished(trackID, token: token, retaining: trackID)
                    return cached
                } catch {
                    await self.finished(trackID, token: token)
                    try Task.checkCancellation()
                    throw error
                }
            }
            tail = Task { _ = try? await work.value }
            flights[trackID] = Flight(trackID: trackID, token: token, task: work, waiters: [waiter],
                                      speculativeWaiters: speculative ? [waiter] : [])
        }
        return try await withTaskCancellationHandler {
            defer { release(trackID, token: token, waiter: waiter) }
            // Task.value ignores the waiter's own cancellation; the deadline race returns promptly and bounds a stuck transfer.
            let cached = try await PlaybackDeadline.run(seconds: 900) { try await work.value }
            try Task.checkCancellation()
            guard startedGeneration == generation else { throw CancellationError() }
            return cached
        } onCancel: {
            Task { await self.release(trackID, token: token, waiter: waiter) }
        }
    }

    private func reserveDownload(trackID: String, token: UUID, generation startedGeneration: UUID,
                                 bytes: Int64, temporary: URL) throws {
        try Task.checkCancellation()
        guard !isMaintainingStorage, generation == startedGeneration, let flight = flights[trackID], flight.token == token else {
            throw CancellationError()
        }
        try evictToPolicy(retaining: retainedTrackIDs, reservingBytes: bytes, reservingTrackID: trackID,
                          excludingParts: [temporary], speculative: flight.isSpeculative && !retainedTrackIDs.contains(trackID))
    }

    private func commitDownload(_ part: AudioDownloader.Part, trackID: String, token: UUID, generation: UUID,
                                stream: ResolvedStream, track: Track?) throws -> CachedAudio {
        try reserveDownload(trackID: trackID, token: token, generation: generation, bytes: part.bytes, temporary: part.url)
        let published = try downloader.publish(part, trackID: trackID, stream: stream, into: directory,
                                               track: CachedAudio.displayMetadata(track, for: trackID), storedAt: now())
        return try adopt(published, key: Self.storageKey(for: trackID), token: token)
    }

    func storeOpus(trackID: String, stream: ResolvedStream, permit: WritePermit, foreground: Bool,
                   track: Track? = nil, speculative: Bool = false) async throws -> CachedAudio {
        try Task.checkCancellation()
        guard !isMaintainingStorage, permit.generation == generation else { throw CancellationError() }
        guard Self.isValidTrackID(trackID), stream.quality?.codec == .opus else { throw PlaybackStreamError.invalidMedia }
        try StreamValidation.validateSourceURL(stream.url)
        let requestedRate = stream.quality?.bitRate ?? 0
        let available = opusStorageIDs(for: trackID).compactMap { loadStorage($0) }
            .filter { $0.opusPreparationVersion == 1 && ($0.quality?.bitRate ?? 0) >= requestedRate }
        if let existing = available.sorted(by: Self.prefers).first {
            return existing
        }
        // Only a better encoding may replace a downloaded file; a lesser request plays the download instead.
        if let downloaded = downloadedKeeper(for: trackID), !SourceAudioQuality.prefers(stream.quality, over: downloaded.entry.quality) {
            log.debug("event=download_admission outcome=refused")
            return downloaded.entry
        }
        let key = "\(trackID)|opus|\(requestedRate)|\(stream.quality?.sampleRate ?? 0)|\(stream.quality?.channels ?? 0)"
        if foreground { cancelBackgroundStores(except: key) }
        let startedGeneration = generation
        let waiter = UUID()
        let token: UUID
        let work: Task<CachedAudio, Error>
        if var flight = flights[key] {
            flight.waiters.insert(waiter)
            if foreground { flight.foregroundWaiters.insert(waiter) }
            if speculative { flight.speculativeWaiters.insert(waiter) }
            flights[key] = flight
            token = flight.token
            work = flight.task
        } else {
            token = UUID()
            let predecessor = tail
            let input = partURL(trackID)
            let storageID = "\(Self.storageKey(for: trackID)).opus-\(UUID().uuidString)"
            let output = mediaURL(storageID, fileExtension: "m4a")
            work = Task.detached(priority: foreground ? .userInitiated : .utility) { [self] in
                do {
                    await predecessor?.value
                    try Task.checkCancellation()
                    guard await began(key, token: token, parts: [input, output]) else { throw CancellationError() }
                    let cached = try await prepareOpusEntry(trackID: trackID, key: key, token: token, generation: startedGeneration,
                                                          stream: stream, input: input, output: output, storageID: storageID, track: track)
                    await finished(key, token: token, retaining: trackID)
                    return cached
                } catch {
                    await finished(key, token: token)
                    try Task.checkCancellation()
                    throw error
                }
            }
            tail = Task { _ = try? await work.value }
            flights[key] = Flight(trackID: trackID, token: token, task: work, waiters: [waiter],
                                   foregroundWaiters: foreground ? [waiter] : [], speculativeWaiters: speculative ? [waiter] : [])
        }
        return try await withTaskCancellationHandler {
            defer { release(key, token: token, waiter: waiter) }
            let result = try await PlaybackDeadline.run(seconds: 60) { try await work.value }
            try Task.checkCancellation()
            guard startedGeneration == generation else { throw CancellationError() }
            return result
        } onCancel: { Task { await self.release(key, token: token, waiter: waiter) } }
    }

    private func prepareOpusEntry(trackID: String, key: String, token: UUID, generation startedGeneration: UUID,
                                  stream: ResolvedStream, input: URL, output: URL, storageID: String, track: Track?) async throws -> CachedAudio {
        var published = false
        defer {
            try? FileManager.default.removeItem(at: input)
            if !published {
                try? FileManager.default.removeItem(at: output)
                try? FileManager.default.removeItem(at: sidecarURL(storageID))
            }
        }
        try Task.checkCancellation()
        // Variant rotation only ever touches the temporary tier; downloaded variants are never a rotation victim.
        let versions = opusStorageIDs(for: trackID, tier: .cache)
        guard versions.count < Self.maximumOpusVariants || !retainedTrackIDs.contains(trackID) else { throw OpusPreparationError.insufficientSpace }
        // The bridge bounds each local file to 64 MiB; reserve both input and output before starting either writer.
        let reservation = Self.maximumFileBytes * 2
        try evictToPolicy(retaining: retainedTrackIDs, reservingBytes: reservation, reservingTrackID: trackID,
                          excludingParts: [input, output],
                          speculative: flights[key]?.isSpeculative == true && !retainedTrackIDs.contains(trackID))
        guard capacityBytes - (try storageUsage().bytes) >= reservation else {
            throw OpusPreparationError.insufficientSpace
        }
        _ = try await downloader.receive(trackID: trackID, from: stream.url, into: directory,
                                         limit: Self.maximumFileBytes, temporary: input, expectedExtension: "webm",
                                         progress: { [self] written, expected in
                                             recordTransferProgress(trackID, written: written, expected: expected)
                                         })
        try Task.checkCancellation()
        let inspected = try await prepareOpus(input, output)
        try Task.checkCancellation()
        guard !retainedTrackIDs.contains(trackID) || opusStorageIDs(for: trackID, tier: .cache).count < Self.maximumOpusVariants else {
            throw OpusPreparationError.insufficientSpace
        }
        guard !isMaintainingStorage, generation == startedGeneration, flights[key]?.token == token,
              inspected.sampleRate == 48_000, (1...2).contains(inspected.channels),
              inspected.decodedFrames > 0, inspected.decodedBytes > 0,
              let duration = PlaybackTiming.validDuration(inspected.duration),
              let attributes = try Self.attributesIfPresent(output), attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0, size <= Self.maximumFileBytes else {
            if generation != startedGeneration || isMaintainingStorage { throw CancellationError() }
            throw OpusPreparationError.invalidOutput
        }
        let quality = SourceAudioQuality(codec: .opus, bitRate: stream.quality?.bitRate,
                                          sampleRate: inspected.sampleRate, channels: inspected.channels)
        try evictToPolicy(retaining: retainedTrackIDs, reservingBytes: size, reservingTrackID: trackID,
                          excludingParts: [output],
                          speculative: flights[key]?.isSpeculative == true && !retainedTrackIDs.contains(trackID))
        let sidecar = Sidecar(duration: duration, loudnessDb: stream.loudnessDb, viewCount: stream.viewCount,
                              bytes: size, storedAt: now(), fileExtension: "m4a", quality: quality, opusPreparationVersion: 1,
                              track: CachedAudio.displayMetadata(track, for: trackID), playbackSource: stream.playbackSource)
        let metadata = try JSONEncoder().encode(sidecar)
        try metadata.write(to: sidecarURL(storageID), options: .atomic)
        let prepared = CachedAudio(trackID: trackID, url: output, duration: duration, loudnessDb: sidecar.loudnessDb,
                                   viewCount: sidecar.viewCount, bytes: size, storedAt: sidecar.storedAt,
                                   quality: quality, opusPreparationVersion: 1, track: sidecar.track, playbackSource: sidecar.playbackSource)
        if isDownloadedOnDisk(trackID) {
            // A downloaded song's variant lives in its tier; the cache rotation below never sees it.
            let adopted = try adopt(prepared, key: storageID, token: token)
            published = true
            log.info("event=opus_cache_prepared bytes=\(size)")
            return adopted
        }
        if !retainedTrackIDs.contains(trackID) {
            let older = versions.compactMap { try? verifiedEntry($0, tier: .cache) }
                .sorted(by: Self.prefers)
            for old in older.dropFirst(Self.maximumOpusVariants - 1) {
                try Self.removeCacheFile(old.url)
                try Self.removeCacheFile(sidecarURL(Self.storageID(of: old.url)))
            }
        }
        guard opusStorageIDs(for: trackID, tier: .cache).count <= Self.maximumOpusVariants else { throw OpusPreparationError.insufficientSpace }
        published = true
        log.info("event=opus_cache_prepared bytes=\(size)")
        return prepared
    }

    private func cancelBackgroundStores(except key: String) {
        for (id, flight) in flights where id != key && flight.foregroundWaiters.isEmpty {
            flights.removeValue(forKey: id)
            flight.task.cancel()
        }
    }

    // MARK: - Flight bookkeeping

    private func began(_ key: String, token: UUID, parts: [URL]) -> Bool {
        guard !isMaintainingStorage, let flight = flights[key], flight.token == token else { return false }
        downloadingTrackID = flight.trackID
        activeParts[token] = (flight.trackID, parts)
        return true
    }

    private func finished(_ key: String, token: UUID, retaining trackID: String? = nil) {
        if let owner = activeParts[token]?.trackID {
            if downloadingTrackID == owner { downloadingTrackID = nil }
            transferProgress.withLock { _ = $0.removeValue(forKey: owner) }
        }
        activeParts.removeValue(forKey: token)
        if flights[key]?.token == token { flights.removeValue(forKey: key) }
        if !isMaintainingStorage { evictIfNeeded(retaining: trackID.map { [$0] } ?? []) }
    }

    nonisolated private func recordTransferProgress(_ trackID: String, written: Int64, expected: Int64) {
        transferProgress.withLock { $0[trackID] = (written, expected) }
    }

    /// Fraction of the active transfer for `trackID`, or nil when nothing is being received right now.
    nonisolated func transferProgress(for trackID: String) -> Double? {
        transferProgress.withLock { state in
            guard let entry = state[trackID], entry.expected > 0 else { return nil }
            return min(1, max(0, Double(entry.written) / Double(entry.expected)))
        }
    }

    /// Idempotent per waiter: cancellation and the normal exit path may both release the same waiter.
    private func release(_ trackID: String, token: UUID, waiter: UUID) {
        guard var flight = flights[trackID], flight.token == token, flight.waiters.remove(waiter) != nil else { return }
        flight.foregroundWaiters.remove(waiter)
        flight.speculativeWaiters.remove(waiter)
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: trackID)
            flight.task.cancel()
            if downloadingTrackID == trackID { downloadingTrackID = nil }
        } else {
            flights[trackID] = flight
        }
    }

    // MARK: - Disk index

    private func evictIfNeeded(retaining trackIDs: Set<String> = []) {
        pruneStrays()
        retirePendingDedupes()
        do { try evictToPolicy(retaining: retainedTrackIDs.union(trackIDs)) }
        catch { log.error("event=audio_cache_eviction_failed") }
    }

    private func evictToPolicy(retaining trackIDs: Set<String>, reservingBytes: Int64 = 0,
                               reservingTrackID: String? = nil, excludingParts: Set<URL> = [], speculative: Bool = false) throws {
        // Only the temporary tier is subject to the limit; downloaded bytes never count and never become victims.
        let entries = try verifiedEntries(tier: .cache)
        let time = now()
        var groups = retentionPolicy.evictionOrder(Dictionary(grouping: entries, by: \.trackID).map { id, values in
            AudioCacheRetentionPolicy.Candidate(id: id, bytes: values.reduce(0) { $0 + $1.entry.bytes },
                                                 accessedAt: values.map(\.accessedAt).max() ?? .distantPast)
        }, now: time)
        let extraSong = reservingTrackID.map { id in groups.contains { $0.id == id } ? 0 : 1 } ?? 0
        var bytes = try preparationBytes(entries: entries, excluding: excludingParts) + groups.reduce(0) { $0 + $1.bytes }
        let target = max(0, capacityBytes - reservingBytes)
        guard bytes > target || groups.count + extraSong > maximumFiles else {
            if speculative { log.debug("event=audio_cache_admission deferred=0") }
            return
        }
        let working = Set(flights.values.map(\.trackID)).union(activeParts.values.map { $0.trackID })
        let protected = trackIDs.union(retainedTrackIDs).union(working)
        let admissionScore = reservingTrackID.map { retentionPolicy.score(for: $0, now: time) } ?? 0
        var victims: [AudioCacheRetentionPolicy.Candidate] = []
        while bytes > target || groups.count + extraSong > maximumFiles {
            guard let index = groups.firstIndex(where: { !protected.contains($0.id) && $0.id != reservingTrackID }) else { break }
            if speculative, retentionPolicy.score(for: groups[index].id, now: time) > admissionScore { break }
            let victim = groups.remove(at: index)
            bytes -= victim.bytes
            victims.append(victim)
        }
        if speculative, bytes > target || groups.count + extraSong > maximumFiles {
            log.debug("event=audio_cache_admission deferred=1")
            throw ManagementError.admissionDeferred
        }
        if speculative { log.debug("event=audio_cache_admission deferred=0") }
        let files = Dictionary(grouping: try cacheFiles(), by: \.trackID)
        for victim in victims {
            for file in files[victim.id, default: []] { try Self.removeCacheFile(file.url) }
            log.info("event=audio_cache_evicted bytes=\(victim.bytes)")
        }
        log.debug("event=audio_cache_policy removed=\(victims.count) protected_overage=\(max(0, bytes - target))")
    }

    private func pruneStrays() {
        guard let files = try? cacheFiles() else { return }
        for file in files where !isProtected(file.trackID) {
            let isPart = file.url.pathExtension == "part"
            let isOrphan = AudioDownloader.mediaExtensions.contains(file.url.pathExtension)
                && !FileManager.default.fileExists(atPath: sidecarURL(Self.storageID(of: file.url)).path)
            if isPart || isOrphan || rejected.contains(Self.storageID(of: file.url)) { try? Self.removeCacheFile(file.url) }
        }
        rejected = rejected.filter { key in Tier.allCases.contains { FileManager.default.fileExists(atPath: sidecarURL(key, tier: $0).path) } }
    }

    private func entries() -> [IndexedEntry] {
        (try? verifiedEntries()) ?? []
    }

    private func verifiedEntries(tier: Tier? = nil) throws -> [IndexedEntry] {
        let tiers = tier.map { [$0] } ?? Tier.allCases
        let entries = try tiers.flatMap { tier in
            try directoryContents(tier).filter { $0.pathExtension == "json" }.compactMap { sidecar -> IndexedEntry? in
                let key = Self.storageID(of: sidecar)
                guard let trackID = Self.logicalTrackID(for: sidecar), let entry = try verifiedEntry(key, tier: tier) else { return nil }
                let accessed = (try? FileManager.default.attributesOfItem(atPath: entry.url.path)[.modificationDate] as? Date) ?? entry.storedAt
                return (trackID, entry, accessed)
            }
        }
        if tiers.contains(.downloads) {
            let downloaded = Set(entries.filter(\.entry.isDownloaded).map(\.trackID))
            downloadedIndex.withLock { $0 = downloaded }
        }
        return entries
    }

    /// Each tier is verified on its own so a stale pair in one tier never deletes the good pair in the other.
    private func loadStorage(_ key: String) -> CachedAudio? {
        guard !rejected.contains(key), let trackID = Self.logicalTrackID(forStorageID: key) else { return nil }
        for tier in Tier.allCases {
            do {
                _ = try directoryContents(tier)
                if let entry = try verifiedEntry(key, tier: tier) { return entry }
                if !isProtected(trackID) { removeStorage(key, tier: tier) }
            } catch { log.error("event=audio_cache_read_failed") }
        }
        return nil
    }

    private func verifiedEntry(_ key: String, tier: Tier) throws -> CachedAudio? {
        guard let trackID = Self.logicalTrackID(forStorageID: key),
              let sidecar = try readSidecar(key, tier: tier), sidecar.bytes > 0, sidecar.bytes <= Self.maximumFileBytes else { return nil }
        let fileExtension = sidecar.fileExtension ?? "m4a"
        guard AudioDownloader.mediaExtensions.contains(fileExtension) else { return nil }
        let isBaseKey = key == Self.storageKey(for: trackID)
        if !isBaseKey, fileExtension != "m4a" || sidecar.opusPreparationVersion == nil { return nil }
        let media = mediaURL(key, fileExtension: fileExtension, tier: tier)
        guard let attributes = try Self.attributesIfPresent(media), attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value == sidecar.bytes else { return nil }
        let quality: SourceAudioQuality? = isBaseKey ? sidecar.quality
            : (sidecar.quality?.codec == .opus ? sidecar.quality : SourceAudioQuality(codec: .opus))
        return CachedAudio(trackID: trackID, url: media, duration: PlaybackTiming.validDuration(sidecar.duration),
                            loudnessDb: sidecar.loudnessDb, viewCount: sidecar.viewCount, bytes: sidecar.bytes,
                            storedAt: sidecar.storedAt, quality: quality, opusPreparationVersion: sidecar.opusPreparationVersion,
                            track: sidecar.track, isDownloaded: tier == .downloads, playbackSource: sidecar.playbackSource)
    }

    private func readSidecar(_ key: String, tier: Tier = .cache) throws -> Sidecar? {
        let url = sidecarURL(key, tier: tier)
        guard let attributes = try Self.attributesIfPresent(url), attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 64 << 10 else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try? JSONDecoder().decode(Sidecar.self, from: data)
        } catch where Self.isMissing(error) { return nil }
    }

    private func usage(retaining trackIDs: Set<String>, entries: [IndexedEntry]? = nil) throws -> Usage {
        let all = try entries ?? verifiedEntries()
        let cached = all.filter { !$0.entry.isDownloaded }
        let downloaded = all.filter(\.entry.isDownloaded)
        let retained = cached.filter { trackIDs.contains($0.trackID) }
        let temporaryBytes = try preparationBytes(entries: all)
        let pending = Set(flights.values.map(\.token)).union(activeParts.keys).count
        return Usage(bytes: cached.reduce(temporaryBytes) { $0 + $1.entry.bytes }, songCount: Set(cached.map { $0.trackID }).count,
                      retainedBytes: retained.reduce(0) { $0 + $1.entry.bytes }, retainedSongCount: Set(retained.map { $0.trackID }).count,
                      capacityBytes: capacityBytes, maximumSongs: maximumFiles, pendingDownloads: pending,
                      downloadedBytes: downloaded.reduce(0) { $0 + $1.entry.bytes },
                      downloadedSongCount: Set(downloaded.map { $0.trackID }).count)
    }

    private func preparationBytes(entries all: [IndexedEntry], excluding: Set<URL> = []) throws -> Int64 {
        let completePaths = Set(all.map { Self.comparablePath($0.entry.url) })
        var temporaryBytes: Int64 = 0
        let temporaryURLs = Set(activeParts.values.flatMap { $0.urls }).union(readerURLs.values).union(retiredReaderURLs)
        for url in temporaryURLs where !completePaths.contains(Self.comparablePath(url)) && !excluding.contains(url) {
            if let attributes = try Self.attributesIfPresent(url), attributes[.type] as? FileAttributeType == .typeRegular {
                temporaryBytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return temporaryBytes
    }

    private func directoryContents(_ tier: Tier = .cache) throws -> [URL] {
        let directory = directory(for: tier)
        guard directory.isFileURL else { throw ManagementError.invalidDirectory }
        guard let attributes = try Self.attributesIfPresent(directory) else { return [] }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ManagementError.invalidDirectory }
        do { return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch where Self.isMissing(error) { return [] }
    }

    private static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch where Self.isMissing(error) { return nil }
    }

    private static func isMissing(_ error: any Error) -> Bool {
        guard let error = error as? CocoaError else { return false }
        return error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }

    /// Only the cache's filename formats are owned; a stray library file or subdirectory is never bulk-deleted.
    private func cacheFiles() throws -> [(trackID: String, url: URL)] {
        try tierFiles(.cache)
    }

    private func tierFiles(_ tier: Tier) throws -> [(trackID: String, url: URL)] {
        let items = try directoryContents(tier)
        let mediaIDs = Set(items.filter { AudioDownloader.mediaExtensions.contains($0.pathExtension) }.map(Self.storageID))
        return try items.compactMap { url in
            let key = Self.storageID(of: url)
            if let id = Self.logicalTrackID(for: url) {
                if AudioDownloader.mediaExtensions.contains(url.pathExtension) { return (id, url) }
                if url.pathExtension == "json" {
                    if mediaIDs.contains(key) { return (id, url) }
                    if try readSidecar(key, tier: tier) != nil { return (id, url) }
                }
            }
            if url.pathExtension == "part", key.count > 37, key.suffix(37).first == "-",
               UUID(uuidString: String(key.suffix(36))) != nil,
               let trackID = Self.trackID(forStorageKey: String(key.dropLast(37))) {
                return (trackID, url)
            }
            return nil
        }
    }

    fileprivate static func removeCacheFile(_ url: URL) throws {
        guard let attributes = try attributesIfPresent(url) else { return }
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { throw ManagementError.unexpectedFile }
        do { try FileManager.default.removeItem(at: url) }
        catch where Self.isMissing(error) { }
    }

    private func sidecarURL(_ key: String, tier: Tier = .cache) -> URL {
        directory(for: tier).appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func mediaURL(_ key: String, fileExtension: String, tier: Tier = .cache) -> URL {
        directory(for: tier).appendingPathComponent("\(key).\(fileExtension)", isDirectory: false)
    }

    /// Listed and constructed URLs can spell one file differently on macOS (/var against /private/var).
    private static func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func partURL(_ trackID: String) -> URL {
        directory.appendingPathComponent("\(Self.storageKey(for: trackID))-\(UUID().uuidString).part", isDirectory: false)
    }

    private func opusStorageIDs(for trackID: String, tier: Tier? = nil) -> [String] {
        let base = Self.storageKey(for: trackID)
        var seen = Set<String>()
        return (tier.map { [$0] } ?? Tier.allCases).flatMap { tier in
            ((try? directoryContents(tier)) ?? []).filter { $0.pathExtension == "json" }.map(Self.storageID)
        }.filter { $0 != base && Self.logicalTrackID(forStorageID: $0) == trackID && seen.insert($0).inserted }.sorted()
    }

    /// `except` is the writer that just published: its own flight must not shield the older files it replaces.
    private func isProtected(_ trackID: String, except token: UUID? = nil) -> Bool {
        isMaintainingStorage || retainedTrackIDs.contains(trackID)
            || flights.values.contains(where: { $0.trackID == trackID && $0.token != token })
            || activeParts.contains(where: { $0.key != token && $0.value.trackID == trackID })
    }

    private func removeStorage(_ key: String, tier: Tier) {
        guard let files = try? tierFiles(tier) else { return }
        for file in files where file.url.pathExtension != "part" && Self.storageID(of: file.url) == key {
            try? Self.removeCacheFile(file.url)
        }
        if !Tier.allCases.contains(where: { FileManager.default.fileExists(atPath: sidecarURL(key, tier: $0).path) }) { rejected.remove(key) }
    }

    private func retireRejectedFiles() {
        let unused = rejected.filter { key in
            guard let id = Self.logicalTrackID(forStorageID: key) else { return false }
            return !isProtected(id)
        }
        for key in unused { for tier in Tier.allCases { removeStorage(key, tier: tier) } }
    }

    private func retireDeferredFiles() {
        for url in retiredReaderURLs {
            guard let id = Self.logicalTrackID(for: url), !isProtected(id) else { continue }
            do {
                try Self.removeCacheFile(url)
                retiredReaderURLs.remove(url)
            } catch { log.error("event=audio_cache_reader_retirement_failed") }
        }
        retireRejectedFiles()
        retirePendingDedupes()
    }

    /// Maintenance passes see the barrier's retained set; ordinary passes see live pins, readers and writers.
    private func retirePendingDedupes() {
        guard !pendingDedupe.isEmpty else { return }
        for trackID in pendingDedupe.sorted() {
            let protected = isMaintainingStorage ? retainedDuringMaintenance.contains(trackID) : isProtected(trackID)
            _ = dedupeDownloaded(trackID, protected: protected, reason: "deferred")
        }
    }

    // MARK: - Download tier

    func promoteToDownloads(_ trackID: String, fence: DownloadPublicationFence) throws -> DownloadTierChange {
        try Task.checkCancellation()
        return try fence.withValid { try promoteToDownloads(trackID) }
    }

    /// OS deliveries stay in durable staging until native validation and the fenced sidecar publication both succeed.
    func publishBackgroundDownload(track: Track, part: AudioDownloader.Part, metadata: Sidecar,
                                   fence: DownloadPublicationFence) async throws {
        let permit = try writePermit()
        guard Self.isProviderTrackID(track.id), try BackgroundDownloadStaging.fileBytes(part.url) == part.bytes,
              metadata.fileExtension == part.fileExtension else { throw PlaybackStreamError.invalidMedia }
        let token = UUID()
        let input = partURL(track.id)
        let output = mediaURL("\(Self.storageKey(for: track.id)).opus-\(token.uuidString)", fileExtension: "m4a")
        _ = try directoryContents()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        activeParts[token] = (track.id, [input, output])
        // Maintenance must retain the local reader's files until native inspection/remux has actually unwound.
        readers[token] = track.id
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
            activeParts.removeValue(forKey: token)
            readers.removeValue(forKey: token)
            retireDeferredFiles()
        }
        let reservation = part.fileExtension == "webm" ? Self.maximumFileBytes * 2 : part.bytes
        try evictToPolicy(retaining: retainedTrackIDs, reservingBytes: reservation, reservingTrackID: track.id,
                          excludingParts: [input, output])
        try FileManager.default.copyItem(at: part.url, to: input)
        var prepared = AudioDownloader.Part(url: input, bytes: part.bytes, fileExtension: part.fileExtension)
        var quality = metadata.quality
        let duration: TimeInterval
        let version: Int?
        if part.fileExtension == "webm" {
            guard metadata.quality?.codec == .opus else { throw PlaybackStreamError.invalidMedia }
            let inspected = try await prepareOpus(input, output)
            guard inspected.sampleRate == 48_000, (1...2).contains(inspected.channels),
                  inspected.decodedBytes > 0, inspected.decodedFrames > 0,
                  let validDuration = PlaybackTiming.validDuration(inspected.duration) else { throw OpusPreparationError.invalidOutput }
            duration = validDuration
            prepared = AudioDownloader.Part(url: output, bytes: try BackgroundDownloadStaging.fileBytes(output), fileExtension: "m4a")
            quality = SourceAudioQuality(codec: .opus, bitRate: metadata.quality?.bitRate,
                                         sampleRate: inspected.sampleRate, channels: inspected.channels)
            version = 1
        } else {
            guard metadata.quality?.codec != .opus else { throw PlaybackStreamError.invalidMedia }
            duration = try await Self.validateBackgroundAudio(input, fileExtension: part.fileExtension)
            version = nil
        }
        try Task.checkCancellation()
        guard !isMaintainingStorage, permit.generation == generation else { throw CancellationError() }
        if let expected = PlaybackTiming.validDuration(metadata.duration), abs(duration - expected) > max(3, expected * 0.02) {
            throw PlaybackStreamError.invalidMedia
        }
        let durable = try FileHandle(forWritingTo: prepared.url)
        defer { try? durable.close() }
        try durable.synchronize()
        try fence.withValid {
            try Task.checkCancellation()
            if downloadedKeeper(for: track.id) != nil { return }
            // Existing readers and cache-maintenance generations use the same tier/publication rules as foreground stores.
            if hasCompleteCopy(of: track.id, allowOpus: true) {
                let result = try promoteToDownloads(track.id)
                if result != .notFound { return }
            }
            try prepareDownloadsDirectory()
            let key = version == 1 ? "\(Self.storageKey(for: track.id)).opus-\(UUID().uuidString)" : Self.storageKey(for: track.id)
            let stream = ResolvedStream(url: prepared.url, duration: duration, loudnessDb: metadata.loudnessDb,
                                        viewCount: metadata.viewCount, quality: quality, playbackSource: metadata.playbackSource)
            _ = try downloader.publish(prepared, trackID: track.id, stream: stream, into: downloadsDirectory,
                                       track: track, storedAt: now(), storageID: key, downloaded: true, opusPreparationVersion: version)
            noteDownloaded(track.id, true)
            _ = dedupeDownloaded(track.id, protected: isProtected(track.id, except: token), reason: "background")
        }
    }

    private static func validateBackgroundAudio(_ url: URL, fileExtension: String) async throws -> TimeInterval {
        let mimeType: String
        switch fileExtension {
        case "wav": mimeType = "audio/wav"
        case "m4a": mimeType = "audio/mp4"
        default: throw PlaybackStreamError.invalidMedia
        }
        // Opaque .part names carry no format hint; use the delivery's checked MIME type to select the native parser.
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mimeType])
        defer { asset.cancelLoading() }
        return try await withTaskCancellationHandler {
            try await validateBackgroundAudio(asset, fileExtension: fileExtension)
        } onCancel: { asset.cancelLoading() }
    }

    private static func validateBackgroundAudio(_ asset: AVURLAsset, fileExtension: String) async throws -> TimeInterval {
        guard try await asset.load(.isPlayable) else { throw PlaybackStreamError.invalidMedia }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        guard audio.count == 1, video.isEmpty,
              let duration = PlaybackTiming.validDuration(try await asset.load(.duration).seconds) else {
            throw PlaybackStreamError.invalidMedia
        }
        let descriptions = try await audio[0].load(.formatDescriptions)
        let allowed: Set<AudioFormatID> = fileExtension == "wav" ? [kAudioFormatLinearPCM]
            : [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2]
        guard !descriptions.isEmpty, descriptions.allSatisfy({ description in
            guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return false }
            return allowed.contains(format.mFormatID) && (1...8).contains(format.mChannelsPerFrame)
                && (8_000...192_000).contains(format.mSampleRate)
        }) else { throw PlaybackStreamError.invalidMedia }
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw PlaybackStreamError.invalidMedia }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              CMSampleBufferGetNumSamples(sample) > 0, CMSampleBufferGetTotalSampleSize(sample) > 0 else {
            throw PlaybackStreamError.invalidMedia
        }
        try Task.checkCancellation()
        return duration
    }

    private struct Variant {
        let key: String
        let tier: Tier
        let entry: CachedAudio
    }

    /// Renames the song's best complete variant out of the purgeable tier and removes its other variants, so a
    /// downloaded song has one home. Variants of a song in use are removed at the next maintenance pass instead.
    func promoteToDownloads(_ trackID: String) throws -> DownloadTierChange {
        guard Self.isValidTrackID(trackID) else { throw PlaybackStreamError.invalidID }
        guard !isMaintainingStorage else { throw ManagementError.clearing }
        let variants = try completeVariants(of: trackID)
        guard let keeper = selectKeeper(among: variants) else { return .notFound }
        var moved: Int64 = 0
        if keeper.tier == .cache {
            try prepareDownloadsDirectory()
            try move(keeper.key, entry: keeper.entry, from: .cache, to: .downloads)
            moved = keeper.entry.bytes
        }
        noteDownloaded(trackID, true)
        removeOtherVariants(of: trackID, keeping: keeper.key, among: variants, protected: isProtected(trackID), reason: "promote")
        if moved > 0 {
            log.info("event=download_promoted bytes=\(moved)")
            return .moved(bytes: moved)
        }
        return .alreadyThere(bytes: keeper.entry.bytes)
    }

    /// Returns the files to the purgeable tier; they stay playable until ordinary eviction removes them.
    func demoteToCache(_ trackID: String) throws -> DownloadTierChange {
        guard Self.isValidTrackID(trackID) else { throw PlaybackStreamError.invalidID }
        guard !isMaintainingStorage else { throw ManagementError.clearing }
        let moved = try moveAllToCache(trackID)
        pendingDedupe.remove(trackID)
        noteDownloaded(trackID, false)
        if moved > 0 {
            log.info("event=download_removed outcome=demoted bytes=\(moved)")
            evictIfNeeded(retaining: [])
            return .moved(bytes: moved)
        }
        let cached = ([Self.storageKey(for: trackID)] + opusStorageIDs(for: trackID, tier: .cache))
            .compactMap { try? verifiedEntry($0, tier: .cache) }.reduce(0) { $0 + $1.bytes }
        return cached > 0 ? .alreadyThere(bytes: cached) : .notFound
    }

    /// Deletes the downloaded bytes, except for a song in use, which is demoted so the player keeps its file.
    func deleteDownload(_ trackID: String) throws -> DownloadDeletion {
        guard Self.isValidTrackID(trackID) else { throw PlaybackStreamError.invalidID }
        guard !isMaintainingStorage else { throw ManagementError.clearing }
        let files = try tierFiles(.downloads).filter { $0.trackID == trackID }
        guard !files.isEmpty else { return .notFound }
        let bytes = downloadedBytes(for: trackID)
        pendingDedupe.remove(trackID)
        if isProtected(trackID) {
            _ = try moveAllToCache(trackID)
            noteDownloaded(trackID, false)
            log.info("event=download_removed outcome=demotedInUse bytes=\(bytes)")
            return .demotedInUse(bytes: bytes)
        }
        for file in files { try Self.removeCacheFile(file.url) }
        rejected.subtract(files.map { Self.storageID(of: $0.url) })
        noteDownloaded(trackID, false)
        log.info("event=download_removed outcome=deleted bytes=\(bytes)")
        return .deleted(bytes: bytes)
    }

    func isDownloaded(_ trackID: String) -> Bool {
        let downloaded = downloadedBytes(for: trackID) > 0
        noteDownloaded(trackID, downloaded)
        return downloaded
    }

    /// Membership as of the last download-tier scan or tier move: no disk read and no actor hop, so the pipeline
    /// can skip admission work early. False before the first inventory read; `isDownloaded(_:)` is the disk answer.
    nonisolated func isDownloaded(trackID: String) -> Bool {
        downloadedIndex.withLock { $0.contains(trackID) }
    }

    func hasCompleteCopy(of trackID: String, allowOpus: Bool = true) -> Bool {
        entry(for: trackID, allowOpus: allowOpus) != nil
    }

    nonisolated private func noteDownloaded(_ trackID: String, _ downloaded: Bool) {
        downloadedIndex.withLock { if downloaded { $0.insert(trackID) } else { $0.remove(trackID) } }
    }

    private func downloadedBytes(for trackID: String) -> Int64 {
        ([Self.storageKey(for: trackID)] + opusStorageIDs(for: trackID, tier: .downloads))
            .compactMap { try? verifiedEntry($0, tier: .downloads) }.reduce(0) { $0 + $1.bytes }
    }

    private func isDownloadedOnDisk(_ trackID: String) -> Bool {
        downloadedBytes(for: trackID) > 0
    }

    /// Every complete variant of the song in both tiers; keys are unique across tiers because a move renames.
    private func completeVariants(of trackID: String) throws -> [Variant] {
        let base = Self.storageKey(for: trackID)
        return try Tier.allCases.flatMap { tier in
            try ([base] + opusStorageIDs(for: trackID, tier: tier)).compactMap { key in
                try verifiedEntry(key, tier: tier).map { Variant(key: key, tier: tier, entry: $0) }
            }
        }
    }

    /// The file a downloaded song keeps: the best playable encoding, the download-tier copy on ties, then the newest.
    private func selectKeeper(among variants: [Variant]) -> Variant? {
        variants.filter { isEligible($0.entry, allowOpus: true) }.sorted(by: Self.prefersToKeep).first
    }

    private static func prefersToKeep(_ left: Variant, _ right: Variant) -> Bool {
        if SourceAudioQuality.prefers(left.entry.quality, over: right.entry.quality) { return true }
        if SourceAudioQuality.prefers(right.entry.quality, over: left.entry.quality) { return false }
        if left.tier != right.tier { return left.tier == .downloads }
        return prefers(left.entry, right.entry)
    }

    /// The best eligible download-tier file, which admission checks compare new encodings against.
    private func downloadedKeeper(for trackID: String) -> Variant? {
        guard let variants = try? completeVariants(of: trackID) else { return nil }
        return selectKeeper(among: variants.filter { $0.tier == .downloads })
    }

    /// A file published for a downloaded song joins that tier when it is the better encoding and is dropped
    /// otherwise; either way the song ends with one file, or a pending removal while it is in use.
    private func adopt(_ published: CachedAudio, key: String, token: UUID) throws -> CachedAudio {
        let variants = try completeVariants(of: published.trackID)
        guard variants.contains(where: { $0.tier == .downloads }), let keeper = selectKeeper(among: variants) else { return published }
        let protected = isProtected(published.trackID, except: token)
        if keeper.key == key {
            try prepareDownloadsDirectory()
            try move(key, entry: published, from: .cache, to: .downloads)
            noteDownloaded(published.trackID, true)
            removeOtherVariants(of: published.trackID, keeping: key, among: variants, protected: protected, reason: "replace")
            log.info("event=download_replaced bytes=\(published.bytes)")
            return CachedAudio(trackID: published.trackID, url: mediaURL(key, fileExtension: published.url.pathExtension, tier: .downloads),
                               duration: published.duration, loudnessDb: published.loudnessDb, viewCount: published.viewCount,
                               bytes: published.bytes, storedAt: published.storedAt, quality: published.quality,
                               opusPreparationVersion: published.opusPreparationVersion, track: published.track, isDownloaded: true,
                               playbackSource: published.playbackSource)
        }
        // Nobody has read the new file yet, so dropping it is safe even while the song itself is in use.
        removeStorage(key, tier: .cache)
        log.debug("event=download_admission outcome=dropped")
        removeOtherVariants(of: published.trackID, keeping: keeper.key, among: variants.filter { $0.key != key },
                            protected: protected, reason: "replace")
        return keeper.entry
    }

    /// One inventory read repairs installs that kept stale variants beside a downloaded song. Songs in use wait for
    /// the next maintenance pass, like a fresh promotion. Returns true when any file changed.
    private func dedupeDownloadsAtLoad(_ entries: [IndexedEntry]) -> Bool {
        guard !hasDedupedDownloadsAtLoad, !isMaintainingStorage else { return false }
        let candidates = Dictionary(grouping: entries, by: \.trackID)
            .filter { $0.value.count > 1 && $0.value.contains(where: \.entry.isDownloaded) }
            .keys.sorted().prefix(Self.maximumLoadDedupes)
        hasDedupedDownloadsAtLoad = candidates.count < Self.maximumLoadDedupes
        var removed = 0
        var bytes: Int64 = 0
        for trackID in candidates {
            let result = dedupeDownloaded(trackID, protected: isProtected(trackID), reason: "load")
            removed += result.removed
            bytes += result.bytes
        }
        log.info("event=cache_dedupe_downloaded removed=\(removed) bytes=\(bytes) songs=\(candidates.count)")
        return !candidates.isEmpty
    }

    /// Re-derives the keeper from disk, moves it into the download tier when needed and removes the rest.
    /// A protected song is left whole so no file changes under a live player; it stays pending instead.
    @discardableResult
    private func dedupeDownloaded(_ trackID: String, protected: Bool, reason: String) -> (removed: Int, bytes: Int64) {
        guard let variants = try? completeVariants(of: trackID), variants.contains(where: { $0.tier == .downloads }),
              let keeper = selectKeeper(among: variants) else {
            pendingDedupe.remove(trackID)
            return (0, 0)
        }
        if protected {
            pendingDedupe.insert(trackID)
            log.debug("event=download_dedupe reason=\(reason, privacy: .public) removed=0 bytes=0 deferred=1")
            return (0, 0)
        }
        if keeper.tier == .cache {
            do {
                try prepareDownloadsDirectory()
                try move(keeper.key, entry: keeper.entry, from: .cache, to: .downloads)
            } catch {
                log.error("event=download_dedupe reason=\(reason, privacy: .public) failed=1")
                return (0, 0)
            }
        }
        return removeOtherVariants(of: trackID, keeping: keeper.key, among: variants, protected: false, reason: reason)
    }

    @discardableResult
    private func removeOtherVariants(of trackID: String, keeping keeper: String, among variants: [Variant],
                                     protected: Bool, reason: String) -> (removed: Int, bytes: Int64) {
        let extras = variants.filter { $0.key != keeper }
        guard !extras.isEmpty else {
            pendingDedupe.remove(trackID)
            return (0, 0)
        }
        if protected {
            pendingDedupe.insert(trackID)
            log.debug("event=download_dedupe reason=\(reason, privacy: .public) removed=0 bytes=0 deferred=1")
            return (0, 0)
        }
        var bytes: Int64 = 0
        for extra in extras {
            removeStorage(extra.key, tier: extra.tier)
            bytes += extra.entry.bytes
        }
        pendingDedupe.remove(trackID)
        log.info("event=download_dedupe reason=\(reason, privacy: .public) removed=\(extras.count) bytes=\(bytes) deferred=0")
        return (extras.count, bytes)
    }

    private func moveAllToCache(_ trackID: String) throws -> Int64 {
        var moved: Int64 = 0
        for key in [Self.storageKey(for: trackID)] + opusStorageIDs(for: trackID, tier: .downloads) {
            guard let entry = try verifiedEntry(key, tier: .downloads) else { continue }
            try move(key, entry: entry, from: .downloads, to: .cache)
            moved += entry.bytes
        }
        return moved
    }

    /// Sidecar first, then media, then the old sidecar: a crash at any point leaves one verifiable pair.
    private func move(_ key: String, entry: CachedAudio, from source: Tier, to target: Tier) throws {
        guard var sidecar = try readSidecar(key, tier: source) else { return }
        sidecar.downloaded = target == .downloads ? true : nil
        if target == .cache { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let media = mediaURL(key, fileExtension: entry.url.pathExtension, tier: target)
        guard !readerURLs.values.contains(media) else { throw ManagementError.unexpectedFile }
        try JSONEncoder().encode(sidecar).write(to: sidecarURL(key, tier: target), options: .atomic)
        try Self.removeCacheFile(media)
        let retainsSource = readerURLs.values.contains(entry.url)
        if retainsSource {
            // A scoped consumer may open the URL again after an await, so a tier change must keep that path alive.
            try FileManager.default.copyItem(at: entry.url, to: media)
            let durable = try FileHandle(forWritingTo: media)
            defer { try? durable.close() }
            try durable.synchronize()
        } else {
            try FileManager.default.moveItem(at: entry.url, to: media)
        }
        retiredReaderURLs.remove(media)
        try Self.removeCacheFile(sidecarURL(key, tier: source))
        if retainsSource { retiredReaderURLs.insert(entry.url) }
    }

    private func prepareDownloadsDirectory() throws {
        guard !downloadsDirectoryPrepared else { return }
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        var url = downloadsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        downloadsDirectoryPrepared = true
    }

    // MARK: - Identifiers

    private static func storageID(of url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    nonisolated static func logicalTrackID(for url: URL) -> String? {
        logicalTrackID(forStorageID: storageID(of: url))
    }

    nonisolated private static func logicalTrackID(forStorageID key: String) -> String? {
        if let id = trackID(forStorageKey: key) { return id }
        guard let range = key.range(of: ".opus-"), UUID(uuidString: String(key[range.upperBound...])) != nil else { return nil }
        return trackID(forStorageKey: String(key[..<range.lowerBound]))
    }

    /// File names replace the provider prefix colon with a tilde, which the ID alphabet never contains.
    nonisolated static func storageKey(for trackID: String) -> String {
        trackID.replacingOccurrences(of: ":", with: "~")
    }

    nonisolated static func trackID(forStorageKey key: String) -> String? {
        guard let separator = key.firstIndex(of: "~") else { return isValidTrackID(key) ? key : nil }
        let candidate = key[..<separator] + ":" + key[key.index(after: separator)...]
        return isValidTrackID(String(candidate)) ? String(candidate) : nil
    }

    /// Bare IDs use the YouTube alphabet; `<source>:<id>` keeps that alphabet after a known `MusicSource` prefix.
    /// Either way every ID maps to a single safe path component.
    nonisolated static func isValidTrackID(_ trackID: String) -> Bool {
        guard !trackID.isEmpty, trackID.utf8.count <= 64 else { return false }
        let prefix = MusicSource.source(of: trackID).idPrefix
        let provider = trackID.utf8.dropFirst(prefix.utf8.count)
        return !provider.isEmpty && provider.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// A bare ID is a recording only at YouTube's fixed 11 characters; prefixed sources define their own lengths.
    nonisolated static func isProviderTrackID(_ trackID: String) -> Bool {
        guard isValidTrackID(trackID) else { return false }
        return MusicSource.source(of: trackID).idPrefix.isEmpty ? trackID.utf8.count == 11 : true
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.networkServiceType = .background
        return URLSession(configuration: configuration)
    }
}

/// Streams one URL into a temporary file and promotes it only when the byte count matches the declared length.
struct AudioDownloader: Sendable {
    struct Part: Sendable {
        let url: URL
        let bytes: Int64
        let fileExtension: String
    }

    static let mediaExtensions = ["m4a", "wav"]
    private static let mimeExtensions: [String: String] = [
        "audio/mp4": "m4a", "audio/m4a": "m4a", "audio/x-m4a": "m4a", "video/mp4": "m4a",
        "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/vnd.wave": "wav",
        "audio/webm": "webm",
    ]
    private static let rangeBytes: Int64 = 1 << 20
    private static let bufferBytes = 256 << 10
    let session: URLSession

    func download(trackID: String, from remote: URL, stream: ResolvedStream, into directory: URL, limit: Int64,
                   temporary: URL) async throws -> CachedAudio {
        let part = try await receive(trackID: trackID, from: remote, into: directory, limit: limit, temporary: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try publish(part, trackID: trackID, stream: stream, into: directory)
    }

    func publish(_ part: Part, trackID: String, stream: ResolvedStream, into directory: URL,
                 track: Track? = nil, storedAt: Date = Date(), storageID: String? = nil,
                 downloaded: Bool = false, opusPreparationVersion: Int? = nil) throws -> CachedAudio {
        guard Self.mediaExtensions.contains(part.fileExtension) else { throw PlaybackStreamError.invalidMedia }
        let fileExtension = part.fileExtension
        let key = storageID ?? AudioCache.storageKey(for: trackID)
        let media = directory.appendingPathComponent("\(key).\(fileExtension)", isDirectory: false)
        let sidecarURL = directory.appendingPathComponent("\(key).json", isDirectory: false)
        // Existing paths can still belong to a player, including a rejected but pinned copy.
        for ext in Self.mediaExtensions {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(key).\(ext)").path) {
                throw AudioCache.ManagementError.unexpectedFile
            }
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: part.url, to: media)
        try? FileManager.default.setAttributes([.modificationDate: storedAt], ofItemAtPath: media.path)
        let sidecar = AudioCache.Sidecar(duration: PlaybackTiming.validDuration(stream.duration), loudnessDb: stream.loudnessDb,
                                          viewCount: stream.viewCount, bytes: part.bytes, storedAt: storedAt,
                                          fileExtension: fileExtension, quality: stream.quality, opusPreparationVersion: opusPreparationVersion,
                                          track: CachedAudio.displayMetadata(track, for: trackID), downloaded: downloaded,
                                          playbackSource: stream.playbackSource)
        do { try JSONEncoder().encode(sidecar).write(to: sidecarURL, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: media); throw error }
        return CachedAudio(trackID: trackID, url: media, duration: sidecar.duration, loudnessDb: sidecar.loudnessDb,
                            viewCount: sidecar.viewCount, bytes: part.bytes, storedAt: storedAt, quality: sidecar.quality,
                            opusPreparationVersion: opusPreparationVersion, track: sidecar.track, isDownloaded: downloaded,
                            playbackSource: sidecar.playbackSource)
    }

    func receive(trackID: String, from remote: URL, into directory: URL, limit: Int64, temporary: URL,
                  expectedExtension: String? = nil, reserve: (@Sendable (Int64) async throws -> Void)? = nil,
                  progress: (@Sendable (_ written: Int64, _ expected: Int64) -> Void)? = nil) async throws -> Part {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let maximumBytes = min(limit, AudioCache.maximumFileBytes)
        guard maximumBytes > 0 else { throw PlaybackStreamError.invalidMedia }
        let urlLength = Self.declaredLength(in: remote)
        let usesRanges = urlLength != nil && (try? StreamValidation.validateSourceURL(remote)) != nil
        let rangeLength = usesRanges ? urlLength : nil
        if let rangeLength, rangeLength > maximumBytes { throw PlaybackStreamError.invalidMedia }

        try Data().write(to: temporary, options: .withoutOverwriting)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: temporary) } }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var written: Int64 = 0
        var declared: Int64?
        var fileExtension: String?
        var firstContentType: String?
        var firstETag: String?
        do {
            for _ in 0..<64 {
                try Task.checkCancellation()
                var request = URLRequest(url: remote)
                request.httpShouldHandleCookies = false
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let requestedEnd = rangeLength.map { min(written + Self.rangeBytes, $0) - 1 }
                if let requestedEnd { request.setValue("bytes=\(written)-\(requestedEnd)", forHTTPHeaderField: "Range") }
                let (body, response) = try await session.chunkedBody(for: request)
                defer { body.cancel() }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw PlaybackStreamError.invalidMedia }
                guard http.statusCode == 200 || (http.statusCode == 206 && requestedEnd != nil) else {
                    throw PlaybackStreamError.httpStatus(http.statusCode)
                }
                let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard encoding == nil || encoding == "identity",
                      let ext = Self.mimeExtensions[(http.mimeType ?? "").lowercased()],
                      expectedExtension == nil || ext == expectedExtension else { throw PlaybackStreamError.invalidMedia }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let etag = http.value(forHTTPHeaderField: "ETag")
                if written == 0 {
                    fileExtension = ext
                    firstContentType = contentType
                    firstETag = etag
                } else if contentType != firstContentType || etag != firstETag {
                    throw PlaybackStreamError.invalidMedia
                }

                let length: Int64
                if http.statusCode == 206 {
                    let range = try StreamValidation.contentRange(in: http)
                    guard range.start == written, range.end == requestedEnd, range.total == rangeLength else {
                        throw PlaybackStreamError.invalidMedia
                    }
                    declared = range.total
                    length = range.length
                } else {
                    // A complete response is safe only before any range bytes have been appended.
                    guard written == 0, http.value(forHTTPHeaderField: "Content-Range") == nil,
                          let wholeLength = try StreamValidation.contentLength(in: http) ?? urlLength,
                          wholeLength > 0, wholeLength <= maximumBytes,
                          rangeLength == nil || wholeLength == rangeLength else { throw PlaybackStreamError.invalidMedia }
                    declared = wholeLength
                    length = wholeLength
                }
                if written == 0, let declared { try await reserve?(declared) }
                let received = written
                var chunkProgress: (@Sendable (Int64) -> Void)?
                if let progress, let total = declared {
                    chunkProgress = { progress(received + $0, total) }
                }
                try await Self.append(body, response: http, to: handle, length: length, fileExtension: ext, first: written == 0,
                                      progress: chunkProgress)
                written += length
                if written == declared { break }
            }
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw MusicServiceError.network(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard written == declared, let fileExtension else { throw PlaybackStreamError.invalidMedia }
        try handle.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == written else { throw PlaybackStreamError.invalidMedia }
        try Task.checkCancellation()
        complete = true
        return Part(url: temporary, bytes: written, fileExtension: fileExtension)
    }

    private static func append(_ body: URLSessionChunkedBody, response: HTTPURLResponse, to handle: FileHandle,
                               length: Int64, fileExtension: String, first: Bool,
                               progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var received: Int64 = 0
            var prefix = Data()
            prefix.reserveCapacity(12)
            var buffer = Data()
            buffer.reserveCapacity(Int(min(length, Int64(bufferBytes))))
            for try await chunk in body {
                // Bytes within the declared length are validated and buffered before an overrun is rejected.
                let accepted = Int(min(Int64(chunk.count), length - received))
                var rest = chunk.prefix(accepted)
                received += Int64(accepted)
                if first && prefix.count < 12 && !rest.isEmpty {
                    prefix.append(rest.prefix(12 - prefix.count))
                    if prefix.count == 12 {
                        if fileExtension == "webm" { try StreamValidation.validateWebM(response: response, prefix: prefix) }
                        else if !looksLikeMedia(prefix, fileExtension: fileExtension) { throw PlaybackStreamError.invalidMedia }
                    }
                }
                while !rest.isEmpty {
                    let take = min(rest.count, bufferBytes - buffer.count)
                    buffer.append(rest.prefix(take))
                    rest = rest.dropFirst(take)
                    if buffer.count == bufferBytes {
                        try Task.checkCancellation()
                        try handle.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                        progress?(received - Int64(rest.count))
                    }
                }
                guard accepted == chunk.count else { throw PlaybackStreamError.invalidMedia }
            }
            try Task.checkCancellation()
            guard received == length, !first || prefix.count == 12 else { throw PlaybackStreamError.invalidMedia }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            progress?(received)
        } onCancel: {
            body.cancel()
        }
    }

    /// googlevideo URLs declare the whole resource size as `clen`; it stands in when Content-Length is absent.
    static func declaredLength(in url: URL) -> Int64? {
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "clen" } ?? []
        guard values.count == 1, let text = values[0].value,
              let length = StreamValidation.decimalByteCount(text), length > 0 else { return nil }
        return length
    }

    static func looksLikeMedia(_ prefix: Data, fileExtension: String) -> Bool {
        guard prefix.count >= 12 else { return false }
        switch fileExtension {
        case "m4a": return String(data: prefix[4..<8], encoding: .ascii) == "ftyp"
        case "wav": return String(data: prefix[0..<4], encoding: .ascii) == "RIFF" && String(data: prefix[8..<12], encoding: .ascii) == "WAVE"
        default: return false
        }
    }
}
