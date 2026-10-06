#if DEBUG
import Foundation
import Observation
import Synchronization

@MainActor
enum DebugCachedAudioFixture {
    @Observable fileprivate final class Probe {
        var isActive = false
        var isReady = false
        var setupError: String?
        var networkRevision = 0
    }

    private static let probe = Probe()
    nonisolated private static let networkAttempts = Mutex(0)
    private static var resolver: DebugCachedAudioResolver?
    private static var cache: AudioCache?
    private static weak var model: MusicAppModel?

    static var isActive: Bool { probe.isActive }
    static var isReady: Bool { probe.isReady }
    static var setupError: String? { probe.setupError }
    static var networkRequestCount: Int {
        _ = probe.networkRevision
        return networkAttempts.withLock { $0 }
    }

    static func makeResolver(directory: URL, initializingStore: Bool, connectivity: ConnectivityMonitor,
                             arguments: [String]) -> (any StreamResolving)? {
        guard arguments.contains("--uitesting"), arguments.contains("--seed-ui"),
              arguments.contains("--offline-fixture") || arguments.contains("--cache-fixture")
                || arguments.contains("--cached-songs-fixture") || arguments.contains(where: { $0.hasPrefix("--cache-fixture-") }) else {
            return nil
        }
        let configuration = DebugCachedAudioConfiguration(arguments: arguments)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [DebugCacheForbiddenNetworkProtocol.self]
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.urlCache = nil
        let session = URLSession(configuration: sessionConfiguration)
        let cache = configuration.unsupported ? nil : AudioCache(directory: directory.appendingPathComponent("Audio", isDirectory: true),
                                                                 downloadsDirectory: directory.appendingPathComponent("Downloads", isDirectory: true),
                                                                 session: session)
        self.cache = cache
        let production = YouTubeStreamResolver(extract: { _, _ in
            recordForbiddenNetworkRequest()
            throw MusicServiceError.network("Network extraction is forbidden in this UI fixture.")
        }, validate: { _ in
            recordForbiddenNetworkRequest()
            throw MusicServiceError.network("Network validation is forbidden in this UI fixture.")
        }, fastExtract: { _ in
            recordForbiddenNetworkRequest()
            throw MusicServiceError.network("Network extraction is forbidden in this UI fixture.")
        }, audioCache: cache, opusEnabled: false, isOffline: { connectivity.isOffline })
        let fixture = DebugCachedAudioResolver(directory: directory, initializingStore: initializingStore,
                                              configuration: configuration, cache: cache, production: production)
        resolver = fixture
        networkAttempts.withLock { $0 = 0 }
        probe.isActive = true
        probe.isReady = false
        probe.setupError = nil
        probe.networkRevision += 1
        return fixture
    }

    /// Downloads in the fixture reuse its cache and resolver, so a "download" is a local rename or a fixture-file copy.
    static func makeDownloadCenter(directory: URL, connectivity: ConnectivityMonitor) -> DownloadCenter? {
        guard let resolver, let cache else { return nil }
        let manager = DownloadManager(store: cache, transfer: { try await resolver.download($0) }, connectivity: connectivity,
                                      queueFile: directory.appendingPathComponent("downloads-queue.json", isDirectory: false),
                                      configuration: DownloadManager.Configuration(allowOpus: false))
        return DownloadCenter(manager: manager)
    }

    static func prepare() async {
        guard let resolver else { return }
        do {
            try await resolver.prepare()
            probe.isReady = true
            probe.setupError = nil
        } catch {
            probe.setupError = "Cached audio fixture setup failed: \(error.localizedDescription)"
        }
    }

    static func attach(to model: MusicAppModel) {
        guard isActive else { return }
        self.model = model
    }

    /// Fault scenarios belong to the request the cached-songs browser makes, not Home's launch preload.
    /// Blocking that preload would only burn the player's inventory deadline, so it ends as cancelled instead.
    static func requireInventoryPresentation() throws {
        guard model?.isCachedSongsScreenVisible == true else { throw CancellationError() }
    }

