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
    private static weak var model: MusicAppModel?
    private static var presentationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

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
                                                                 session: session)
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

    static func waitForInventoryPresentation() async throws {
        // Offline Home preloads inventory; fault scenarios belong to the listener's cache-browsing workflow.
        repeat {
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    presentationWaiters[id] = continuation
                    let presented = withObservationTracking {
                        model?.isSettingsPresented == true || model?.selectedTab == .search
                    } onChange: {
                        Task { @MainActor in presentationWaiters.removeValue(forKey: id)?.resume() }
                    }
                    if presented { presentationWaiters.removeValue(forKey: id)?.resume() }
                }
            } onCancel: {
                Task { @MainActor in presentationWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
            }
        } while model?.isSettingsPresented != true && model?.selectedTab != .search
        try Task.checkCancellation()
    }

    nonisolated static func recordForbiddenNetworkRequest() {
        networkAttempts.withLock { $0 += 1 }
        Task { @MainActor in probe.networkRevision += 1 }
    }
}

private struct DebugCachedAudioConfiguration: Sendable {
    let populated: Bool
    let unsupported: Bool
    let failFirstRead: Bool
    let failFirstRemoval: Bool
    let retainOnRemove: Bool
    let slowSnapshot: Bool

    init(arguments: [String]) {
        unsupported = arguments.contains("--cache-fixture-unsupported")
        populated = !unsupported && !arguments.contains("--cache-fixture-empty")
            && (arguments.contains("--cache-fixture") || arguments.contains("--cached-songs-fixture")
                || arguments.contains(where: { $0.hasPrefix("--cache-fixture-") }))
        failFirstRead = arguments.contains("--cache-fixture-read-error")
        failFirstRemoval = arguments.contains("--cache-fixture-remove-error")
        retainOnRemove = arguments.contains("--cache-fixture-retain-on-remove")
        slowSnapshot = arguments.contains("--cache-fixture-slow")
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
            try FileManager.default.createDirectory(at: stagedCache, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            if configuration.populated {
                let waveform = try await DebugMusicFixtures.fileURL(in: staging)
                let aac = try await DebugFixtureAudio.exportAAC(from: waveform, to: staging.appendingPathComponent("source.m4a"))
                let opus = try DebugFixtureAudio.incompatibleOpus(to: staging.appendingPathComponent("opus.m4a"))
                let tracks = DebugMusicFixtures.tracks
                for id in ["fsiPzT50ZiM", "NJAv_7lHUIU", "FOA9iyxsW_A", "CacheOnly01"] {
                    let metadata = id == "FOA9iyxsW_A" || id == "CacheOnly01" ? nil : tracks.first { $0.id == id }
                    try publish(aac, storageID: id, track: metadata, metadataFree: id == "CacheOnly01", into: stagedCache)
                }
                try publish(opus, storageID: "NJAv_7lHUIU.opus-\(UUID().uuidString)",
                            track: tracks.first { $0.id == "NJAv_7lHUIU" }, into: stagedCache)
                try publish(opus, storageID: "xTvyyoF_LZY", track: tracks.first { $0.id == "xTvyyoF_LZY" }, into: stagedCache)
                try Data([0, 1, 2, 3]).write(to: stagedCache.appendingPathComponent("J7p4bzqLvCw-\(UUID().uuidString).part"))
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: stagedCache, to: cache.directory)
        }
        // Disk verification bypasses fault injection; only a UI inventory request consumes the first-read failure.
        let snapshot = try await cache.snapshot(allowOpus: false)
        if initializingStore, configuration.populated {
            guard Set(snapshot.songs.map(\.id)) == ["fsiPzT50ZiM", "NJAv_7lHUIU", "FOA9iyxsW_A", "CacheOnly01", "xTvyyoF_LZY"],
                  snapshot.songs.filter(\.isPlayable).count == 4,
                  snapshot.songs.first(where: { $0.id == "NJAv_7lHUIU" })?.variantCount == 2 else {
                throw PlaybackStreamError.invalidMedia
            }
        }
    }

    private func publish(_ stream: ResolvedStream, storageID: String, track: Track?, metadataFree: Bool = false,
                         into directory: URL) throws {
        let destination = directory.appendingPathComponent("\(storageID).m4a")
        try FileManager.default.copyItem(at: stream.url, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes > 0 else {
            throw PlaybackStreamError.invalidMedia
        }
        let sidecar = AudioCache.Sidecar(duration: metadataFree ? nil : stream.duration, bytes: bytes, storedAt: Date(),
                                         fileExtension: "m4a", quality: metadataFree ? nil : stream.quality,
                                         opusPreparationVersion: stream.quality?.codec == .opus ? 0 : nil, track: track)
        try JSONEncoder().encode(sidecar).write(to: directory.appendingPathComponent("\(storageID).json"), options: .atomic)
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try await ready()
        return try await production.resolve(track: track, forceRefresh: forceRefresh)
    }

    func download(_ track: Track) async throws -> ResolvedStream {
        try await ready()
        return try await production.download(track)
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
            try await DebugCachedAudioFixture.waitForInventoryPresentation()
            inventoryScenarioStarted = true
        }
        if configuration.failFirstRead, !readFailed {
            readFailed = true
            throw MusicServiceError.unavailable("Synthetic cache inventory read failure. Try again.")
        }
        if configuration.slowSnapshot { try await Task.sleep(for: .seconds(15)) }
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
