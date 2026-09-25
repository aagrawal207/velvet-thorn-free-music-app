import Foundation
import XCTest
@testable import GanaBajana

enum WidgetRouteFixtures {
    static let current = libraryTestTrack("fsiPzT50ZiM", duration: 30)
    static let next = libraryTestTrack("J7p4bzqLvCw", duration: 30)
    static let selected = libraryTestTrack("NJAv_7lHUIU", duration: 30)
    static let newer = libraryTestTrack("xTvyyoF_LZY", duration: 30)

    static var playback: PlaybackSnapshot {
        PlaybackSnapshot(queue: [current, next, current], currentIndex: 2, position: 3.25,
                         shuffleEnabled: true, repeatMode: .all, originalQueue: [current, current, next],
                         originalQueueIndices: [0, 2, 1])
    }

    static func mix(_ kind: GeneratedPlaylistKind = .dailyMix, period: String = "2026-09-23",
                    tracks: [Track] = [selected, next]) -> GeneratedPlaylist {
        GeneratedPlaylist(kind: kind, tracks: tracks, generatedAt: RecommendationFixtures.now,
                          periodKey: period, seedArtists: ["Saved artist"])
    }
}

actor WidgetRouteInventoryResolver: StreamCacheManaging {
    let snapshots = AppModelRequestGate<AudioCacheSnapshot?, AudioCacheSnapshot?>()
    nonisolated let base: YouTubeStreamResolver
    private var isHoldingSnapshots = false
    private var heldSnapshot: Task<AudioCacheSnapshot?, any Error>?

    init(base: YouTubeStreamResolver) { self.base = base }

    func holdSnapshots() { isHoldingSnapshots = true }

    func audioCacheSnapshot() async throws -> AudioCacheSnapshot? {
        guard isHoldingSnapshots else { return try await base.audioCacheSnapshot() }
        // Player deadlines detach their work; overlapping background reads must share the same bounded reply.
        if let heldSnapshot { return try await heldSnapshot.value }
        let work = Task { [base, snapshots] in
            let captured = try await base.audioCacheSnapshot()
            return try await snapshots.receive(captured)
        }
        heldSnapshot = work
        return try await work.value
    }

    func close() async {
        await snapshots.close()
        _ = try? await heldSnapshot?.value
        heldSnapshot = nil
        isHoldingSnapshots = false
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try await base.resolve(track: track, forceRefresh: forceRefresh)
    }
    func prefetch(_ tracks: [Track]) async { await base.prefetch(tracks) }
    func download(_ track: Track) async throws -> ResolvedStream { try await base.download(track) }
    func discardCached(_ track: Track) async { await base.discardCached(track) }
    func discardCached(_ track: Track, url: URL?) async { await base.discardCached(track, url: url) }
    func retainCached(_ trackIDs: Set<String>) async { await base.retainCached(trackIDs) }
    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool { base.isCachedStream(stream) }
    func audioCacheUsage() async throws -> AudioCache.Usage? { try await base.audioCacheUsage() }
    func updateCacheListeningHistory(_ events: [ListeningEvent], now: Date) async {
        await base.updateCacheListeningHistory(events, now: now)
    }
    func removeCachedSong(id: String, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCacheRemoval? {
        try await base.removeCachedSong(id: id, retaining: retaining)
    }
    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await base.clearAudioCache(retaining: retaining)
    }
    func setAudioCacheLimit(_ limit: AudioCacheLimit,
                           retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await base.setAudioCacheLimit(limit, retaining: retaining)
    }
}

@MainActor
final class WidgetRouteTestContext {
    let base: AppModelTestContext
    let library: LibraryStore
    let model: MusicAppModel
    let connectivity: ConnectivityMonitor
    var player: PlayerController { base.player }
    var libraryURL: URL { base.directory.appendingPathComponent(LibraryPersistence.fileName) }
    private let inventory: WidgetRouteInventoryResolver?
    private var routeTasks: [Task<Void, Never>] = []

    init(snapshot: PlaybackSnapshot, resolver: (any StreamResolving)?, connectivity: ConnectivityMonitor,
         completedWelcome: Bool, generatesMixes: Bool, prepare: (AppModelTestContext) throws -> Void) throws {
        self.connectivity = connectivity
        inventory = resolver as? WidgetRouteInventoryResolver
        base = try AppModelTestContext(snapshot: snapshot, resolver: resolver)
        base.model.updatePreferences {
            $0.hasCompletedWelcome = completedWelcome
            $0.saveListeningHistory = true
            $0.autoplay = false
            $0.gaplessPlayback = false
        }
        try prepare(base)
        // The setup model must not checkpoint its old snapshot while a new model installs the reloaded state.
        base.player.onSnapshotChanged = nil
        library = LibraryStore(directory: base.directory)
        model = MusicAppModel(library: library, player: base.player, catalog: base.catalog, charts: base.charts,
            lyrics: base.lyrics, account: base.model.account, appIcons: base.model.appIcons,
            recordingLanguageService: base.model.recordingLanguageService, languageDiscovery: base.model.languageDiscovery,
            connectivity: connectivity, generatesMixes: generatesMixes)
    }

