#if DEBUG
import Foundation
import OSLog

/// `--uitesting --seed-ui --r19-fixture`: an isolated library for the Super Likes workflows. Six liked songs by
/// distinct artists, one of them already super liked and not downloaded (so Super Liked Only has a one-song backlog),
/// two liked songs and one unliked song in the download tier, one unliked playable song for the tip's first like.
/// Every song has complete local AAC, so playback and queued downloads finish without a network.
enum DebugR19Fixture {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--seed-ui")
            && arguments.contains("--r19-fixture")
    }

    // Bare ids must be exactly 11 characters (`AudioCache.isProviderTrackID`) or the download queue refuses them.
    static let heartless = Track(id: "heartless19", title: "Heartless", credits: [ArtistCredit(name: "Kanye West")],
                                 albumTitle: "808s & Heartbreak", duration: 360, isAudioRecording: true)
    static let sunflower = Track(id: "sunflower19", title: "Sunflower", credits: [ArtistCredit(name: "Post Malone")],
                                 albumTitle: "Hollywood's Bleeding", duration: 360, isAudioRecording: true)
    static let landslide = Track(id: "landslide19", title: "Landslide", credits: [ArtistCredit(name: "Fleetwood Mac")],
                                 albumTitle: "Fleetwood Mac", duration: 360, isAudioRecording: true)
    static let blackbird = Track(id: "blackbird19", title: "Blackbird", credits: [ArtistCredit(name: "The Beatles")],
                                 albumTitle: "The Beatles", duration: 360, isAudioRecording: true)
    static let starlight = Track(id: "starlight19", title: "Starlight", credits: [ArtistCredit(name: "Muse")],
                                 albumTitle: "Black Holes and Revelations", duration: 360, isAudioRecording: true)
    static let fireflies = Track(id: "fireflies19", title: "Fireflies", credits: [ArtistCredit(name: "Owl City")],
                                 albumTitle: "Ocean Eyes", duration: 360, isAudioRecording: true)
    static let paparazzi = Track(id: "paparazzi19", title: "Paparazzi", credits: [ArtistCredit(name: "Lady Gaga")],
                                 albumTitle: "The Fame", duration: 360, isAudioRecording: true)
    static let nightcall = Track(id: "nightcall19", title: "Nightcall", credits: [ArtistCredit(name: "Kavinsky")],
                                 albumTitle: "OutRun", duration: 360, isAudioRecording: true)

    /// Queue order for `--player`: the liked heart song first, the unliked tip song one Next away.
    static let tracks = [heartless, sunflower, landslide, blackbird, starlight, fireflies, paparazzi, nightcall]
    static let likedTracks = [heartless, landslide, blackbird, starlight, fireflies, paparazzi]
    static let superLikedTrack = starlight
    /// Two liked downloads plus one unliked, so the Downloads Liked and Not Liked filters each keep a hit.
    static let downloadedIDs: Set<String> = [landslide.id, blackbird.id, nightcall.id]

    @MainActor
    static func makeModel(directory: URL, initializingStore: Bool) -> MusicAppModel {
        let library = LibraryStore(directory: directory)
        if initializingStore {
            var preferences = library.preferences
            preferences.hasCompletedWelcome = true
            preferences.useEncryptedDNS = false
            preferences.allowRemoteFallback = false
            preferences.autoplay = false
            preferences.autoDownloadScope = .off
            preferences.appearance = ProcessInfo.processInfo.arguments.contains("--light") ? .light : .dark
            library.preferences = preferences
            _ = library.addFavorites(likedTracks)
            library.setSuperLiked(superLikedTrack, true)
            library.updatePlayback(PlaybackSnapshot(queue: tracks, position: 32))
        }
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let resolver = DebugR19AudioResolver(directory: directory)
        let downloads = DownloadCenter(manager: DownloadManager(store: resolver.cache,
            transfer: { try await resolver.download($0) }, connectivity: connectivity,
            queueFile: directory.appendingPathComponent("downloads-queue.json"),
            configuration: DownloadManager.Configuration(allowOpus: false)))
        let account = YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry())
        let model = MusicAppModel(library: library, player: PlayerController(resolver: resolver),
            catalog: DebugR19Catalog(), charts: DebugR17Provider(), lyrics: DebugR17Provider(), account: account,
            appIcons: AppIconController(enabled: false),
            recordingLanguageService: ArtistSpotlightLanguageService(provider: DebugR17Provider()),
            youTubeDataAPI: YouTubeDataAPI(apiKey: "r19-synthetic-unused", session: DebugR18ForbiddenNetwork.session(),
                                           isOffline: { true }),
            songDetails: DebugTrackDetailsFixture.store(connectivity: connectivity),
            genreEvidence: GenreEvidenceStore(url: nil), connectivity: connectivity, downloads: downloads,
            youTubeImport: DebugYouTubeImportFixtureClient.makeImporter(library: library, account: account,
                directory: directory, fixture: true, seedLedger: false),
            exporter: AudioExporter(directory: directory.appendingPathComponent("Exports")),
            generatesMixes: false, asynchronousListeningCheckpoints: true)
        model.lyricLanguageLookup = { _ in "en" }
        // AAC staging can take tens of seconds; starting it here means the first play or download waits less.
        Task { _ = try? await resolver.prepare() }
        return model
    }

    @MainActor
    static func prepare(_ model: MusicAppModel) async {
        guard isEnabled, let resolver = model.player.resolver as? DebugR19AudioResolver else { return }
        if ProcessInfo.processInfo.arguments.contains("--player") {
            // DebugBootstrap's `--player` presentation over this fixture's queue; the heart needs no audio, so the
            // player opens before staging finishes.
            model.player.restore(PlaybackSnapshot(queue: tracks, currentIndex: 0, position: 32))
            model.isPlayerPresented = true
        }
        do {
            try await resolver.prepare()
            await model.refreshCachedSongs()
            if !Set(model.cachedSongs.filter(\.isPlayable).map(\.id)).isSuperset(of: Set(tracks.map(\.id))) {
                // The first call may only have joined a startup read that began before staging finished.
                await model.refreshCachedSongs()
            }
        } catch {
            let stage = await resolver.preparationStage
            model.showToast("R19 fixture audio failed during \(stage): \(error.localizedDescription)")
        }
    }
}

