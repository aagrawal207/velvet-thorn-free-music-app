#if DEBUG
import Foundation
import YouTubeKit

enum DebugR18Fixture {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--seed-ui")
            && arguments.contains("--r18-fixture")
    }

    static var tracks: [Track] {
        [Track(id: "gaana:R18quiet", title: "Paper Radio", credits: [DebugR17Fixture.artist],
               albumTitle: "Invented Signals", duration: 360, artworkURL: DebugArtworkURLProtocol.url("album"), isAudioRecording: true),
         Track(id: "R18song0001", title: "Little Green Receiver", credits: [DebugR17Fixture.artist],
               albumTitle: "Invented Signals", duration: 360, artworkURL: DebugArtworkURLProtocol.url("artist"), isAudioRecording: true)]
    }

    static let stations = [
        LiveRadioStation(id: UUID(uuidString: "18000000-0000-0000-0000-000000000001")!, name: "KBRZ Public Radio",
            streamingURL: URL(string: "https://radio.example.org/public.aac")!, homepageURL: nil, artworkURL: nil,
            countryCode: "US", languages: ["english"], tags: ["npr", "news"], codec: "AAC", isHLS: false),
        LiveRadioStation(id: UUID(uuidString: "18000000-0000-0000-0000-000000000002")!, name: "Breezy Jazz Radio",
            streamingURL: URL(string: "https://radio.example.org/jazz.aac")!, homepageURL: nil, artworkURL: nil,
            countryCode: "GB", languages: ["english"], tags: ["jazz"], codec: "AAC", isHLS: false),
    ]

    static func directory() -> LiveRadioDirectory {
        LiveRadioDirectory(transport: { request, _ in
            guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "Cookie") == nil,
                  request.value(forHTTPHeaderField: "Authorization") == nil, let url = request.url else {
                throw LiveRadioError.invalidResponse
            }
            if url.path == "/json/servers" { return Data(#"[{"name":"de1.api.radio-browser.info"}]"#.utf8) }
            guard url.path == "/json/stations/search" else { throw LiveRadioError.invalidResponse }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ key: String) -> String { query.first { $0.name == key }?.value ?? "" }
            let selected = stations.filter { station in
                (value("name").isEmpty || station.name.localizedCaseInsensitiveContains(value("name")))
                    && (value("countrycode").isEmpty || station.countryCode == value("countrycode"))
                    && (value("language").isEmpty || station.languages.contains(value("language")))
                    && value("tagList").split(separator: ",").allSatisfy { station.tags.contains(String($0)) }
            }
            return try JSONSerialization.data(withJSONObject: selected.map { station -> [String: Any] in
                ["stationuuid": station.id.uuidString, "name": station.name, "url_resolved": station.streamingURL.absoluteString,
                 "countrycode": station.countryCode, "language": station.languages.joined(separator: ","),
                 "tags": station.tags.joined(separator: ","), "codec": station.codec, "hls": 0, "lastcheckok": 1]
            })
        })
    }

    @MainActor
    static func makeModel(directory: URL, initializingStore: Bool,
                          player injectedPlayer: PlayerController? = nil,
                          account injectedAccount: YouTubeAccountStore? = nil,
                          writeClient: DebugR18WriteClient = DebugR18WriteClient(),
                          catalog: (any MusicCatalogProviding)? = nil,
                          startsExtractor: Bool = false) -> MusicAppModel {
        let library = LibraryStore(directory: directory)
        if initializingStore {
            var preferences = library.preferences
            preferences.hasCompletedWelcome = true
            preferences.useEncryptedDNS = false
            preferences.allowRemoteFallback = false
            preferences.autoplay = false
            preferences.normalizeVolume = true
            preferences.appearance = ProcessInfo.processInfo.arguments.contains("--light") ? .light : .dark
            library.preferences = preferences
            _ = library.createPlaylist(name: "Invented Signals", tracks: tracks)
            library.updatePlayback(PlaybackSnapshot(queue: tracks, position: 12))
        }
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let resolver = DebugR18AudioResolver(directory: directory)
        let player = injectedPlayer ?? PlayerController(resolver: resolver, liveRadioResolver: DebugR18RadioResolver(audio: resolver))
        let account = injectedAccount ?? makeAccount()
        let write = YouTubeAccountWriteController(account: account,
            permissions: YouTubeAccountWritePermissionStore(secrets: MemorySecretStore()), client: writeClient,
            isOffline: { connectivity.isOffline })
        let updates = ExtractorUpdateCenter(directory: directory.appendingPathComponent("ExtractorUpdates"))
        if startsExtractor { updates.start() }
        let downloads = DownloadCenter(manager: DownloadManager(store: resolver.cache,
            transfer: { try await resolver.download($0) }, connectivity: connectivity,
            queueFile: directory.appendingPathComponent("download-queue.json"),
            configuration: DownloadManager.Configuration(allowOpus: false)))
        let provider: any MusicCatalogProviding = catalog ?? DebugR18Catalog()
        let model = MusicAppModel(library: library, player: player, catalog: provider, charts: DebugR17Provider(),
            lyrics: DebugR17Provider(), account: account, appIcons: AppIconController(enabled: false),
            recordingLanguageService: ArtistSpotlightLanguageService(provider: DebugR17Provider()),
            youTubeDataAPI: YouTubeDataAPI(apiKey: "r18-synthetic-unused", session: DebugR18ForbiddenNetwork.session(), isOffline: { true }),
            songDetails: DebugTrackDetailsFixture.store(connectivity: connectivity), genreEvidence: GenreEvidenceStore(url: nil),
            connectivity: connectivity, downloads: injectedPlayer == nil ? downloads : .unavailable,
            youTubeImport: DebugYouTubeImportFixtureClient.makeImporter(library: library, account: account,
                directory: directory, fixture: true, seedLedger: false),
            liveRadio: LiveRadioBrowser(directory: self.directory(),
                favorites: LiveRadioFavorites(url: directory.appendingPathComponent("live-radio-favorites.json"))),
            youTubeWrite: write, extractorUpdates: updates,
            exporter: AudioExporter(directory: directory.appendingPathComponent("Exports")), generatesMixes: false,
            asynchronousListeningCheckpoints: true)
        model.lyricLanguageLookup = { _ in "en" }
        return model
    }

    @MainActor
    private static func makeAccount() -> YouTubeAccountStore {
        // Synthetic cookies stay in a private memory registry and can only reach the injected no-network client.
        let session = YouTubeAccountSession(cookies: [
            StoredCookie(name: "SAPISID", value: "r18-not-a-credential", domain: ".youtube.com"),
            StoredCookie(name: "SID", value: "r18-not-a-session", domain: ".youtube.com"),
        ])
        let bytes = try! JSONEncoder().encode(session)
        return YouTubeAccountStore(secrets: MemorySecretStore(initial: [YouTubeAccountStore.secretKey: bytes]),
                                   registry: YouTubeSessionRegistry())
    }

    @MainActor
    static func prepare(_ model: MusicAppModel) async {
        guard isEnabled, let resolver = model.player.resolver as? DebugR18AudioResolver else { return }
        do {
            try await resolver.prepare()
            await model.refreshCachedSongs()
            if ProcessInfo.processInfo.arguments.contains("--r18-import-candidate"), model.extractorUpdates.highestRevision == 0 {
                let url = resolver.root.appendingPathComponent("manual-candidate.json")
                try manualPackage().write(to: url, options: .atomic)
                await model.extractorUpdates.prepareImport(from: url)
            }
        } catch { model.showToast("R18 fixture preparation failed: \(error.localizedDescription)") }
    }

    static func manualPackage(app: ExtractorAppCompatibility = .current, revision: Int64 = 1) throws -> Data {
        let payload = try JSONEncoder().encode(ExtractorUpdatePayload(schemaVersion: 1, extractorABI: 1,
            appBundleID: app.bundleID, minimumAppBuild: app.build, maximumAppBuild: app.build, revision: revision,
            rules: .init(timestampKeys: ["R18_SIGNATURE_EPOCH"], visitorKeys: ["R18_VISITOR_TOKEN"])))
        return try JSONEncoder().encode(ExtractorUpdateEnvelope(formatVersion: 1, payload: payload,
            sha256: ExtractorUpdateValidator.hash(payload), keyID: nil, signature: nil))
    }
}