    nonisolated static func recordForbiddenNetworkRequest() {
        networkAttempts.withLock { $0 += 1 }
        Task { @MainActor in probe.networkRevision += 1 }
    }
}

private struct DebugCachedAudioConfiguration: Sendable {
    let seedRadio: Bool
    let populated: Bool
    let unsupported: Bool
    let failFirstRead: Bool
    let failFirstRemoval: Bool
    let retainOnRemove: Bool
    let slowSnapshot: Bool
    /// Tum Hi Ho starts downloaded with a stale cache variant beside it, the shape older installs may hold.
    let downloadedDuplicate: Bool
    /// The restored player may pin Tum Hi Ho before the first inventory read, which defers its dedupe.
    let inUse: Bool

    init(arguments: [String]) {
        seedRadio = arguments.contains("--seed-radio-fixture")
        unsupported = arguments.contains("--cache-fixture-unsupported")
        populated = !unsupported && !arguments.contains("--cache-fixture-empty")
            && (arguments.contains("--cache-fixture") || arguments.contains("--cached-songs-fixture")
                || arguments.contains(where: { $0.hasPrefix("--cache-fixture-") }))
        failFirstRead = arguments.contains("--cache-fixture-read-error")
        failFirstRemoval = arguments.contains("--cache-fixture-remove-error")
        retainOnRemove = arguments.contains("--cache-fixture-retain-on-remove")
        slowSnapshot = arguments.contains("--cache-fixture-slow")
        downloadedDuplicate = arguments.contains("--cache-fixture-downloaded")
        inUse = arguments.contains("--cache-fixture-in-use")
    }
}

