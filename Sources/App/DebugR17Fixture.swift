#if DEBUG
import Foundation
import OSLog

enum DebugR17Fixture {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--seed-ui")
            && arguments.contains("--r17-fixture")
    }

    static let artist = ArtistCredit(name: "Breezy Fixture Ensemble")
    static let tracks = ["Paper Lantern", "Little Blue Window", "Quiet Courtyard"].enumerated().map {
        Track(id: "R17song000\($0.offset + 1)", title: $0.element, credits: [artist],
              albumTitle: "Invented Mornings", duration: 360, isAudioRecording: true)
    }
    static let expiredTrack = Track(id: "R17old00001", title: "Expired Fixture Recording",
                                   credits: [artist], duration: 360, isAudioRecording: true)
    static let attribution = "Original test verse written for Breezy fixtures; not taken from a released song."
    static let gurmukhi = ["ਕਾਗਜ਼ ਦੀ ਕਿਸ਼ਤੀ ਹੌਲੀ ਤੁਰੇ", "ਨੀਲੀ ਖਿੜਕੀ ਹੱਸਦੀ ਰਹੇ", "ਛੋਟਾ ਦੀਵਾ ਘਰ ਨੂੰ ਤੱਕੇ"]
    static let latin = ["Kaagaz di kishti hauli ture", "Neeli khirki hassdi rahe", "Chhota deeva ghar nu takke"]

    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    static func recurringEvents(now: Date) -> [ListeningEvent] {
        let calendar = calendar
        let days = (1...10).compactMap { offset -> Date? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now),
                  !calendar.isDateInWeekend(day) else { return nil }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
        }.prefix(3).sorted()
        return zip(tracks, days).enumerated().map { index, pair in
            ListeningEvent(id: UUID(uuidString: String(format: "17000000-0000-0000-0000-%012d", index + 1))!,
                           track: pair.0, startedAt: pair.1, listenedSeconds: 360)
        }
    }

    static func documents(for track: Track) -> [LyricsDocument] {
        [gurmukhi, latin].enumerated().map { variant, text in
            LyricsDocument(trackID: track.id, kind: .synced,
                lines: text.enumerated().map { LyricLine(id: $0.offset, time: Double($0.offset * 120), text: $0.element) },
                source: "Breezy Original Fixture", sourceID: 17_000 + variant,
                matchedTitle: track.title, matchedArtist: track.artistName,
                attributionText: attribution, providerTrackID: track.id)
        }
    }

    @MainActor
    static func makeModel(directory: URL, initializingStore: Bool) -> MusicAppModel {
        let now = Date()
        let library = LibraryStore(directory: directory)
        let events = recurringEvents(now: now)
        if initializingStore {
            var preferences = library.preferences
            preferences.hasCompletedWelcome = true
            preferences.useEncryptedDNS = false
            preferences.allowRemoteFallback = false
            preferences.autoplay = false
            preferences.appearance = ProcessInfo.processInfo.arguments.contains("--light") ? .light : .dark
            library.preferences = preferences
            _ = library.addFavorites(tracks)
            // Real session receipts survive retention; expired recording metadata must not enter charts or moments.
            for index in 0..<40 {
                _ = library.recordListening(track: expiredTrack,
                    sessionID: UUID(uuidString: String(format: "17000000-0000-0000-0001-%012d", index + 1))!,
                    startedAt: now.addingTimeInterval(-500 * 86_400 + Double(index * 600)), seconds: 360)
            }
            for event in events {
                _ = library.recordListening(track: event.track, sessionID: event.id,
                                            startedAt: event.startedAt, seconds: event.listenedSeconds)
            }
            library.updatePlayback(PlaybackSnapshot(queue: tracks, position: 32))
        }
        let floor = (events.first?.startedAt ?? now).addingTimeInterval(-1)
        let momentStore = MomentMixStore(persistence: MomentMixFilePersistence(
            url: directory.appendingPathComponent("Moments/moments.json")), now: floor)
        if initializingStore {
            // Synchronize the real epoch at the learning floor, before the controller's first current-time projection.
            _ = momentStore.synchronizePrivacy(historyEnabled: true, historyEpoch: library.listeningHistoryEpoch, now: floor)
        }
        let moments = MomentMixController(store: momentStore, now: { now }, calendar: { calendar })
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let resolver = DebugR17AudioResolver(directory: directory)
        let downloads = DownloadCenter(manager: DownloadManager(store: resolver.cache,
            transfer: { try await resolver.download($0) }, connectivity: connectivity,
            queueFile: directory.appendingPathComponent("downloads-queue.json"),
            configuration: DownloadManager.Configuration(allowOpus: false)))
        let provider = DebugR17Provider()
        let account = YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry())
        let model = MusicAppModel(library: library, player: PlayerController(resolver: resolver),
            catalog: provider, charts: provider, lyrics: provider, account: account,
            recordingLanguageService: ArtistSpotlightLanguageService(provider: provider),
            songDetails: DebugTrackDetailsFixture.store(connectivity: connectivity),
            genreEvidence: GenreEvidenceStore(url: nil), connectivity: connectivity, downloads: downloads,
            youTubeImport: DebugYouTubeImportFixtureClient.makeImporter(library: library, account: account,
                directory: directory, fixture: true, seedLedger: false),
            momentMixes: moments, exporter: AudioExporter(directory: directory.appendingPathComponent("Export")),
            generatesMixes: false, asynchronousListeningCheckpoints: true)
        model.lyricLanguageLookup = { _ in "pa-Guru" }
        Task { @MainActor [weak model] in
            do {
                try await resolver.prepare()
                // An early five-second inventory read can time out while AAC is encoded; publish a fresh inventory afterwards.
                await model?.refreshCachedSongs()
                if let model, !Set(model.cachedSongs.filter { $0.isDownloaded && $0.isPlayable }.map(\.id))
                    .isSuperset(of: Set(tracks.map(\.id))) {
                    // The first call may only have joined the timed-out startup read while it drained.
                    await model.refreshCachedSongs()
                }
            } catch {
                let stage = await resolver.preparationStage
                model?.showToast("R17 fixture audio failed during \(stage): \(error.localizedDescription)")
            }
        }
        return model
    }
}