struct DebugR18Catalog: MusicCatalogProviding {
    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        CatalogPage(tracks: DebugR18Fixture.tracks.filter { ($0.title + " " + $0.artistName).localizedCaseInsensitiveContains(query) })
    }
    func browse(id: String) async throws -> CatalogPage { CatalogPage(tracks: DebugR18Fixture.tracks) }
    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] { [] }
    func radio(seed: Track) async throws -> [Track] { [] }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { [] }
}

actor DebugR18AudioResolver: StreamCacheManaging {
    nonisolated let root: URL
    nonisolated let cache: AudioCache
    private var preparation: Task<Void, Error>?

    init(directory: URL) {
        root = directory
        cache = AudioCache(directory: directory.appendingPathComponent("Audio"),
            downloadsDirectory: directory.appendingPathComponent("Downloads"), session: DebugR18ForbiddenNetwork.session())
    }

    func prepare() async throws {
        if let preparation { return try await preparation.value }
        let cache = cache, root = root
        let task = Task {
            let existing = try await cache.snapshot(allowOpus: false)
            if Set(existing.songs.filter(\.isPlayable).map(\.id)).isSuperset(of: Set(DebugR18Fixture.tracks.map(\.id))) { return }
            let staging = root.appendingPathComponent("AAC-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            let wave = try await DebugFixtureAudio.waveform(in: staging)
            let audio = try await AudioExporter.bounded(seconds: 90) {
                try await DebugFixtureAudio.exportAAC(from: wave, to: staging.appendingPathComponent("source.m4a"))
            }
            try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
            let bytes = AudioExporter.size(of: audio.url)
            guard bytes > 0 else { throw PlaybackStreamError.invalidMedia }
            for (index, track) in DebugR18Fixture.tracks.enumerated() {
                if await cache.entry(for: track.id, allowOpus: false) != nil { continue }
                let key = AudioCache.storageKey(for: track.id)
                try FileManager.default.copyItem(at: audio.url, to: cache.directory.appendingPathComponent(key + ".m4a"))
                let sidecar = AudioCache.Sidecar(duration: audio.duration, loudnessDb: index == 0 ? -3 : -6,
                    bytes: bytes, storedAt: Date(), fileExtension: "m4a", quality: audio.quality, track: track,
                    playbackSource: index == 0 ? .jioSaavn : .youTubeMusic)
                try JSONEncoder().encode(sidecar).write(to: cache.directory.appendingPathComponent(key + ".json"), options: .atomic)
            }
        }
        preparation = task
        try await task.value
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try await prepare()
        guard DebugR18Fixture.tracks.contains(where: { $0.id == track.id }),
              let entry = try await cache.preparedEntry(for: track.id, allowOpus: false) else { throw PlaybackStreamError.invalidMedia }
        return entry.stream
    }
    func download(_ track: Track) async throws -> ResolvedStream { try await resolve(track: track, forceRefresh: false) }
    func discardCached(_ track: Track) async { }
    func retainCached(_ trackIDs: Set<String>) async { await cache.pin(only: trackIDs) }
    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool {
        stream.url.isFileURL && stream.url.deletingLastPathComponent().standardizedFileURL == cache.directory.standardizedFileURL
    }
    func audioCacheSnapshot() async throws -> AudioCacheSnapshot? { try await prepare(); return try await cache.snapshot(allowOpus: false) }
    func audioCacheUsage() async throws -> AudioCache.Usage? { try await audioCacheSnapshot()?.usage }
    func shutdown() async {
        preparation?.cancel()
        _ = try? await preparation?.value
    }
    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        throw MusicServiceError.unavailable("R18 fixture audio is read-only.")
    }
}