    func suspend(_ route: MusicWidgetRoute, using resolver: WidgetRouteInventoryResolver,
                 file: StaticString = #filePath, line: UInt = #line) async throws
        -> (work: Task<Void, Never>, request: AppModelRequestGate<AudioCacheSnapshot?, AudioCacheSnapshot?>.Request) {
        XCTAssertFalse(model.isRefreshingCachedSongs, "A preexisting model refresh would coalesce the route", file: file, line: line)
        let index = await resolver.snapshots.requests.count
        await resolver.holdSnapshots()
        XCTAssertTrue(model.handleOpenURL(route.url), file: file, line: line)
        let work = try XCTUnwrap(model.widgetOpenTask, "Expected deferred offline widget work", file: file, line: line)
        routeTasks.append(work)
        let request = try await resolver.snapshots.request(at: index)
        try await AppModelFixtures.eventually { model.isRefreshingCachedSongs }
        XCTAssertTrue(model.isRefreshingCachedSongs, file: file, line: line)
        return (work, request)
    }

    func assertPausedPlayback(_ expected: PlaybackSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(player.queue, expected.queue, file: file, line: line)
        XCTAssertEqual(player.currentIndex, expected.currentIndex, file: file, line: line)
        XCTAssertEqual(player.position, expected.position, file: file, line: line)
        XCTAssertEqual(player.shuffleEnabled, expected.shuffleEnabled, file: file, line: line)
        XCTAssertEqual(player.repeatMode, expected.repeatMode, file: file, line: line)
        XCTAssertFalse(player.isPlaying, file: file, line: line)
        XCTAssertFalse(player.isLoading, file: file, line: line)
        XCTAssertNil(player.errorMessage, file: file, line: line)
        XCTAssertEqual(library.playback.queue, expected.queue, file: file, line: line)
        XCTAssertEqual(library.playback.currentIndex, expected.currentIndex, file: file, line: line)
        XCTAssertEqual(library.playback.position, expected.position, file: file, line: line)
        XCTAssertEqual(library.playback.shuffleEnabled, expected.shuffleEnabled, file: file, line: line)
        XCTAssertEqual(library.playback.repeatMode, expected.repeatMode, file: file, line: line)
        XCTAssertEqual(library.playback.originalQueue, expected.originalQueue, file: file, line: line)
        XCTAssertEqual(library.playback.originalQueueIndices, expected.originalQueueIndices, file: file, line: line)
    }

    func assertNoCatalogRequests(file: StaticString = #filePath, line: UInt = #line) async {
        let searches = await base.catalog.searches.requests
        let discoveries = await base.catalog.discoveries.requests
        let radios = await base.catalog.radios.requests
        let autoplay = await base.catalog.autoplayRadios.requests
        let artists = await base.catalog.artists.requests
        let charts = await base.charts.charts.requests
        let lyrics = await base.lyrics.requests
        XCTAssertTrue(searches.isEmpty, file: file, line: line)
        XCTAssertTrue(discoveries.isEmpty, file: file, line: line)
        XCTAssertTrue(radios.isEmpty, file: file, line: line)
        XCTAssertTrue(autoplay.isEmpty, file: file, line: line)
        XCTAssertTrue(artists.isEmpty, file: file, line: line)
        XCTAssertTrue(charts.isEmpty, file: file, line: line)
        XCTAssertTrue(lyrics.isEmpty, file: file, line: line)
    }

    func close() async throws {
        if let work = model.widgetOpenTask { routeTasks.append(work) }
        model.cancelPendingWidgetOpen()
        model.cancelPendingRadio()
        player.pause()
        await inventory?.close()
        for work in routeTasks { await work.value }
        model.deactivateDeviceServices()
        connectivity.stop()
        try await base.close()
    }
}

@MainActor
extension XCTestCase {
    func makeWidgetRouteContext(snapshot: PlaybackSnapshot = PlaybackSnapshot(), resolver: (any StreamResolving)? = nil,
                                connectivity: ConnectivityMonitor? = nil, completedWelcome: Bool = true,
                                generatesMixes: Bool = false,
                                prepare: (AppModelTestContext) throws -> Void = { _ in }) throws -> WidgetRouteTestContext {
        let context = try WidgetRouteTestContext(snapshot: snapshot, resolver: resolver,
            connectivity: connectivity ?? ConnectivityMonitor(initialStatus: .online, monitorsSystem: false),
            completedWelcome: completedWelcome, generatesMixes: generatesMixes, prepare: prepare)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }

    func makeWidgetAudioFile() throws -> URL {
        let url = try PlaybackTestSupport.audioFile(seconds: 30)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    func makeWidgetOfflineFixture(cached tracks: [Track], snapshot: PlaybackSnapshot = WidgetRouteFixtures.playback,
                                  prepare: (AppModelTestContext) throws -> Void = { _ in }) throws
        -> (context: WidgetRouteTestContext, cache: CacheManagementFixture,
            inventory: WidgetRouteInventoryResolver, calls: CatalogTestRecorder<String>) {
        let cache = try CacheManagementFixture(handler: { _ in throw URLError(.notConnectedToInternet) })
        addTeardownBlock { @MainActor in try await cache.close() }
        for track in tracks { try cache.seed(track.id, seconds: 30) }
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let base = YouTubeStreamResolver(
            extract: { _, _ in calls.record("extract"); throw URLError(.notConnectedToInternet) },
            validate: { _ in calls.record("validate"); throw URLError(.notConnectedToInternet) },
            fastExtract: { _ in calls.record("fast"); throw URLError(.notConnectedToInternet) },
            audioCache: cache.cache, isOffline: { connectivity.isOffline })
        let inventory = WidgetRouteInventoryResolver(base: base)
        let context = try makeWidgetRouteContext(snapshot: snapshot, resolver: inventory,
                                                 connectivity: connectivity, prepare: prepare)
        return (context, cache, inventory, calls)
    }
}
