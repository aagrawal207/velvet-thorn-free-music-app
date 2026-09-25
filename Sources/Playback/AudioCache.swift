import AVFoundation
import Foundation
import OSLog

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

    init(trackID: String, url: URL, duration: TimeInterval?, loudnessDb: Double?, viewCount: Int64?,
         bytes: Int64, storedAt: Date, quality: SourceAudioQuality? = nil, opusPreparationVersion: Int? = nil,
         track: Track? = nil) {
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
    }

    var stream: ResolvedStream {
        ResolvedStream(url: url, duration: duration, expiresAt: nil, loudnessDb: loudnessDb, viewCount: viewCount, quality: quality)
    }

    static func displayMetadata(_ track: Track?, for id: String) -> Track? {
        guard let track, track.id == id, (try? LibraryValidation.validateTrack(track)) != nil,
              let data = try? JSONEncoder().encode(track), data.count <= 48 << 10 else { return nil }
        return track
    }
}

/// Whole-file audio cache in the app's purgeable Caches directory. Each immutable encoding has its own JSON sidecar;
/// only size-verified pairs are playable; active preparation bytes are reported separately from the song count.
actor AudioCache {
    typealias OpusPreparation = @Sendable (URL, URL) async throws -> OpusNativeAudio.Inspection
    typealias LocalDurationLoader = @Sendable (URL) async throws -> TimeInterval
    private typealias IndexedEntry = (trackID: String, entry: CachedAudio, accessedAt: Date)
    struct Usage: Equatable, Sendable {
        let bytes: Int64
        let songCount: Int
        let retainedBytes: Int64
        let retainedSongCount: Int
        let capacityBytes: Int64
        let maximumSongs: Int
        let pendingDownloads: Int
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

    struct Sidecar: Codable, Sendable {
        var duration: TimeInterval?
        var loudnessDb: Double?
        var viewCount: Int64?
        var bytes: Int64
        var storedAt: Date
        var fileExtension: String?
        var quality: SourceAudioQuality?
        var opusPreparationVersion: Int?
        var track: Track?

        init(duration: TimeInterval? = nil, loudnessDb: Double? = nil, viewCount: Int64? = nil, bytes: Int64, storedAt: Date,
             fileExtension: String? = nil, quality: SourceAudioQuality? = nil, opusPreparationVersion: Int? = nil,
             track: Track? = nil) {
            self.duration = duration
            self.loudnessDb = loudnessDb
            self.viewCount = viewCount
            self.bytes = bytes
            self.storedAt = storedAt
            self.fileExtension = fileExtension
            self.quality = quality
            self.opusPreparationVersion = opusPreparationVersion
            self.track = track.flatMap { CachedAudio.displayMetadata($0, for: $0.id) }
        }

        private enum CodingKeys: String, CodingKey {
            case duration, loudnessDb, viewCount, bytes, storedAt, fileExtension, quality, opusPreparationVersion, track
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
            opusPreparationVersion = try values.decodeIfPresent(Int.self, forKey: .opusPreparationVersion)
            track = try? values.decodeIfPresent(Track.self, forKey: .track)
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
    /// Larger than any plausible song; bounds a single download regardless of what the server declares.
    static let maximumFileBytes: Int64 = 64 << 20
    static let maximumOpusVariants = 2

    nonisolated let directory: URL
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
    private var retentionPolicy = AudioCacheRetentionPolicy()
    private var generation = UUID()
    private var isMaintainingStorage = false
    private var retainedDuringMaintenance: Set<String> = []
    private(set) var downloadingTrackID: String?
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "AudioCache")

    init(directory: URL? = nil, capacityBytes: Int64 = AudioCacheLimit.defaultLimit.bytes,
         maximumFiles: Int = AudioCacheLimit.defaultLimit.maximumSongs, session: URLSession? = nil,
         opusPreparation: @escaping OpusPreparation = { try await OpusNativeAudio.prepare(input: $0, output: $1) },
         localDurationLoader: LocalDurationLoader? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = (directory ?? Self.defaultDirectory).standardizedFileURL
        self.capacityBytes = max(0, capacityBytes)
        self.maximumFiles = max(1, maximumFiles)
        downloader = AudioDownloader(session: session ?? Self.makeSession())
        prepareOpus = opusPreparation
        loadLocalDuration = localDurationLoader ?? { try await Self.nativeDuration($0) }
        self.now = now
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
            let all = try verifiedEntries()
            let retained = retainedTrackIDs
            let songs = Dictionary(grouping: all, by: \.trackID).map { id, variants in
                let ordered = variants.map(\.entry).sorted(by: Self.prefers)
                let preferred = AudioCache.isProviderTrackID(id)
                    ? ordered.first { isEligible($0, allowOpus: allowOpus) } : nil
                return CachedSong(id: id, track: preferred?.track ?? ordered.compactMap(\.track).first,
                                  preferredAudio: preferred, bytes: ordered.reduce(0) { $0 + $1.bytes },
                                  variantCount: ordered.count, isInUse: retained.contains(id))
            }.sorted { $0.id < $1.id }
            let result = AudioCacheSnapshot(usage: try usage(retaining: retained, entries: all), songs: songs)
            log.debug("event=audio_cache_inventory songs=\(songs.count) playable=\(songs.filter(\.isPlayable).count) metadata_missing=\(songs.filter { $0.track == nil }.count) failed=0")
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
    func entry(for trackID: String, allowOpus: Bool = true) -> CachedAudio? {
        guard Self.isValidTrackID(trackID) else { return nil }
        let keys = [trackID] + opusStorageIDs(for: trackID)
        let available = keys.compactMap { loadStorage($0) }.filter { isEligible($0, allowOpus: allowOpus) }
        guard let entry = available.sorted(by: Self.prefers).first else { return nil }
        if isMaintainingStorage { retainedDuringMaintenance.insert(trackID) }
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: entry.url.path)
        return entry
    }

    /// The lease belongs to the actual native reader, so an outer deadline cannot release its files prematurely.
    func preparedEntry(for trackID: String, allowOpus: Bool = true) async throws -> CachedAudio? {
        for _ in 0...Self.maximumOpusVariants {
            try Task.checkCancellation()
            guard let audio = entry(for: trackID, allowOpus: allowOpus) else { return nil }
            let lease = UUID()
            readers[lease] = trackID
            defer {
                readers.removeValue(forKey: lease)
                retireRejectedFiles()
            }
            guard audio.duration == nil else { return audio }
            do {
                let duration = try await loadLocalDuration(audio.url)
                try Task.checkCancellation()
                guard PlaybackTiming.validDuration(duration) != nil else { throw PlaybackStreamError.invalidMedia }
                log.debug("event=audio_cache_local_inspection rejected=0")
                return CachedAudio(trackID: audio.trackID, url: audio.url, duration: duration, loudnessDb: audio.loudnessDb,
                                   viewCount: audio.viewCount, bytes: audio.bytes, storedAt: audio.storedAt,
                                   quality: audio.quality, opusPreparationVersion: audio.opusPreparationVersion, track: audio.track)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                rejectPlaybackFile(audio.url)
                log.notice("event=audio_cache_local_inspection rejected=1")
            }
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

    private var retainedTrackIDs: Set<String> { pinned.union(readers.values).union(retainedDuringMaintenance) }

    func pin(_ trackID: String) {
        guard Self.isValidTrackID(trackID) else { return }
        pinned.insert(trackID)
        if isMaintainingStorage { retainedDuringMaintenance.insert(trackID) }
    }

    func unpin(_ trackID: String) {
        pinned.remove(trackID)
        retireRejectedFiles()
    }

    /// Replaces the pinned set so the caller does not have to remember what it pinned earlier.
    func pin(only trackIDs: Set<String>) {
        pinned = trackIDs.filter(Self.isValidTrackID)
        if isMaintainingStorage { retainedDuringMaintenance.formUnion(pinned) }
        retireRejectedFiles()
    }

    func remove(trackID: String) {
        guard Self.isValidTrackID(trackID), let files = try? cacheFiles() else { return }
        if isProtected(trackID) {
            for file in files where file.trackID == trackID && file.url.pathExtension == "json" {
                rejected.insert(Self.storageID(of: file.url))
            }
            return
        }
        for file in files where file.trackID == trackID { try? Self.removeCacheFile(file.url) }
    }

    /// Rejected encodings stay on disk while pinned, but cannot win a subsequent resolution.
    func rejectPlaybackFile(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == directory,
              AudioDownloader.mediaExtensions.contains(url.pathExtension),
              let id = Self.logicalTrackID(for: url) else { return }
        let key = Self.storageID(of: url)
        rejected.insert(key)
        if !isProtected(id) { removeStorage(key) }
    }

    func removeAll() async {
        do { _ = try await clearUnused() }
        catch { log.error("event=audio_cache_clear_failed") }
    }

    /// The live snapshot runs after writers stop; reads and pin changes during that wait also retain their files.
    func clearUnused(retaining liveTrackIDs: @Sendable () async -> Set<String> = { [] }) async throws -> Usage {
        try await beginStorageMaintenance()
        defer { endStorageMaintenance() }
        await retainLiveFiles(liveTrackIDs)

        for file in try cacheFiles() where file.url.pathExtension == "part" || !retainedDuringMaintenance.contains(file.trackID) {
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

    /// Downloads `remote` completely, verifies its length against the declared size, and publishes it for `trackID`.
    /// Concurrent requests for one track share a download; different tracks download one at a time.
    func store(trackID: String, from remote: URL, stream: ResolvedStream, permit: WritePermit? = nil,
               track: Track? = nil, speculative: Bool = false) async throws -> CachedAudio {
        try Task.checkCancellation()
        guard !isMaintainingStorage, permit == nil || permit?.generation == generation else { throw CancellationError() }
        guard Self.isValidTrackID(trackID) else { throw PlaybackStreamError.invalidID }
        _ = try directoryContents()
        let startedGeneration = generation
        if let existing = loadStorage(trackID) {
            guard existing.quality?.codec != .opus else { throw OpusPreparationError.invalidOutput }
            return existing
        }
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
        return try downloader.publish(part, trackID: trackID, stream: stream, into: directory,
                                      track: CachedAudio.displayMetadata(track, for: trackID), storedAt: now())
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
            let storageID = "\(trackID).opus-\(UUID().uuidString)"
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
        let versions = opusStorageIDs(for: trackID)
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
                                         limit: Self.maximumFileBytes, temporary: input, expectedExtension: "webm")
        try Task.checkCancellation()
        let inspected = try await prepareOpus(input, output)
        try Task.checkCancellation()
        guard !retainedTrackIDs.contains(trackID) || opusStorageIDs(for: trackID).count < Self.maximumOpusVariants else {
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
                              track: CachedAudio.displayMetadata(track, for: trackID))
        let metadata = try JSONEncoder().encode(sidecar)
        try metadata.write(to: sidecarURL(storageID), options: .atomic)
        if !retainedTrackIDs.contains(trackID) {
            let older = versions.compactMap { loadStorage($0) }
                .sorted(by: Self.prefers)
            for old in older.dropFirst(Self.maximumOpusVariants - 1) {
                try Self.removeCacheFile(old.url)
                try Self.removeCacheFile(sidecarURL(Self.storageID(of: old.url)))
            }
        }
        guard opusStorageIDs(for: trackID).count <= Self.maximumOpusVariants else { throw OpusPreparationError.insufficientSpace }
        published = true
        log.info("event=opus_cache_prepared bytes=\(size)")
        return CachedAudio(trackID: trackID, url: output, duration: duration, loudnessDb: sidecar.loudnessDb,
                            viewCount: sidecar.viewCount, bytes: size, storedAt: sidecar.storedAt,
                            quality: quality, opusPreparationVersion: 1, track: sidecar.track)
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
        if downloadingTrackID == activeParts[token]?.trackID { downloadingTrackID = nil }
        activeParts.removeValue(forKey: token)
        if flights[key]?.token == token { flights.removeValue(forKey: key) }
        if !isMaintainingStorage { evictIfNeeded(retaining: trackID.map { [$0] } ?? []) }
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
        do { try evictToPolicy(retaining: retainedTrackIDs.union(trackIDs)) }
        catch { log.error("event=audio_cache_eviction_failed") }
    }

    private func evictToPolicy(retaining trackIDs: Set<String>, reservingBytes: Int64 = 0,
                               reservingTrackID: String? = nil, excludingParts: Set<URL> = [], speculative: Bool = false) throws {
        let entries = try verifiedEntries()
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
        rejected = rejected.filter { FileManager.default.fileExists(atPath: sidecarURL($0).path) }
    }

    private func entries() -> [IndexedEntry] {
        (try? verifiedEntries()) ?? []
    }

    private func verifiedEntries() throws -> [IndexedEntry] {
        try directoryContents().filter { $0.pathExtension == "json" }.compactMap { sidecar in
            let key = Self.storageID(of: sidecar)
            guard let trackID = Self.logicalTrackID(for: sidecar), let entry = try verifiedEntry(key) else { return nil }
            let accessed = (try? FileManager.default.attributesOfItem(atPath: entry.url.path)[.modificationDate] as? Date) ?? entry.storedAt
            return (trackID, entry, accessed)
        }
    }

    private func loadStorage(_ key: String) -> CachedAudio? {
        guard !rejected.contains(key), let trackID = Self.logicalTrackID(forStorageID: key) else { return nil }
        do {
            _ = try directoryContents()
            if let entry = try verifiedEntry(key) { return entry }
            if !isProtected(trackID) { removeStorage(key) }
        } catch { log.error("event=audio_cache_read_failed") }
        return nil
    }

    private func verifiedEntry(_ key: String) throws -> CachedAudio? {
        guard let trackID = Self.logicalTrackID(forStorageID: key),
              let sidecar = try readSidecar(key), sidecar.bytes > 0, sidecar.bytes <= Self.maximumFileBytes else { return nil }
        let fileExtension = sidecar.fileExtension ?? "m4a"
        guard AudioDownloader.mediaExtensions.contains(fileExtension) else { return nil }
        if key != trackID, fileExtension != "m4a" || sidecar.opusPreparationVersion == nil { return nil }
        let media = mediaURL(key, fileExtension: fileExtension)
        guard let attributes = try Self.attributesIfPresent(media), attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value == sidecar.bytes else { return nil }
        let quality: SourceAudioQuality? = key == trackID ? sidecar.quality
            : (sidecar.quality?.codec == .opus ? sidecar.quality : SourceAudioQuality(codec: .opus))
        return CachedAudio(trackID: trackID, url: media, duration: PlaybackTiming.validDuration(sidecar.duration),
                            loudnessDb: sidecar.loudnessDb, viewCount: sidecar.viewCount, bytes: sidecar.bytes,
                            storedAt: sidecar.storedAt, quality: quality, opusPreparationVersion: sidecar.opusPreparationVersion,
                            track: sidecar.track)
    }

    private func readSidecar(_ trackID: String) throws -> Sidecar? {
        let url = sidecarURL(trackID)
        guard let attributes = try Self.attributesIfPresent(url), attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 64 << 10 else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try? JSONDecoder().decode(Sidecar.self, from: data)
        } catch where Self.isMissing(error) { return nil }
    }

    private func usage(retaining trackIDs: Set<String>, entries: [IndexedEntry]? = nil) throws -> Usage {
        let all = try entries ?? verifiedEntries()
        let retained = all.filter { trackIDs.contains($0.trackID) }
        let temporaryBytes = try preparationBytes(entries: all)
        let pending = Set(flights.values.map(\.token)).union(activeParts.keys).count
        return Usage(bytes: all.reduce(temporaryBytes) { $0 + $1.entry.bytes }, songCount: Set(all.map { $0.trackID }).count,
                      retainedBytes: retained.reduce(0) { $0 + $1.entry.bytes }, retainedSongCount: Set(retained.map { $0.trackID }).count,
                      capacityBytes: capacityBytes, maximumSongs: maximumFiles, pendingDownloads: pending)
    }

    private func preparationBytes(entries all: [IndexedEntry], excluding: Set<URL> = []) throws -> Int64 {
        let completeURLs = Set(all.map { $0.entry.url })
        var temporaryBytes: Int64 = 0
        for url in activeParts.values.flatMap({ $0.urls }) where !completeURLs.contains(url) && !excluding.contains(url) {
            if let attributes = try Self.attributesIfPresent(url), attributes[.type] as? FileAttributeType == .typeRegular {
                temporaryBytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return temporaryBytes
    }

    private func directoryContents() throws -> [URL] {
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
        let items = try directoryContents()
        let mediaIDs = Set(items.filter { AudioDownloader.mediaExtensions.contains($0.pathExtension) }.map(Self.storageID))
        return try items.compactMap { url in
            let key = Self.storageID(of: url)
            if let id = Self.logicalTrackID(for: url) {
                if AudioDownloader.mediaExtensions.contains(url.pathExtension) { return (id, url) }
                if url.pathExtension == "json" {
                    if mediaIDs.contains(key) { return (id, url) }
                    if try readSidecar(key) != nil { return (id, url) }
                }
            }
            if url.pathExtension == "part", key.count > 37, key.suffix(37).first == "-",
               UUID(uuidString: String(key.suffix(36))) != nil {
                let trackID = String(key.dropLast(37))
                if Self.isValidTrackID(trackID) { return (trackID, url) }
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

    private func sidecarURL(_ trackID: String) -> URL { directory.appendingPathComponent("\(trackID).json", isDirectory: false) }

    private func mediaURL(_ trackID: String, fileExtension: String) -> URL {
        directory.appendingPathComponent("\(trackID).\(fileExtension)", isDirectory: false)
    }

    private func partURL(_ trackID: String) -> URL {
        directory.appendingPathComponent("\(trackID)-\(UUID().uuidString).part", isDirectory: false)
    }

    private func opusStorageIDs(for trackID: String) -> [String] {
        ((try? directoryContents()) ?? []).filter { $0.pathExtension == "json" }
            .map(Self.storageID).filter { $0 != trackID && Self.logicalTrackID(forStorageID: $0) == trackID }.sorted()
    }

    private func isProtected(_ trackID: String) -> Bool {
        isMaintainingStorage || retainedTrackIDs.contains(trackID)
            || flights.values.contains(where: { $0.trackID == trackID }) || activeParts.values.contains(where: { $0.trackID == trackID })
    }

    private func removeStorage(_ key: String) {
        guard let files = try? cacheFiles() else { return }
        for file in files where file.url.pathExtension != "part" && Self.storageID(of: file.url) == key {
            try? Self.removeCacheFile(file.url)
        }
        if !FileManager.default.fileExists(atPath: sidecarURL(key).path) { rejected.remove(key) }
    }

    private func retireRejectedFiles() {
        let unused = rejected.filter { key in
            guard let id = Self.logicalTrackID(forStorageID: key) else { return false }
            return !isProtected(id)
        }
        for key in unused { removeStorage(key) }
    }

    private static func storageID(of url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    nonisolated static func logicalTrackID(for url: URL) -> String? {
        logicalTrackID(forStorageID: storageID(of: url))
    }

    private static func logicalTrackID(forStorageID key: String) -> String? {
        if isValidTrackID(key) { return key }
        guard let range = key.range(of: ".opus-"), UUID(uuidString: String(key[range.upperBound...])) != nil else { return nil }
        let id = String(key[..<range.lowerBound])
        return isValidTrackID(id) ? id : nil
    }

    /// Same alphabet as YouTube IDs; it also keeps every file name a single safe path component.
    static func isValidTrackID(_ trackID: String) -> Bool {
        !trackID.isEmpty && trackID.utf8.count <= 64 && trackID.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    nonisolated static func isProviderTrackID(_ trackID: String) -> Bool {
        trackID.utf8.count == 11 && isValidTrackID(trackID)
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
                 track: Track? = nil, storedAt: Date = Date()) throws -> CachedAudio {
        guard Self.mediaExtensions.contains(part.fileExtension) else { throw PlaybackStreamError.invalidMedia }
        let fileExtension = part.fileExtension
        let media = directory.appendingPathComponent("\(trackID).\(fileExtension)", isDirectory: false)
        let sidecarURL = directory.appendingPathComponent("\(trackID).json", isDirectory: false)
        // Existing paths can still belong to a player, including a rejected but pinned copy.
        for ext in Self.mediaExtensions {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(trackID).\(ext)").path) {
                throw AudioCache.ManagementError.unexpectedFile
            }
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: part.url, to: media)
        try? FileManager.default.setAttributes([.modificationDate: storedAt], ofItemAtPath: media.path)
        let sidecar = AudioCache.Sidecar(duration: PlaybackTiming.validDuration(stream.duration), loudnessDb: stream.loudnessDb,
                                          viewCount: stream.viewCount, bytes: part.bytes, storedAt: storedAt,
                                          fileExtension: fileExtension, quality: stream.quality,
                                          track: CachedAudio.displayMetadata(track, for: trackID))
        do { try JSONEncoder().encode(sidecar).write(to: sidecarURL, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: media); throw error }
        return CachedAudio(trackID: trackID, url: media, duration: sidecar.duration, loudnessDb: sidecar.loudnessDb,
                            viewCount: sidecar.viewCount, bytes: part.bytes, storedAt: storedAt, quality: sidecar.quality, track: sidecar.track)
    }

    func receive(trackID: String, from remote: URL, into directory: URL, limit: Int64, temporary: URL,
                  expectedExtension: String? = nil, reserve: (@Sendable (Int64) async throws -> Void)? = nil) async throws -> Part {
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
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
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
                try await Self.append(bytes, response: http, to: handle, length: length, fileExtension: ext, first: written == 0)
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

    private static func append(_ bytes: URLSession.AsyncBytes, response: HTTPURLResponse, to handle: FileHandle,
                               length: Int64, fileExtension: String, first: Bool) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var received: Int64 = 0
            var prefix = Data()
            prefix.reserveCapacity(12)
            var buffer = Data()
            buffer.reserveCapacity(Int(min(length, Int64(bufferBytes))))
            for try await byte in bytes {
                guard received < length else { throw PlaybackStreamError.invalidMedia }
                received += 1
                if first && prefix.count < 12 {
                    prefix.append(byte)
                    if prefix.count == 12 {
                        if fileExtension == "webm" { try StreamValidation.validateWebM(response: response, prefix: prefix) }
                        else if !looksLikeMedia(prefix, fileExtension: fileExtension) { throw PlaybackStreamError.invalidMedia }
                    }
                }
                buffer.append(byte)
                if buffer.count == bufferBytes {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            guard received == length, !first || prefix.count == 12 else { throw PlaybackStreamError.invalidMedia }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        } onCancel: {
            bytes.task.cancel()
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