struct DebugR18RadioResolver: LiveRadioResolving {
    let audio: DebugR18AudioResolver
    func resolve(_ station: LiveRadioStation) async throws -> LiveRadioConnection {
        guard DebugR18Fixture.stations.contains(station) else { throw LiveRadioError.invalidStation }
        let stream = try await audio.resolve(track: DebugR18Fixture.tracks[0], forceRefresh: false)
        // The live player currently refuses local URLs before AVFoundation; never substitute a public broadcaster.
        return LiveRadioConnection(station: station, streamingURL: stream.url)
    }
}

actor DebugR18WriteClient: YouTubeAccountWriteProviding {
    private(set) var actions: [YouTubeAccountWriteAction] = []
    private(set) var targets: [String] = []
    func ownedPlaylists(access: YouTubeAccountWriteAccess) async throws -> YouTubeAccountWritePlaylistListing {
        try access.check()
        return .init(items: [], isLimited: false)
    }
    func perform(_ action: YouTubeAccountWriteAction, targetID: String, playlistID: String?, access: YouTubeAccountWriteAccess) async throws {
        try access.check()
        guard action == .like, targetID == "R18song0001", playlistID == nil else { throw YouTubeAccountWriteError.invalidTarget }
        actions.append(action)
        targets.append(targetID)
    }
}

final class DebugR18ForbiddenNetwork: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DebugR18ForbiddenNetwork.self]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() { }
}
#endif