struct DebugR19Catalog: MusicCatalogProviding {
    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        CatalogPage(tracks: DebugR19Fixture.tracks.filter { ($0.title + " " + $0.artistName).localizedCaseInsensitiveContains(query) })
    }
    func browse(id: String) async throws -> CatalogPage { CatalogPage(tracks: DebugR19Fixture.tracks) }
    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] { [] }
    func radio(seed: Track) async throws -> [Track] { [] }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { [] }
}

/// Stages one verified AAC file under every fixture id: the download tier for `downloadedIDs`, the cache tier for the
/// rest. The production resolver in front of the cache plays them; its network closures fail closed.
actor DebugR19AudioResolver: StreamCacheManaging {
    nonisolated let cache: AudioCache
    private let directory: URL
    private let production: YouTubeStreamResolver
    private var preparation: Task<Void, any Error>?
    private(set) var preparationStage = "not started"
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "R19Fixture")

    init(directory: URL) {
        self.directory = directory
        let cache = AudioCache(directory: directory.appendingPathComponent("Audio"),
                               downloadsDirectory: directory.appendingPathComponent("Downloads"),
                               session: DebugR18ForbiddenNetwork.session())
        self.cache = cache
        production = YouTubeStreamResolver(extract: { _, _ in throw URLError(.notConnectedToInternet) },
            validate: { _ in throw URLError(.notConnectedToInternet) },
            fastExtract: { _ in throw URLError(.notConnectedToInternet) }, audioCache: cache, opusEnabled: false)
    }

    func prepare() async throws {
        if let preparation { return try await preparation.value }
        let directory = directory, cache = cache
        let task = Task {
            setPreparationStage("inventory")
            let existing = try await cache.snapshot(allowOpus: false)
            if Set(existing.songs.filter(\.isPlayable).map(\.id)).isSuperset(of: Set(DebugR19Fixture.tracks.map(\.id))) {
                // A relaunched store keeps whatever tier the previous run's downloads moved songs into.
                try await validate(checkingTiers: false)
                setPreparationStage("ready")
                return
            }
            let staging = directory.appendingPathComponent("R19Audio-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            setPreparationStage("waveform")
            let waveform = try await DebugFixtureAudio.waveform(in: staging)
            setPreparationStage("AAC encoding")
            let audio = try await AudioExporter.bounded(seconds: 90) {
                try await DebugFixtureAudio.exportAAC(from: waveform, to: staging.appendingPathComponent("source.m4a"))
            }
            setPreparationStage("publication")
            try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
            var downloads = cache.downloadsDirectory
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try downloads.setResourceValues(values)
            let bytes = AudioExporter.size(of: audio.url)
            guard bytes > 0 else { throw PlaybackStreamError.invalidMedia }
            for track in DebugR19Fixture.tracks {
                if await cache.entry(for: track.id, allowOpus: false) != nil { continue }
                let downloaded = DebugR19Fixture.downloadedIDs.contains(track.id)
                let tier = downloaded ? downloads : cache.directory
                let key = AudioCache.storageKey(for: track.id)
                // Media first, sidecar last and atomically, so an inventory read never lists a half-published song.
                try FileManager.default.copyItem(at: audio.url, to: tier.appendingPathComponent("\(key).m4a"))
                let sidecar = AudioCache.Sidecar(duration: audio.duration, bytes: bytes, storedAt: Date(),
                    fileExtension: "m4a", quality: audio.quality, track: track, downloaded: downloaded)
                try JSONEncoder().encode(sidecar).write(to: tier.appendingPathComponent("\(key).json"), options: .atomic)
            }
            setPreparationStage("validation")
            try await validate(checkingTiers: true)
            setPreparationStage("ready")
        }
        preparation = task
        try await task.value
    }

    private func setPreparationStage(_ stage: String) {
        preparationStage = stage
        log.info("event=r19_audio stage=\(stage, privacy: .public)")
    }

    /// Every fixture song is playable, freshly staged ones in the tier the fixture promised; one file proves the encoding.
    private func validate(checkingTiers: Bool) async throws {
        let snapshot = try await cache.snapshot(allowOpus: false)
        for track in DebugR19Fixture.tracks {
            guard let song = snapshot.songs.first(where: { $0.id == track.id }), song.isPlayable,
                  !checkingTiers || song.isDownloaded == DebugR19Fixture.downloadedIDs.contains(track.id),
                  let audio = song.preferredAudio, audio.bytes > 0, audio.track?.id == track.id,
                  audio.quality?.codec == .aac else {
                throw PlaybackStreamError.invalidMedia
            }
        }
        guard let sample = snapshot.songs.first(where: { $0.id == DebugR19Fixture.heartless.id })?.preferredAudio else {
            throw PlaybackStreamError.invalidMedia
        }
        let inspection = try await NativeAudioExport.inspect(sample.url)
        guard inspection.isAAC, abs(inspection.duration - (DebugR19Fixture.heartless.duration ?? 0)) < 1 else {
            throw PlaybackStreamError.invalidMedia
        }
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try await prepare()
        return try await production.resolve(track: track, forceRefresh: forceRefresh)
    }
    /// Queued downloads of fixture songs are renames of the staged copy; nothing here can reach a network.
    func download(_ track: Track) async throws -> ResolvedStream {
        try await prepare()
        if let entry = try await cache.preparedEntry(for: track.id, allowOpus: false) { return entry.stream }
        return try await production.download(track)
    }
    func discardCached(_ track: Track) async { await production.discardCached(track) }
    func discardCached(_ track: Track, url: URL?) async { await production.discardCached(track, url: url) }
    func retainCached(_ trackIDs: Set<String>) async { await production.retainCached(trackIDs) }
    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool { production.isCachedStream(stream) }
    func audioCacheUsage() async throws -> AudioCache.Usage? {
        try await prepare()
        return try await production.audioCacheUsage()
    }
    func audioCacheSnapshot() async throws -> AudioCacheSnapshot? {
        try await prepare()
        return try await production.audioCacheSnapshot()
    }
    func updateCacheListeningHistory(_ events: [ListeningEvent], now: Date) async {
        await production.updateCacheListeningHistory(events, now: now)
    }
    func clearAudioCache(retaining live: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await prepare()
        return try await production.clearAudioCache(retaining: live)
    }
}
#endif