private actor DebugCachedAudioResolver: StreamCacheManaging {
    private let directory: URL
    private let initializingStore: Bool
    private let configuration: DebugCachedAudioConfiguration
    private let cache: AudioCache?
    private let production: YouTubeStreamResolver
    private var setupTask: Task<Void, any Error>?
    private var setupResult: Result<Void, any Error>?
    private var setupWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var readFailed = false
    private var removalFailed = false
    private var retainedByFixture: Set<String> = []
    private var inventoryScenarioStarted = false

    init(directory: URL, initializingStore: Bool, configuration: DebugCachedAudioConfiguration,
         cache: AudioCache?, production: YouTubeStreamResolver) {
        self.directory = directory
        self.initializingStore = initializingStore
        self.configuration = configuration
        self.cache = cache
        self.production = production
    }

    func prepare() async throws {
        if let setupResult { return try setupResult.get() }
        if let setupTask { return try await setupTask.value }
        let work = Task { try await prepareFiles() }
        setupTask = work
        let result: Result<Void, any Error>
        do { try await work.value; result = .success(()) }
        catch { result = .failure(error) }
        setupResult = result
        let waiting = Array(setupWaiters.values)
        setupWaiters.removeAll()
        waiting.forEach { $0.resume(with: result) }
        try result.get()
    }

    private func ready() async throws {
        try Task.checkCancellation()
        if let setupResult { return try setupResult.get() }
        if let setupTask { try await setupTask.value; try Task.checkCancellation(); return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                setupWaiters[id] = continuation
            }
        } onCancel: { Task { await self.cancelSetupWaiter(id) } }
        try Task.checkCancellation()
    }

    private func cancelSetupWaiter(_ id: UUID) {
        setupWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func prepareFiles() async throws {
        guard let cache else { return }
        if initializingStore {
            guard !FileManager.default.fileExists(atPath: cache.directory.path) else {
                throw AudioCache.ManagementError.unexpectedFile
            }
            let staging = directory.appendingPathComponent("CacheFixture-\(UUID().uuidString)", isDirectory: true)
            let stagedCache = staging.appendingPathComponent("Audio", isDirectory: true)
            let stagedDownloads = staging.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: stagedCache, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            if configuration.populated {
                let waveform = try await DebugMusicFixtures.fileURL(in: staging)
                let aac = try await DebugFixtureAudio.exportAAC(from: waveform, to: staging.appendingPathComponent("source.m4a"))
                let opus = try DebugFixtureAudio.incompatibleOpus(to: staging.appendingPathComponent("opus.m4a"))
                let tracks = DebugMusicFixtures.tracks
                for id in ["fsiPzT50ZiM", "NJAv_7lHUIU", "FOA9iyxsW_A", "CacheOnly01"] {
                    let metadata = id == "FOA9iyxsW_A" || id == "CacheOnly01" ? nil : tracks.first { $0.id == id }
                    if id == "fsiPzT50ZiM", configuration.downloadedDuplicate {
                        try FileManager.default.createDirectory(at: stagedDownloads, withIntermediateDirectories: true)
                        try publish(aac, storageID: id, track: metadata, downloaded: true, into: stagedDownloads)
                        try publish(opus, storageID: "\(id).opus-\(UUID().uuidString)", track: metadata, into: stagedCache)
                        continue
                    }
                    try publish(aac, storageID: id, track: metadata, metadataFree: id == "CacheOnly01", into: stagedCache)
                }
                try publish(opus, storageID: "NJAv_7lHUIU.opus-\(UUID().uuidString)",
                            track: tracks.first { $0.id == "NJAv_7lHUIU" }, into: stagedCache)
                if configuration.seedRadio {
                    for track in Array(tracks.suffix(2)) + DebugSeedRadioCatalog.extraTracks {
                        try publish(aac, storageID: track.id, track: track, into: stagedCache)
                    }
                } else {
                    try publish(opus, storageID: "xTvyyoF_LZY", track: tracks.first { $0.id == "xTvyyoF_LZY" }, into: stagedCache)
                }
                try Data([0, 1, 2, 3]).write(to: stagedCache.appendingPathComponent("J7p4bzqLvCw-\(UUID().uuidString).part"))
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: stagedCache, to: cache.directory)
            if FileManager.default.fileExists(atPath: stagedDownloads.path) {
                try FileManager.default.moveItem(at: stagedDownloads, to: cache.downloadsDirectory)
            }
        }
        // Disk verification bypasses fault injection; only a UI inventory request consumes the first-read failure.
        let snapshot = try await cache.snapshot(allowOpus: false)
        if initializingStore, configuration.populated {
            var expected: Set<String> = ["fsiPzT50ZiM", "NJAv_7lHUIU", "FOA9iyxsW_A", "CacheOnly01", "xTvyyoF_LZY"]
            if configuration.seedRadio { expected.formUnion(["J7p4bzqLvCw"] + DebugSeedRadioCatalog.extraTracks.map(\.id)) }
            guard Set(snapshot.songs.map(\.id)) == expected,
                   snapshot.songs.filter(\.isPlayable).count == (configuration.seedRadio ? expected.count : 4),
                  snapshot.songs.first(where: { $0.id == "NJAv_7lHUIU" })?.variantCount == 2 else {
                throw PlaybackStreamError.invalidMedia
            }
            if configuration.downloadedDuplicate {
                // The first inventory read gives the downloaded song one home unless the restored player holds it.
                let song = snapshot.songs.first { $0.id == "fsiPzT50ZiM" }
                let cacheFiles = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).filter { $0.hasPrefix("fsiPzT50ZiM") }
                guard song?.isDownloaded == true, song?.isPlayable == true,
                      configuration.inUse || (song?.variantCount == 1 && cacheFiles.isEmpty) else {
                    throw PlaybackStreamError.invalidMedia
                }
            }
        }
    }

    private func publish(_ stream: ResolvedStream, storageID: String, track: Track?, metadataFree: Bool = false,
                         downloaded: Bool = false, into directory: URL) throws {
        let destination = directory.appendingPathComponent("\(storageID).m4a")
        try FileManager.default.copyItem(at: stream.url, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes > 0 else {
            throw PlaybackStreamError.invalidMedia
        }
        let sidecar = AudioCache.Sidecar(duration: metadataFree ? nil : stream.duration, bytes: bytes, storedAt: Date(),
                                         fileExtension: "m4a", quality: metadataFree ? nil : stream.quality,
                                         opusPreparationVersion: stream.quality?.codec == .opus ? 0 : nil, track: track,
                                         downloaded: downloaded)
        try JSONEncoder().encode(sidecar).write(to: directory.appendingPathComponent("\(storageID).json"), options: .atomic)
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try await ready()
        return try await production.resolve(track: track, forceRefresh: forceRefresh)
    }

    /// An uncached fixture song is published from the local fixture file first, so no forbidden network request happens.
    func download(_ track: Track) async throws -> ResolvedStream {
        try await ready()
        if ProcessInfo.processInfo.arguments.contains("--cache-fixture-slow-download") { try await Task.sleep(for: .seconds(3)) }
        if configuration.populated, let cache, await cache.entry(for: track.id, allowOpus: false) == nil,
           DebugMusicFixtures.tracks.contains(where: { $0.id == track.id }) {
            try await publishFixtureAudio(for: track, into: cache)
        }
        return try await production.download(track)
    }

    private func publishFixtureAudio(for track: Track, into cache: AudioCache) async throws {
        let staging = directory.appendingPathComponent("DownloadFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let waveform = try await DebugMusicFixtures.fileURL(in: staging)
        let aac = try await DebugFixtureAudio.exportAAC(from: waveform, to: staging.appendingPathComponent("source.m4a"))
        let key = AudioCache.storageKey(for: track.id)
        for ext in AudioDownloader.mediaExtensions {
            try? FileManager.default.removeItem(at: cache.directory.appendingPathComponent("\(key).\(ext)"))
        }
        try? FileManager.default.removeItem(at: cache.directory.appendingPathComponent("\(key).json"))
        try publish(aac, storageID: key, track: track, into: cache.directory)
    }

    func prefetch(_ tracks: [Track]) async {
        do { try await ready(); await production.prefetch(tracks) } catch { }
    }

    func discardCached(_ track: Track) async { await production.discardCached(track) }
    func discardCached(_ track: Track, url: URL?) async { await production.discardCached(track, url: url) }

    func retainCached(_ trackIDs: Set<String>) async {
        await production.retainCached(trackIDs.union(retainedByFixture))
    }

    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool { production.isCachedStream(stream) }

    func audioCacheUsage() async throws -> AudioCache.Usage? {
        try await ready()
        return try await production.audioCacheUsage()
    }

    func audioCacheSnapshot() async throws -> AudioCacheSnapshot? {
        try await ready()
        if !inventoryScenarioStarted, configuration.failFirstRead || configuration.slowSnapshot {
            try await DebugCachedAudioFixture.requireInventoryPresentation()
            inventoryScenarioStarted = true
        }
        if configuration.failFirstRead, !readFailed {
            readFailed = true
            throw MusicServiceError.unavailable("Synthetic cache inventory read failure. Try again.")
        }
        // Long enough to observe the loading state, short enough to finish inside the 5 s inventory deadline.
        if configuration.slowSnapshot { try await Task.sleep(for: .seconds(3)) }
        try Task.checkCancellation()
        return try await production.audioCacheSnapshot()
    }

    func updateCacheListeningHistory(_ events: [ListeningEvent], now: Date) async {
        do { try await ready(); await production.updateCacheListeningHistory(events, now: now) } catch { }
    }

    func removeCachedSong(id: String, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCacheRemoval? {
        try await ready()
        if configuration.failFirstRemoval, !removalFailed {
            removalFailed = true
            throw MusicServiceError.unavailable("Synthetic cached-song removal failure. Try again.")
        }
        if configuration.retainOnRemove, id == "NJAv_7lHUIU", let cache {
            retainedByFixture.insert(id)
            return try await production.removeCachedSong(id: id) {
                let retained = await retaining()
                await cache.pin(id)
                return retained.union([id])
            }
        }
        return try await production.removeCachedSong(id: id, retaining: retaining)
    }

    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await ready()
        return try await production.clearAudioCache(retaining: retaining)
    }

    func setAudioCacheLimit(_ limit: AudioCacheLimit,
                           retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await ready()
        return try await production.setAudioCacheLimit(limit, retaining: retaining)
    }
}

private final class DebugCacheForbiddenNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        DebugCachedAudioFixture.recordForbiddenNetworkRequest()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() { }
}
#endif