struct DebugR17Provider: MusicCatalogProviding, MusicChartsProviding, LyricsVariantsProviding {
    func lyrics(for track: Track) async throws -> LyricsDocument { DebugR17Fixture.documents(for: track)[0] }
    func lyricVariants(for track: Track) async throws -> [LyricsDocument] { DebugR17Fixture.documents(for: track) }
    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        CatalogPage(tracks: DebugR17Fixture.tracks.filter {
            ($0.title + " " + $0.artistName).localizedCaseInsensitiveContains(query)
        })
    }
    func browse(id: String) async throws -> CatalogPage { CatalogPage(tracks: DebugR17Fixture.tracks) }
    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] { DebugR17Fixture.tracks }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { [] }
    func weeklyChart(language: MusicLanguage) async throws -> ChartSnapshot {
        let now = Date()
        return ChartSnapshot(id: "r17.chart", title: "Fixture Chart", subtitle: "Invented recordings",
            source: "Breezy Original Fixture", language: language, periodStart: now, periodEnd: now,
            fetchedAt: now, entries: [])
    }
}

// Uses the same verified AAC and sidecar publication as DebugCachedAudioFixture, with an independent set of IDs.
actor DebugR17AudioResolver: StreamCacheManaging {
    nonisolated let cache: AudioCache
    private let directory: URL
    private let production: YouTubeStreamResolver
    private var preparation: Task<Void, any Error>?
    private(set) var preparationStage = "not started"
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "R17Fixture")

    init(directory: URL) {
        self.directory = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DebugR17ForbiddenNetwork.self]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let cache = AudioCache(directory: directory.appendingPathComponent("Audio"),
                               downloadsDirectory: directory.appendingPathComponent("Downloads"),
                               session: URLSession(configuration: configuration))
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
            if Set(existing.songs.filter { $0.isPlayable && $0.isDownloaded }.map(\.id))
                .isSuperset(of: Set(DebugR17Fixture.tracks.map(\.id))) {
                try await validateDownloads()
                setPreparationStage("ready")
                return
            }
            let staging = directory.appendingPathComponent("R17Audio-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            setPreparationStage("waveform")
            let waveform = try await DebugFixtureAudio.waveform(in: staging)
            setPreparationStage("AAC encoding")
            let audio = try await AudioExporter.bounded(seconds: 90) {
                try await DebugFixtureAudio.exportAAC(from: waveform, to: staging.appendingPathComponent("source.m4a"))
            }
            setPreparationStage("download publication")
            var downloads = cache.downloadsDirectory
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try downloads.setResourceValues(values)
            let bytes = (try FileManager.default.attributesOfItem(atPath: audio.url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 else { throw PlaybackStreamError.invalidMedia }
            for track in DebugR17Fixture.tracks {
                if let existing = await cache.entry(for: track.id, allowOpus: false) {
                    if !existing.isDownloaded { _ = try await cache.promoteToDownloads(track.id) }
                    continue
                }
                let key = AudioCache.storageKey(for: track.id)
                try FileManager.default.copyItem(at: audio.url, to: downloads.appendingPathComponent("\(key).m4a"))
                let sidecar = AudioCache.Sidecar(duration: audio.duration, bytes: bytes, storedAt: Date(),
                    fileExtension: "m4a", quality: audio.quality, track: track, downloaded: true)
                try JSONEncoder().encode(sidecar).write(to: downloads.appendingPathComponent("\(key).json"), options: .atomic)
            }
            setPreparationStage("download validation")
            try await validateDownloads()
            setPreparationStage("ready")
        }
        preparation = task
        try await task.value
    }

    private func setPreparationStage(_ stage: String) {
        preparationStage = stage
        log.info("event=r17_audio stage=\(stage, privacy: .public)")
    }

    private func validateDownloads() async throws {
        let snapshot = try await cache.snapshot(allowOpus: false)
        for track in DebugR17Fixture.tracks {
            guard let song = snapshot.songs.first(where: { $0.id == track.id }), song.isDownloaded, song.isPlayable,
                  let audio = song.preferredAudio, audio.isDownloaded, audio.bytes > 0,
                  audio.track == track, audio.quality?.codec == .aac,
                  audio.url.deletingLastPathComponent().standardizedFileURL.path == cache.downloadsDirectory.path else {
                throw PlaybackStreamError.invalidMedia
            }
            let inspection = try await NativeAudioExport.inspect(audio.url)
            guard inspection.isAAC, abs(inspection.duration - (track.duration ?? 0)) < 1 else {
                throw PlaybackStreamError.invalidMedia
            }
        }
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try await prepare()
        return try await production.resolve(track: track, forceRefresh: forceRefresh)
    }
    func download(_ track: Track) async throws -> ResolvedStream {
        try await prepare()
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

private final class DebugR17ForbiddenNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() { }
}
#endif
