import Foundation
import Observation
import OSLog
import SwiftUI
import WidgetKit

enum AppTab: Hashable { case home, search, library, recap }

@MainActor @Observable
final class MusicAppModel {
    // Provider copy can change; these IDs identify the two hitlists rather than the whole editorial category.
    private static let excludedHomeShelfIDs: Set<String> = ["editorial-hindi", "editorial-english"]

    let library: LibraryStore
    let player: PlayerController
    /// Warms the songs a listener is likely to tap next (search results, opened collections); see `docs/FAST_START.md`.
    let playbackWarmer: PlaybackWarmer
    let catalog: any MusicCatalogProviding
    let artistArtwork: ArtistArtworkResolver
    /// Song details for the player's More sheet; fixtures and unit hosts swap in a network-free provider.
    @ObservationIgnored let songDetails: any TrackDetailsProviding
    let cloudSync: ICloudLibrarySync
    let appIcons: AppIconController
    let lyrics: any LyricsProviding
    let lyricsSelection = LyricsLoader()
    let momentMixes: MomentMixController
    @ObservationIgnored var lyricsSelectionTask: Task<Void, Never>?
    @ObservationIgnored var selectedLyricsToken: TVLyricsController.SelectionToken?
    @ObservationIgnored var selectedLyricsTrack: Track?
    @ObservationIgnored var lyricLanguageLookup: (@Sendable (Track) async throws -> String?)?
    @ObservationIgnored lazy var tvLyrics = TVLyricsController(player: player, lyricsOffset: { [weak self] id in
        self?.library.lyricsOffset(for: id) ?? 0
    })
    /// Hidden delights; docs/DELIGHTS.md owns their triggers, flags and metrics.
    @ObservationIgnored lazy var delights = DelightController(model: self)
    let recordingLanguageService: ArtistSpotlightLanguageService
    let languageDiscovery: ListeningLanguageDiscovery
    /// Device-local genre evidence per played recording and the bounded classifier that fills it (WP17).
    let genreEvidence: GenreEvidenceStore
    let genreClassification: GenreEvidenceLoader
    /// Device-local per-song equalizer overrides and saved presets (R14 WP25, docs/PLAYER_MORE.md).
    let equalizerProfiles: EqualizerProfileStore
    let connectivity: ConnectivityMonitor
    /// Optional YouTube sign-in used only for stream lookups.
    let account: YouTubeAccountStore
    let youTubeWrite: YouTubeAccountWriteController
    let liveRadio: LiveRadioBrowser
    let seedRadioHistory: RadioHistoryStore
    /// Device-local skip and completion signals that recommendations read (docs/LISTENING_DISCOVERY.md).
    let listeningSignalStore: ListeningSignalStore
    var listeningSignals: [ListeningSignal] { listeningSignalStore.signals }
    var listeningSignalsRevision: UInt64 { listeningSignalStore.revision }
    private(set) var pendingRadioSeed: RadioSeed?
    private(set) var isStartingSeedRadio = false
    private(set) var seedRadioError: String?
    private var seededSession: SeededRadioSession?
    @ObservationIgnored private var seedRadioStartTask: Task<Void, Never>?
    @ObservationIgnored private var seedRadioStartGeneration = UUID()
    @ObservationIgnored private var pendingRadioTuning = RadioTuning()
    let extractorUpdates: ExtractorUpdateCenter
    @ObservationIgnored private var extractorInvalidationTask: Task<Void, Never>?
    /// Opt-in, read-only copy of the signed-in account's library into the local one (Settings > Account & connection).
    let youTubeImport: YouTubeLibraryImporter
    let tips: TipJarService
    @ObservationIgnored let releases: ReleaseWatcher
    @ObservationIgnored private let chartProvider: any MusicChartsProviding
    @ObservationIgnored private let engine: RecommendationEngine
    @ObservationIgnored private let experienceRadio: ExperienceRadioEngine
    @ObservationIgnored private let seedRadioEngine: SeedRadioEngine
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Discovery")
    @ObservationIgnored private var homeGeneration = UUID()
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var personalizationGeneration = UUID()
    @ObservationIgnored private var completedSearch: SearchIdentity?
    @ObservationIgnored private var loadedLanguageProfileKey: String?
    @ObservationIgnored private var loadedGenreProfileKey: String?
    @ObservationIgnored private var cachedGenreProfile: (key: GenreProfileCacheKey, profile: ListeningGenreProfile)?
    @ObservationIgnored private var cachedLanguageProfile: (key: LanguageProfileCacheKey, profile: ListeningLanguageProfile)?
    @ObservationIgnored private var cachedListeningSummaries: [ListeningWindow: (key: ListeningSummaryCacheKey, summary: ListeningSummary)] = [:]
    @ObservationIgnored private var cachedTasteProfile: (key: TasteProfileCacheKey, profile: TasteProfile)?
    @ObservationIgnored private var cachedPreviousWindowSeconds: [ListeningWindow: (key: ListeningSummaryCacheKey, seconds: TimeInterval)] = [:]
    @ObservationIgnored private var cachedLanguageSummaries: [ListeningWindow: (key: LanguageSummaryCacheKey, summary: ListeningLanguageSummary)] = [:]
    @ObservationIgnored private var cachedGenreSummaries: [ListeningWindow: (key: GenreSummaryCacheKey, summary: ListeningGenreSummary)] = [:]
    @ObservationIgnored private(set) var listeningProjectionBuildCounts: [ListeningProjectionKind: Int] = [:]
    @ObservationIgnored private var loggedGenreProfileKey: String?
    @ObservationIgnored private var loadedDiscoveryFamiliarity: DiscoveryFamiliarity?
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var mixesTask: Task<Void, Never>?
    @ObservationIgnored private var followTasks: Set<String> = []
    @ObservationIgnored private var artistLookupGeneration = UUID()
    @ObservationIgnored private let generatesMixes: Bool
    @ObservationIgnored private var consumedSearchFocusRequest = 0
    @ObservationIgnored private var radioSelectionGeneration = UUID()
    @ObservationIgnored private var radioContinuationGeneration = UUID()
    @ObservationIgnored private var playbackIntentGeneration = UUID()
    @ObservationIgnored private var needsInitialPlaybackRestore = false
    @ObservationIgnored private var radioSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var radioRetryTask: Task<Void, Never>?
    @ObservationIgnored private var radioRequestLanguages: Set<MusicLanguage>?
    @ObservationIgnored private var radioRequestUsesPreferences = true
    @ObservationIgnored private var autoplayContinuationGeneration = UUID()
    @ObservationIgnored private var autoplayRetryTask: Task<Void, Never>?
    @ObservationIgnored private var deviceServicesAreActive = false
    @ObservationIgnored private var executedSearchQuery: String?
    @ObservationIgnored private var cachedSongsTask: Task<Void, Never>?
    @ObservationIgnored private var cachedSongsGeneration = UUID()
    @ObservationIgnored private var lastConnectivityWasOffline = false
    @ObservationIgnored private var widgetPublisher: WidgetSnapshotPublisher?
    @ObservationIgnored private var playbackWidgetPublisher: PlaybackWidgetPublisher?
    @ObservationIgnored var widgetOpenTask: Task<Void, Never>?
    /// Managed downloads: queue state for views and the tier calls; `.unavailable` without a local audio store.
    let downloads: DownloadCenter
    @ObservationIgnored private let exporter: AudioExporter
    @ObservationIgnored private var knownFavoriteIDs: Set<String> = []
    @ObservationIgnored private var knownSuperLikedIDs: Set<String> = []
    private(set) var inventoryDownloadedTrackIDs: Set<String> = []

    var widgetLibraryDestination: LibrarySavedSongsView.Kind?
    /// Library's Cached songs page; the offline banner and the Library card both push through this flag.
    var showsLibraryCachedSongs = false
    /// Appear/disappear count from every `CachedSongsView`; while positive the offline banner drops its action.
    private(set) var visibleCachedSongsScreens = 0
    var isCachedSongsScreenVisible: Bool { visibleCachedSongsScreens > 0 }
    /// Library's On this device page; the offline banner pushes it so every playable local song has one list.
    var showsLibraryOnThisDevice = false
    private(set) var visibleOnThisDeviceScreens = 0
    var isOnThisDeviceScreenVisible: Bool { visibleOnThisDeviceScreens > 0 }
    /// One-shot scroll for the Library root; the view clears it after scrolling so a later visit keeps its position.
    var libraryScrollTarget: LibraryScrollTarget?
    #if DEBUG
    var isWidgetPreviewPresented = false
    #endif

    var selectedTab: AppTab = .home {
        didSet {
            if selectedTab != oldValue { cancelPendingArtistLookup() }
            if selectedTab != .search { dismissSearchKeyboard() }
        }
    }
    var isPlayerPresented = false {
        didSet {
            if isPlayerPresented != oldValue { cancelPendingArtistLookup() }
            if isPlayerPresented { dismissSearchKeyboard() }
        }
    }
    var isSettingsPresented = false {
        didSet {
            if isSettingsPresented != oldValue { cancelPendingArtistLookup() }
            if isSettingsPresented { dismissSearchKeyboard() }
        }
    }
    /// The Devices sheet over the root; Song Options and Settings push the same list instead.
    var isNearbyDevicesPresented = false
    /// Installed once by the app; unit and fixture models without one hide every Devices entry point.
    @ObservationIgnored var nearbyDevices: NearbyDevicesController?
    var toast: String?
    @ObservationIgnored private var pendingReleaseNotification: ReleaseNotificationRoute?
    @ObservationIgnored private var isReleaseNotificationNavigationReady = false
    /// Programmatic pushes per tab (album and artist pages opened from the player); tapped links push on top.
    var navigationPaths: [AppTab: [MusicCollection]] = [:] {
        didSet {
            if navigationPaths[selectedTab, default: []] != oldValue[selectedTab, default: []] { cancelPendingArtistLookup() }
        }
    }
    private(set) var homeSections: [DiscoverySection] = []
    private(set) var charts: [ChartSnapshot] = []
    private(set) var isLoadingHome = false
    private(set) var isGeneratingMixes = false
    private var releaseChecksInFlight = 0
    var isCheckingNewReleases: Bool { releaseChecksInFlight > 0 }
    /// True once listening history is rich enough for personal mixes; Home hides the "play a few songs" hint.
    private(set) var hasListeningProfile = false
    private(set) var homeError: String?
    var searchQuery = "" {
        didSet { if searchQuery != oldValue { cancelPendingArtistLookup() } }
    }
    var searchFilter: SearchFilter = .songs {
        didSet { if searchFilter != oldValue { cancelPendingArtistLookup() } }
    }
    private(set) var searchPage = CatalogPage()
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var hasSearched = false
    private(set) var searchFocusRequest = 0
    private(set) var searchFocusDismissal = 0
    private(set) var searchRootGeneration = UUID()
    private(set) var libraryRootGeneration = UUID()
    private(set) var cachedSongs: [CachedSong] = []
    private(set) var cachedSongsUsage: AudioCache.Usage?
    private(set) var cachedPlayableTrackIDs: Set<String> = []
    /// The Cached songs screen and the temporary-cache totals; downloaded songs are listed under Downloads instead.
    var temporaryCachedSongs: [CachedSong] { cachedSongs.filter { !$0.isDownloaded } }
    private(set) var hasLoadedCachedSongs = false
    private(set) var isRefreshingCachedSongs = false
    private(set) var cachedSongsError: String?
    private(set) var selectedRadioExperience: RadioExperience?
    private(set) var isLoadingRadio = false
    private(set) var radioError: String?
    private(set) var isContinuingRadio = false
    private(set) var radioContinuationError: String?
    private var radioSession: RadioSession?
    /// Ordinary-queue Autoplay continuation for the queue sheet; radio sessions keep the radio continuation state.
    private(set) var isContinuingAutoplay = false
    private(set) var autoplayContinuationError: String?
    /// True while a title-only credit is being matched to an artist page.
    private(set) var isArtistLookupPending = false

    init(library: LibraryStore = LibraryStore(), player: PlayerController? = nil,
         catalog: (any MusicCatalogProviding)? = nil,
         charts: (any MusicChartsProviding)? = nil,
         lyrics: (any LyricsProviding)? = nil,
         releaseNotifier: (any ReleaseNotifying)? = nil,
         account: YouTubeAccountStore? = nil,
          appIcons: AppIconController? = nil,
          artistArtwork: ArtistArtworkResolver? = nil,
           recordingLanguageService: ArtistSpotlightLanguageService? = nil,
           youTubeDataAPI: YouTubeDataAPI? = nil,
          songDetails: (any TrackDetailsProviding)? = nil,
          languageDiscovery: ListeningLanguageDiscovery? = nil,
          genreEvidence: GenreEvidenceStore? = nil,
          genreMetadata: (any GenreMetadataProviding)? = nil,
          connectivity: ConnectivityMonitor? = nil,
          downloads: DownloadCenter? = nil,
           youTubeImport: YouTubeLibraryImporter? = nil,
           momentMixes: MomentMixController? = nil,
           liveRadio: LiveRadioBrowser? = nil,
           seedRadioCatalog: (any MusicCatalogProviding)? = nil,
           youTubeWrite: YouTubeAccountWriteController? = nil,
           extractorUpdates: ExtractorUpdateCenter? = nil,
           exporter: AudioExporter = AudioExporter(),
           generatesMixes: Bool = true, asynchronousListeningCheckpoints: Bool? = nil) {
        let usesAsyncListeningCheckpoints = asynchronousListeningCheckpoints ?? (player == nil)
        #if DEBUG
        let observingPurchases = !ProcessInfo.processInfo.arguments.contains("--uitesting")
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #else
        let observingPurchases = true
        #endif
        let updates = extractorUpdates ?? ExtractorUpdateCenter(directory: observingPurchases
            ? ExtractorUpdateStore.defaultDirectory
            : FileManager.default.temporaryDirectory.appendingPathComponent("ExtractorFixture-\(UUID().uuidString)"))
        self.extractorUpdates = updates
        if observingPurchases { updates.start() }
        self.liveRadio = liveRadio ?? LiveRadioBrowser(directory: LiveRadioDirectory(isEnabled: observingPurchases),
            favorites: LiveRadioFavorites(url: observingPurchases ? LiveRadioFavorites.defaultURL() : nil),
            verifier: observingPurchases ? LiveRadioStreamResolver() : nil)
        self.seedRadioHistory = RadioHistoryStore(url: library.syncDeviceConfigurationURL?
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("radio-history.json"),
            historyEpoch: library.listeningHistoryEpoch, deferLoading: !library.hasLoadedDocument)
        if library.hasLoadedDocument {
            self.seedRadioHistory.synchronize(historyEpoch: library.listeningHistoryEpoch,
                                              enabled: library.preferences.saveListeningHistory)
        }
        // Unit and fixture hosts keep signals in memory only, like genre evidence.
        self.listeningSignalStore = ListeningSignalStore(url: observingPurchases ? library.syncDeviceConfigurationURL?
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(ListeningSignalStore.fileName) : nil,
            historyEpoch: library.listeningHistoryEpoch, deferLoading: !library.hasLoadedDocument)
        if library.hasLoadedDocument {
            self.listeningSignalStore.synchronize(historyEpoch: library.listeningHistoryEpoch,
                                                 enabled: library.preferences.saveListeningHistory)
        }
        self.exporter = exporter
        LyricsDNSConfiguration.configure(enabled: library.preferences.useEncryptedDNS)
        self.generatesMixes = generatesMixes
        let connectivity = connectivity ?? ConnectivityMonitor()
        self.connectivity = connectivity
        self.lastConnectivityWasOffline = connectivity.isOffline
        // One service per provider serves both catalog and playback so details fetched for a row also feed its stream.
        let sources = player == nil || catalog == nil ? ProductionSources() : nil
        var productionResolver: CompositeStreamResolver?
        let player = player ?? {
            let resolver = Self.makeProductionResolver(sources: sources ?? ProductionSources(), isOffline: { connectivity.isOffline })
            productionResolver = resolver
            return PlayerController(resolver: resolver)
        }()
        // Downloads reuse the resolver's own cache; an injected player without a center leaves downloads unavailable.
        self.downloads = downloads ?? productionResolver.flatMap { resolver in
            AudioCache.installed.map { cache in
                DownloadCenter(manager: DownloadManager.background(store: cache,
                    planner: { try await resolver.backgroundDownloadPlan(for: $0) },
                    connectivity: connectivity, allowCellular: library.preferences.downloadsOverCellular))
            }
        } ?? .unavailable
        let catalog = catalog ?? Self.makeProductionCatalog(sources: sources ?? ProductionSources(),
                                                            enabledSources: library.preferences.enabledCatalogSources)
        let dataAPI = youTubeDataAPI ?? YouTubeDataAPI.configured(isOffline: { connectivity.isOffline })
        let prepareTrack: CompositeLyricsProvider.MetadataPreparation?
        let recordingMetadataLookup: ArtistSpotlightLanguageService.MetadataLookup?
        if let dataAPI {
            prepareTrack = { try await dataAPI.prepareForLookup($0) }
            recordingMetadataLookup = { try await dataAPI.recordingLanguage(for: $0) }
        } else {
            prepareTrack = nil
            recordingMetadataLookup = nil
        }
        self.library = library
        self.player = player
        playbackWarmer = PlaybackWarmer(resolver: player.resolver, network: PlaybackWarmer.Network(
            isOffline: { connectivity.isOffline }, isExpensive: { connectivity.isExpensive },
            isConstrained: { connectivity.isConstrained }, allowsExpensive: { library.preferences.downloadsOverCellular }),
            preloader: player.preloader)
        player.preloader.network = PlaybackPreloader.Network(
            isOffline: { connectivity.isOffline }, isConstrained: { connectivity.isConstrained },
            isExpensive: { connectivity.isExpensive }, allowsExpensive: { library.preferences.downloadsOverCellular })
        self.catalog = catalog
        self.artistArtwork = artistArtwork ?? ArtistArtworkResolver(catalog: catalog)
        self.songDetails = songDetails ?? TrackDetailsStore(
            directory: TrackDetailsStore.defaultDirectory(),
            fetcher: TrackDetailsService(dataAPI: dataAPI, player: YouTubePlayerDetailsClient(isOffline: { connectivity.isOffline }),
                                         musicBrainz: ArtistSpotlightMusicBrainz.shared),
            isOffline: { connectivity.isOffline })
        self.cloudSync = ICloudLibrarySync(library: library)
        let account = account ?? YouTubeAccountStore()
        self.account = account
        self.youTubeWrite = youTubeWrite ?? YouTubeAccountWriteController(account: account,
            permissions: observingPurchases ? YouTubeAccountWritePermissionStore()
                : YouTubeAccountWritePermissionStore(secrets: MemorySecretStore()),
            isOffline: { connectivity.isOffline })
        // The ledger reads once here and writes only during an import; the client makes no request until one starts.
        self.youTubeImport = youTubeImport ?? YouTubeLibraryImporter(library: library, account: account,
                                                                     client: YouTubeAccountLibraryClient(),
                                                                     ledgerStore: YouTubeImportLedgerStore())
        self.appIcons = appIcons ?? AppIconController(enabled: observingPurchases || ProcessInfo.processInfo.arguments.contains("--uitesting"))
        let momentDisk: (any MomentMixPersistence)? = observingPurchases
            ? MomentMixFilePersistence.defaultURL().map { MomentMixFilePersistence(url: $0) } : nil
        self.momentMixes = momentMixes ?? MomentMixController(store: MomentMixStore(persistence: momentDisk),
                                                            usesDeviceSignals: observingPurchases)
        self.tips = TipJarService(library: library, observeTransactions: observingPurchases)
        self.chartProvider = charts ?? YouTubeChartsService()
        let lyrics = lyrics ?? CompositeLyricsProvider(primary: LRCLyricsService(), fallback: catalog as? any LyricsProviding,
            prepareTrack: prepareTrack,
            additionalVariantSource: sources.map { JioSaavnLyricsProvider(catalog: $0.saavn) })
        self.lyrics = lyrics
        if let dataAPI { lyricLanguageLookup = { try await dataAPI.lyricLanguageCode(for: $0) } }
        let languageService = recordingLanguageService ?? ArtistSpotlightLanguageService(provider: lyrics,
            recordingMetadataLookup: recordingMetadataLookup, metadataLookup: { track in
                let prepared = try await prepareTrack?(track) ?? track
                return try await ArtistSpotlightMusicBrainz.shared?.language(for: prepared)
            })
        self.recordingLanguageService = languageService
        let languageCacheURL = observingPurchases ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GanaBajana", isDirectory: true)
            .appendingPathComponent(ListeningLanguageDiscoveryCache.fileName) : nil
        self.languageDiscovery = languageDiscovery ?? ListeningLanguageDiscovery(service: languageService, cacheURL: languageCacheURL)
        // Test hosts get a memory-only store and no MusicBrainz provider, like the language cache.
        let genreStore = genreEvidence ?? GenreEvidenceStore(url: observingPurchases ? GenreEvidenceStore.defaultURL() : nil)
        self.genreEvidence = genreStore
        let genreProvider: (any GenreMetadataProviding)? = genreMetadata
            ?? (observingPurchases ? ArtistSpotlightMusicBrainz.shared.map { $0 as any GenreMetadataProviding } : nil)
        self.genreClassification = GenreEvidenceLoader(store: genreStore, provider: genreProvider)
        let equalizerProfiles = EqualizerProfileStore(url: observingPurchases ? EqualizerProfileStore.defaultURL() : nil)
        self.equalizerProfiles = equalizerProfiles
        player.equalizerSongOverride = { [weak equalizerProfiles] id in
            guard let settings = equalizerProfiles?.override(for: id) else { return nil }
            equalizerProfiles?.markUsed(id)
            return settings
        }
        self.engine = RecommendationEngine(catalog: catalog)
        self.experienceRadio = ExperienceRadioEngine(catalog: catalog)
        self.seedRadioEngine = SeedRadioEngine(catalog: seedRadioCatalog ?? catalog)
        self.releases = ReleaseWatcher(library: library, catalog: catalog, notifier: releaseNotifier ?? LocalReleaseNotifier())
        player.setAudioCacheLimit(library.preferences.audioCacheLimit)
        player.updateCacheListeningHistory(library.events)
        player.setNetworkOffline(connectivity.isOffline)
        player.setRemoteFallbackEnabled(library.preferences.allowRemoteFallback)
        player.setAudioQualityPreference(library.preferences.audioQuality)
        player.setEqualizer(library.preferences.equalizer)
        player.setSponsorBlockSkipping(library.preferences.sponsorBlockSkipping)
        player.apply(PlaybackTransitionSettings(library.preferences))
        player.setShuffleStyle(library.preferences.shuffleStyle)
        player.shuffleHistoryProvider = { [weak library] in
            guard let library, library.hasLoadedDocument, !library.requiresReload,
                  library.preferences.saveListeningHistory else { return nil }
            return library.events
        }
        needsInitialPlaybackRestore = !library.hasLoadedDocument
        player.restore(library.playback)
        player.onListeningProgress = { [weak self, weak library, weak player] track, session, started, seconds in
            guard let library else { return false }
            let event = ListeningEvent(id: session, track: track, startedAt: started, listenedSeconds: seconds)
            let capture = self?.momentMixes.capture(for: [event])
            let historyRevision = library.historyRevision
            let recentPosition = player?.currentTrack?.id == track.id ? player?.position : nil
            guard library.recordListening(track: track, sessionID: session, startedAt: started, seconds: seconds,
                                          recentPosition: recentPosition) else { return false }
            self?.momentMixes.synchronize(library: library, historyEpoch: library.listeningHistoryEpoch,
                                         localEventIDs: [session], capture: capture)
            guard library.historyRevision != historyRevision else { return true }
            self?.refreshListeningLanguages()
            player?.updateCacheListeningHistory(library.events)
            return true
        }
        player.onSnapshotChanged = { [weak self, weak library] snapshot in
            // Lifecycle checkpoints and restore's retirement flush cannot make a failed-startup placeholder durable.
            if self?.needsInitialPlaybackRestore == true {
                guard !snapshot.queue.isEmpty || snapshot.position != 0
                        || snapshot.shuffleEnabled || snapshot.repeatMode != .off else { return }
                self?.needsInitialPlaybackRestore = false
            }
            library?.updatePlayback(snapshot)
        }
        if usesAsyncListeningCheckpoints {
            player.onSnapshotIntentChanged = { [weak self] snapshot in
                guard self?.needsInitialPlaybackRestore == true,
                      !snapshot.queue.isEmpty || snapshot.position != 0 || snapshot.shuffleEnabled || snapshot.repeatMode != .off else { return }
                self?.needsInitialPlaybackRestore = false
            }
            player.onListeningCheckpoint = { [weak self, weak library, weak player] checkpoint in
                guard let self, let library, let player else { return false }
                let momentCapture = self.momentMixes.capture(for: checkpoint.events)
                var snapshot: PlaybackSnapshot? = checkpoint.snapshot
                if self.needsInitialPlaybackRestore {
                    if checkpoint.snapshot.queue.isEmpty && checkpoint.snapshot.position == 0
                        && !checkpoint.snapshot.shuffleEnabled && checkpoint.snapshot.repeatMode == .off {
                        snapshot = nil
                    } else { self.needsInitialPlaybackRestore = false }
                }
                let history = library.historyRevision
                let sessionRevision = self.account.sessionRevision
                let signOutPending = self.account.isSignOutPending
                let acknowledged = await library.recordListeningCheckpoint(events: checkpoint.events, recent: checkpoint.recent,
                    snapshot: snapshot, isCurrentIntent: { [weak player] in
                        player?.isCurrentListeningCheckpointIntent(checkpoint) == true
                    }, isCurrentContext: { [weak self, weak player] in
                        player?.isCurrentListeningCheckpointGeneration(checkpoint) == true
                            && self?.account.sessionRevision == sessionRevision && self?.account.isSignOutPending == signOutPending
                    })
                if acknowledged {
                    self.momentMixes.synchronize(library: library, historyEpoch: library.listeningHistoryEpoch,
                        localEventIDs: Set(checkpoint.events.map(\.id)), capture: momentCapture)
                }
                if acknowledged, library.historyRevision != history {
                    self.refreshListeningLanguages()
                    player.updateCacheListeningHistory(library.events)
                }
                return acknowledged
            }
        }
        player.onTrackStarted = { [weak self, weak library, weak player] track in
            self?.delights.trackStarted(track)
            guard player?.onListeningCheckpoint == nil else { return }
            library?.recordRecent(track: track, position: player?.position ?? 0)
        }
        player.onSleepTimerFired = { [weak self, weak player] in
            self?.delights.sleepTimerFired(wasPlaying: player?.isPlaying == true || player?.isLoading == true)
        }
        player.onQueueExhausted = { [weak self] track in
            await self?.autoplayTracks(after: track) ?? []
        }
        player.onQueueEnded = { [weak self] track in
            await self?.autoplayTracks(after: track, final: true) ?? []
        }
        player.onListeningSignal = { [weak self] signal in
            guard let self else { return }
            self.listeningSignalStore.record(signal, historyEpoch: self.library.listeningHistoryEpoch,
                                             enabled: self.library.preferences.saveListeningHistory)
        }
        library.onHistoryCleared = { [weak self] in
            guard let self else { return }
            self.momentMixes.reset(historyEpoch: self.library.listeningHistoryEpoch)
            self.resetSeedRadioLearning()
            self.synchronizeListeningSignals()
            self.clearSelectedLyrics(reason: .privacy)
            self.cancelPendingWidgetOpen()
            self.player.discardPendingListening()
            if self.library.events.isEmpty { self.languageDiscovery.reset() }
            else { self.languageDiscovery.pause() }
            // The genre store lists only played recordings, so a full clear forgets it like the language cache.
            if self.library.events.isEmpty {
                self.genreClassification.reset()
                self.genreEvidence.reset()
            } else { self.genreClassification.pause() }
            self.invalidateRecommendations()
            self.player.updateCacheListeningHistory(self.library.events)
            // A privacy reset retires captured learning without interrupting the playing queue.
            if self.radioSession?.languageProfile != nil {
                self.retireRadioContinuation()
                self.radioSession?.languageProfile = self.listeningLanguageProfile
            }
            if self.isLoadingRadio || self.radioError != nil { self.cancelPendingRadio() }
            self.hasListeningProfile = !self.tasteProfile().isColdStart
        }
        library.onCloudSyncApplied = { [weak self] previous, recommendationsChanged in
            self?.applyCloudLibraryChange(replacing: previous, recommendationsChanged: recommendationsChanged)
        }
        var syncNotice: String?
        cloudSync.onFailureNotification = { [weak self] message in
            if let message { self?.showToast(message) }
            else if let syncNotice, self?.toast == syncNotice { self?.toast = nil }
            syncNotice = message
        }
        self.languageDiscovery.onResultsChanged = { [weak self] in
            self?.loadedAt = nil
        }
        connectivity.onChange = { [weak self] status in
            self?.connectivityChanged(status)
        }
        connectivity.onExpensiveChange = { [weak self] _ in
            self?.downloads.connectivityChanged()
        }
        self.downloads.onTierChange = { [weak self] _, _ in
            Task { [weak self] in await self?.refreshCachedSongs() }
        }
        self.downloads.setAllowCellular(library.preferences.downloadsOverCellular)
        knownFavoriteIDs = Set(library.favorites.map(\.id))
        knownSuperLikedIDs = library.superLikedIDs
        observeLikesForAutoDownload()
        // The queue resumes on every launch, not only once device services start, so fixtures relaunch truthfully.
        restoreDownloadQueue()
        migrateShuffleDefaultIfNeeded()
        self.momentMixes.startObserving(library: library) { $0.listeningHistoryEpoch }
        installLyricsSelection()
        updates.onRulesChanged = { [weak self] _ in
            guard let self else { return }
            self.playbackWarmer.cancel()
            self.player.preloader.reset()
            self.extractorInvalidationTask?.cancel()
            let resolver = self.player.resolver
            self.extractorInvalidationTask = Task {
                if let composite = resolver as? CompositeStreamResolver {
                    await composite.invalidateExtractionCompatibility()
                } else if let youtube = resolver as? YouTubeStreamResolver {
                    await youtube.invalidateExtractionCompatibility()
                }
            }
        }
        player.onFreshExtractionPlayed = { [weak updates] generation in
            updates?.confirmPlaybackSucceeded(generation: generation)
        }
    }

    /// One edit through the normal preference path, so sync carries the new style and the flag together.
    private func migrateShuffleDefaultIfNeeded() {
        guard library.hasLoadedDocument, !library.requiresReload, !library.preferences.shuffleDefaultMigrated else { return }
        updatePreferences { $0.migrateShuffleDefault() }
    }

    isolated deinit {
        seedRadioStartTask?.cancel()
        extractorInvalidationTask?.cancel()
        youTubeWrite.shutdown()
        lyricsSelectionTask?.cancel()
        widgetOpenTask?.cancel()
        mixesTask?.cancel()
        radioSelectionTask?.cancel()
        radioRetryTask?.cancel()
        autoplayRetryTask?.cancel()
        cachedSongsTask?.cancel()
    }

    // MARK: Preferences

    func activateDeviceServices() {
        deviceServicesAreActive = true
        delights.sceneDidBecomeActive()
        downloads.setForeground(true)
        momentMixes.synchronize(library: library, historyEpoch: library.listeningHistoryEpoch)
        widgetPublisher?.refresh()
        connectivity.start()
        cloudSync.start()
        cloudSync.refresh()
        synchronizeAppIcon()
        refreshListeningLanguages()
        Task { [weak self] in await self?.refreshCachedSongs() }
        restoreDownloadQueue()
        Task.detached(priority: .utility) { AudioExporter.pruneStaleExports() }
    }

    func deactivateDeviceServices() {
        deviceServicesAreActive = false
        delights.sceneDidResignActive()
        downloads.setForeground(false)
        languageDiscovery.pause()
        genreClassification.pause()
        // Leaving the foreground may end the process before a coalesced write fires.
        listeningSignalStore.flush()
        widgetPublisher?.refresh()
    }

    func startWidgetUpdates(store: WidgetSnapshotStore = WidgetSnapshotStore(directory: WidgetSnapshotStore.sharedDirectory())) {
        guard widgetPublisher == nil else { widgetPublisher?.refresh(); return }
        widgetPublisher = WidgetSnapshotPublisher(library: library, store: store) {
            for kind in MusicWidgetKind.allCases { WidgetCenter.shared.reloadTimelines(ofKind: kind.widgetKind) }
        }
        playbackWidgetPublisher = PlaybackWidgetPublisher(player: player, library: library,
                                                          store: WidgetPlaybackStateStore(directory: store.directory)) {
            PlaybackWidgetPublisher.reloadSystemSurfaces()
        }
    }

    var listeningLanguageProfile: ListeningLanguageProfile {
        listeningLanguageProfile(now: Date())
    }

    func listeningLanguageProfile(now: Date, calendar: Calendar = .current) -> ListeningLanguageProfile {
        let key = LanguageProfileCacheKey(summary: languageSummaryCacheKey(now: now, calendar: calendar),
                                          nudges: library.preferences.languageNudges, fallback: library.preferences.languages)
        if let cachedLanguageProfile, cachedLanguageProfile.key == key { return cachedLanguageProfile.profile }
        let started = ContinuousClock.now
        let profile = ListeningLanguageProfile(summary: listeningLanguageSummary(now: now, calendar: calendar), nudges: key.nudges,
                                              evidence: languageDiscovery.results, overrides: library.recordingLanguageOverrides,
                                              fallback: key.fallback)
        cachedLanguageProfile = (key, profile)
        recordListeningProjection(.languageProfile, window: .month, started: started)
        return profile
    }

    // Each window holds one snapshot; advancing time cannot grow these caches or scan history on a hit.
    func listeningSummary(for window: ListeningWindow = .month, now: Date = Date(), calendar: Calendar = .current) -> ListeningSummary {
        let key = listeningSummaryCacheKey(now: now, calendar: calendar)
        if let cached = cachedListeningSummaries[window], cached.key == key { return cached.summary }
        let started = ContinuousClock.now
        let summary = ListeningAnalytics.summary(events: library.events, for: window, now: now, calendar: calendar)
        cachedListeningSummaries[window] = (key, summary)
        recordListeningProjection(.summary, window: window, started: started)
        return summary
    }

    /// Seconds in the window that ended when the current one began; the recap reads it in its body on every update.
    func previousWindowListeningSeconds(for window: ListeningWindow, now: Date = Date(),
                                        calendar: Calendar = .current) -> TimeInterval? {
        guard let cutoff = calendar.date(byAdding: .day, value: -window.days, to: now) else { return nil }
        let key = listeningSummaryCacheKey(now: now, calendar: calendar)
        if let cached = cachedPreviousWindowSeconds[window], cached.key == key { return cached.seconds }
        let started = ContinuousClock.now
        let seconds = ListeningAnalytics.listenedSeconds(events: library.events, for: window, now: cutoff, calendar: calendar)
        cachedPreviousWindowSeconds[window] = (key, seconds)
        recordListeningProjection(.previousWindowSeconds, window: window, started: started)
        return seconds
    }

    func listeningLanguageSummary(for window: ListeningWindow = .month, now: Date = Date(),
                                  calendar: Calendar = .current) -> ListeningLanguageSummary {
        let key = languageSummaryCacheKey(now: now, calendar: calendar)
        if let cached = cachedLanguageSummaries[window], cached.key == key { return cached.summary }
        let listening = listeningSummary(for: window, now: now, calendar: calendar)
        let started = ContinuousClock.now
        let summary = ListeningAnalytics.languageSummary(listening: listening, evidence: languageDiscovery.results,
                                                        overrides: library.recordingLanguageOverrides)
        cachedLanguageSummaries[window] = (key, summary)
        recordListeningProjection(.languageSummary, window: window, started: started)
        return summary
    }

    private struct ListeningSummaryCacheKey: Equatable {
        let historyRevision: UInt64
        let savesHistory: Bool
        let calendar: Calendar
        let minute: Double
    }

    private struct LanguageSummaryCacheKey: Equatable {
        let listening: ListeningSummaryCacheKey
        let evidenceRevision: UInt64
        let overridesRevision: UInt64
    }

    private struct LanguageProfileCacheKey: Equatable {
        let summary: LanguageSummaryCacheKey
        let nudges: LanguageRecommendationNudges
        let fallback: Set<MusicLanguage>
    }

    private struct GenreSummaryCacheKey: Equatable {
        let listening: ListeningSummaryCacheKey
        let evidenceRevision: UInt64
    }

    private func listeningSummaryCacheKey(now: Date, calendar: Calendar) -> ListeningSummaryCacheKey {
        // Match Listening's minute cadence without freezing rolling-window expiry; durable edits bypass the bucket.
        ListeningSummaryCacheKey(historyRevision: library.historyRevision, savesHistory: library.preferences.saveListeningHistory,
                                 calendar: calendar, minute: floor(now.timeIntervalSince1970 / 60))
    }

    private func languageSummaryCacheKey(now: Date, calendar: Calendar) -> LanguageSummaryCacheKey {
        LanguageSummaryCacheKey(listening: listeningSummaryCacheKey(now: now, calendar: calendar),
                                evidenceRevision: languageDiscovery.resultsRevision,
                                overridesRevision: library.recordingLanguageOverridesRevision)
    }

    enum ListeningProjectionKind: String {
        case summary, previousWindowSeconds, languageSummary, genreSummary, languageProfile, genreProfile
    }

    private func recordListeningProjection(_ kind: ListeningProjectionKind, window: ListeningWindow,
                                          started: ContinuousClock.Instant) {
        listeningProjectionBuildCounts[kind, default: 0] += 1
        let elapsed = started.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        log.debug("event=listening_projection_cache_miss kind=\(kind.rawValue, privacy: .public) window=\(window.rawValue, privacy: .public) elapsed_ms=\(milliseconds)")
    }

    func refreshListeningLanguages() {
        languageDiscovery.refresh(events: library.events, overrides: library.recordingLanguageOverrides,
                                  enabled: deviceServicesAreActive && library.preferences.saveListeningHistory && !isOffline)
        // Genre classification shares every eligibility trigger of the language checks.
        refreshListeningGenres()
    }

    func setLanguageNudge(_ nudge: LanguageRecommendationNudge, for language: ArtistSongLanguage) {
        updatePreferences { $0.languageNudges[language] = nudge }
        if let error = library.errorMessage { showToast(error) }
    }

    func resetLanguageNudges() {
        updatePreferences { $0.languageNudges = LanguageRecommendationNudges() }
        if let error = library.errorMessage { showToast(error) }
    }

    // MARK: Genres

    private struct GenreProfileCacheKey: Equatable {
        let summary: GenreSummaryCacheKey
        let nudges: GenreNudges
    }

    /// Cached per (history, evidence, nudges, minute): views read it in their bodies and history changes every checkpoint.
    var listeningGenreProfile: ListeningGenreProfile {
        listeningGenreProfile(now: Date())
    }

    func listeningGenreProfile(now: Date, calendar: Calendar = .current) -> ListeningGenreProfile {
        let key = GenreProfileCacheKey(summary: GenreSummaryCacheKey(listening: listeningSummaryCacheKey(now: now, calendar: calendar),
                                                                    evidenceRevision: genreEvidence.revision),
                                       nudges: library.preferences.genreNudges)
        if let cachedGenreProfile, cachedGenreProfile.key == key { return cachedGenreProfile.profile }
        let started = ContinuousClock.now
        let profile = ListeningGenreProfile(summary: listeningGenreSummary(now: now, calendar: calendar),
                                           nudges: key.nudges, evidence: genreEvidence.distributions)
        cachedGenreProfile = (key, profile)
        recordListeningProjection(.genreProfile, window: .month, started: started)
        if loggedGenreProfileKey != profile.requestKey {
            loggedGenreProfileKey = profile.requestKey
            GenreEvidenceStore.log.info("event=genre_profile coverage=\(Int((profile.coverage * 100).rounded())) top=\(profile.topFamily?.rawValue ?? "none", privacy: .public)")
        }
        return profile
    }

    func listeningGenreSummary(for window: ListeningWindow = .month, now: Date = Date(),
                               calendar: Calendar = .current) -> ListeningGenreSummary {
        let key = GenreSummaryCacheKey(listening: listeningSummaryCacheKey(now: now, calendar: calendar),
                                       evidenceRevision: genreEvidence.revision)
        if let cached = cachedGenreSummaries[window], cached.key == key { return cached.summary }
        let listening = listeningSummary(for: window, now: now, calendar: calendar)
        let started = ContinuousClock.now
        let summary = ListeningAnalytics.genreSummary(listening: listening, evidence: genreEvidence.distributions)
        cachedGenreSummaries[window] = (key, summary)
        recordListeningProjection(.genreSummary, window: window, started: started)
        return summary
    }

    func refreshListeningGenres() {
        genreClassification.refresh(events: library.events,
                                    enabled: deviceServicesAreActive && library.preferences.saveListeningHistory && !isOffline)
    }

    func setGenreNudge(_ nudge: ListeningNudge, for family: GenreFamily) {
        updatePreferences { $0.genreNudges[family] = nudge }
        if let error = library.errorMessage { showToast(error) }
    }

    func resetGenreNudges() {
        updatePreferences { $0.genreNudges = GenreNudges() }
        if let error = library.errorMessage { showToast(error) }
    }

    private func invalidateRecommendations() {
        retirePersonalization()
        homeGeneration = UUID()
        isLoadingHome = false
        homeError = nil
        loadedLanguageProfileKey = nil
        loadedGenreProfileKey = nil
        loadedDiscoveryFamiliarity = nil
        loadedAt = nil
        homeSections.removeAll { $0.id.hasPrefix("personal.") || $0.id.hasPrefix("discovery.language.") }
    }

    // MARK: Cached listening

    var isOffline: Bool { connectivity.status == .offline }

    private func connectivityChanged(_ status: ConnectivityMonitor.Status) {
        let wasOffline = lastConnectivityWasOffline
        lastConnectivityWasOffline = status == .offline
        player.setNetworkOffline(status == .offline)
        player.preloader.refreshNetwork()
        if status == .offline || wasOffline {
            homeGeneration = UUID()
            searchGeneration = UUID()
            isLoadingHome = false
            isSearching = false
            loadedAt = nil
        }
        if status == .offline {
            languageDiscovery.pause()
            genreClassification.pause()
            retirePersonalization()
            retireAutoplayContinuation()
            retireRadioContinuation()
            if isLoadingRadio || radioError != nil { cancelPendingRadio() }
        } else if deviceServicesAreActive {
            refreshListeningLanguages()
        }
        downloads.connectivityChanged()
        Task { [weak self] in await self?.refreshCachedSongs() }
    }

    func refreshCachedSongs() async {
        if let cachedSongsTask { await cachedSongsTask.value; return }
        let generation = UUID()
        cachedSongsGeneration = generation
        isRefreshingCachedSongs = true
        let player = player
        let work = Task { @MainActor [weak self] in
            defer {
                if self?.cachedSongsGeneration == generation {
                    self?.isRefreshingCachedSongs = false
                    self?.cachedSongsTask = nil
                }
            }
            do {
                let snapshot = try await player.cachedSongsSnapshot()
                try Task.checkCancellation()
                guard let self, self.cachedSongsGeneration == generation else { return }
                self.cachedSongs = snapshot?.songs ?? []
                self.cachedSongsUsage = snapshot?.usage
                self.cachedPlayableTrackIDs = Set(self.cachedSongs.filter(\.isPlayable).map(\.id))
                self.inventoryDownloadedTrackIDs = Set(self.cachedSongs.filter(\.isDownloaded).map(\.id))
                self.downloads.inventoryRefreshed(downloadedIDs: self.inventoryDownloadedTrackIDs)
                self.cachedSongsError = nil
                self.hasLoadedCachedSongs = true
            } catch {
                // A read that ended as cancelled has no result to report; the next refresh simply tries again.
                guard let self, self.cachedSongsGeneration == generation, !Task.isCancelled,
                      !(error is CancellationError) else { return }
                self.cachedSongsError = error.localizedDescription
            }
        }
        cachedSongsTask = work
        await work.value
    }

    /// Cached songs screens report their visibility so the offline banner can hide its redundant action.
    func cachedSongsScreenAppeared() { visibleCachedSongsScreens += 1 }
    func cachedSongsScreenDisappeared() { visibleCachedSongsScreens = max(0, visibleCachedSongsScreens - 1) }
    func onThisDeviceScreenAppeared() { visibleOnThisDeviceScreens += 1 }
    func onThisDeviceScreenDisappeared() { visibleOnThisDeviceScreens = max(0, visibleOnThisDeviceScreens - 1) }

    /// Complete local songs that play without a connection: downloads first, then the temporary cache, each by title.
    var onThisDeviceSongs: (downloaded: [(song: CachedSong, track: Track)], cached: [(song: CachedSong, track: Track)]) {
        // One lookup table instead of `cachedTrack(for:)` per song, which rebuilds the known tracks each call.
        var known: [String: Track] = [:]
        for track in player.queue + library.favorites + library.playlists.flatMap(\.tracks)
            + library.recentlyPlayed.map(\.track) + library.events.map(\.track) + library.mixes.flatMap(\.tracks)
            where known[track.id] == nil { known[track.id] = track }
        let playable = cachedSongs.filter(\.isPlayable).map { song in
            let track = song.track.flatMap { $0.id == song.id ? $0 : nil } ?? known[song.id]
                ?? Track(id: song.id, title: "Cached song", duration: song.preferredAudio?.duration, isAudioRecording: true)
            return (song: song, track: track)
        }
        let sorted = playable.sorted { $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending }
        return (sorted.filter { $0.song.isDownloaded }, sorted.filter { !$0.song.isDownloaded })
    }

    func removeCachedSong(id: String) async {
        do {
            guard let removal = try await player.removeCachedSong(id: id) else {
                showToast("This playback provider cannot manage cached songs.")
                return
            }
            // A snapshot captured before deletion must not put a removed row back on screen.
            cachedSongsGeneration = UUID()
            cachedSongsTask?.cancel()
            cachedSongsTask = nil
            isRefreshingCachedSongs = false
            cachedSongsUsage = removal.usage
            switch removal.outcome {
            case .removed:
                cachedSongs.removeAll { $0.id == id }
                cachedPlayableTrackIDs.remove(id)
                showToast("Removed from this device’s cache.")
            case .notFound:
                cachedSongs.removeAll { $0.id == id }
                cachedPlayableTrackIDs.remove(id)
                showToast("That song is no longer cached.")
            case .inUse:
                showToast("This song is in use. Try again after playback moves on.")
            }
            await refreshCachedSongs()
        } catch {
            cachedSongsError = error.localizedDescription
            showToast(error.localizedDescription)
        }
    }

    func cachedTrack(for song: CachedSong) -> Track? {
        if let track = song.track, track.id == song.id { return track }
        let known = player.queue + library.favorites + library.playlists.flatMap(\.tracks)
            + library.recentlyPlayed.map(\.track) + library.events.map(\.track) + library.mixes.flatMap(\.tracks)
        if let track = known.first(where: { $0.id == song.id }) { return track }
        guard song.isPlayable else { return nil }
        return Track(id: song.id, title: "Cached song", duration: song.preferredAudio?.duration, isAudioRecording: true)
    }

    func offlineSearchTracks(query: String) -> [Track] {
        var seen = Set<String>()
        let tracks = (library.favorites + library.playlists.flatMap(\.tracks)
                      + library.recentlyPlayed.map(\.track) + cachedSongs.compactMap { cachedTrack(for: $0) })
            .filter { seen.insert($0.id).inserted }
        return LibraryTrackSearch(tracks: tracks, query: query).tracks
    }

    func selectAppIcon(_ option: AppIconOption) {
        updatePreferences { $0.appIconID = option.id }
        guard library.preferences.appIconID == option.id, library.errorMessage == nil else { return }
        appIcons.request(option)
    }

    private func synchronizeAppIcon() {
        guard deviceServicesAreActive, appIcons.supportsAlternateIcons else { return }
        let id = library.preferences.appIconID
        if id.isEmpty {
            if !appIcons.current.isPrimary {
                updatePreferences { $0.appIconID = appIcons.current.id }
            }
        } else {
            appIcons.request(AppIcons.all.first { $0.id == id } ?? AppIcons.primary)
        }
    }

    private func applyCloudLibraryChange(replacing previous: UserPreferences, recommendationsChanged: Bool) {
        let applied = library.preferences
        applyPreferenceServices(applied, replacing: previous)
        if recommendationsChanged {
            invalidateRecommendations()
            homeSections = withoutDisliked(homeSections)
            refreshListeningLanguages()
            player.updateCacheListeningHistory(library.events)
            hasListeningProfile = !tasteProfile().isColdStart
        }
        synchronizeAppIcon()
    }

    /// Single entry point for preference edits so dependent services see the change at once.
    func updatePreferences(_ change: (inout UserPreferences) -> Void) {
        var preferences = library.preferences
        let previous = preferences
        change(&preferences)
        guard preferences != previous else { return }
        if preferences.crossfadeSeconds != previous.crossfadeSeconds || preferences.saveListeningHistory != previous.saveListeningHistory {
            player.flushListeningProgress()
        }
        library.preferences = preferences
        let applied = library.preferences
        // Enabling starts a fresh session; time accumulated while history was disabled must not be backfilled.
        if previous.saveListeningHistory != applied.saveListeningHistory {
            if !applied.saveListeningHistory { cancelPendingWidgetOpen() }
            player.discardPendingListening()
        }
        if applied.languageNudges != previous.languageNudges || applied.languages != previous.languages
            || applied.discoveryFamiliarity != previous.discoveryFamiliarity || applied.genreNudges != previous.genreNudges {
            invalidateRecommendations()
        }
        applyPreferenceServices(applied, replacing: previous)
        if applied.saveListeningHistory != previous.saveListeningHistory {
            refreshListeningLanguages()
            player.updateCacheListeningHistory(library.events)
        }
    }

    private func applyPreferenceServices(_ applied: UserPreferences, replacing previous: UserPreferences) {
        momentMixes.synchronize(library: library, historyEpoch: library.listeningHistoryEpoch)
        synchronizeSeedRadioHistory()
        synchronizeListeningSignals()
        if applied.saveListeningHistory != previous.saveListeningHistory { resetSeedRadioLearning() }
        if previous.saveListeningHistory, !applied.saveListeningHistory { clearSelectedLyrics(reason: .privacy) }
        if applied.shuffleStyle != previous.shuffleStyle {
            player.setShuffleStyle(applied.shuffleStyle)
        }
        if applied.audioCacheLimit != previous.audioCacheLimit {
            player.setAudioCacheLimit(applied.audioCacheLimit)
        }
        if applied.languageNudges != previous.languageNudges || applied.languages != previous.languages,
           radioRequestUsesPreferences, isLoadingRadio || radioError != nil { cancelPendingRadio() }
        if PlaybackTransitionSettings(applied) != PlaybackTransitionSettings(previous) {
            player.apply(PlaybackTransitionSettings(applied))
        }
        if previous.autoplay, !applied.autoplay { retireAutoplayContinuation() }
        if applied.allowRemoteFallback != previous.allowRemoteFallback {
            player.setRemoteFallbackEnabled(applied.allowRemoteFallback)
        }
        if applied.audioQuality != previous.audioQuality {
            player.setAudioQualityPreference(applied.audioQuality)
        }
        if applied.equalizer != previous.equalizer {
            player.setEqualizer(applied.equalizer)
        }
        if applied.sponsorBlockSkipping != previous.sponsorBlockSkipping {
            player.setSponsorBlockSkipping(applied.sponsorBlockSkipping)
        }
        if applied.enabledCatalogSources != previous.enabledCatalogSources, let composite = catalog as? CompositeCatalog {
            let sources = applied.enabledCatalogSources
            Task { await composite.setEnabledSources(sources) }
        }
        if applied.useEncryptedDNS != previous.useEncryptedDNS {
            LyricsDNSConfiguration.configure(enabled: applied.useEncryptedDNS)
        }
        if applied.downloadsOverCellular != previous.downloadsOverCellular {
            downloads.setAllowCellular(applied.downloadsOverCellular)
            player.preloader.refreshNetwork()
        }
    }

    // MARK: Production providers

    /// The provider services the production catalog and resolver share.
    struct ProductionSources {
        let youTube = YouTubeMusicService()
        let saavn = JioSaavnCatalogService()
        let gaana = GaanaCatalogService()
    }

    /// YouTube Music stays the primary catalog and fallback; JioSaavn and Gaana join behind their id prefixes.
    private static func makeProductionCatalog(sources: ProductionSources, enabledSources: [MusicSource]) -> CompositeCatalog {
        CompositeCatalog(youTube: sources.youTube, secondary: [.jioSaavn: sources.saavn, .gaana: sources.gaana],
                         enabledSources: enabledSources)
    }

    /// Gaana falls back to the same recording on JioSaavn, then YouTube Music, when its own stream is unavailable.
    private static func makeProductionResolver(sources: ProductionSources,
                                               isOffline: @escaping @Sendable () -> Bool) -> CompositeStreamResolver {
        let youTube = YouTubeStreamResolver(isOffline: isOffline)
        let saavn = JioSaavnStreamResolver(catalog: sources.saavn)
        let gaana = GaanaStreamResolver(catalog: sources.gaana, fallbacks: [
            JioSaavnStreamFallback(catalog: sources.saavn, resolver: saavn),
            YouTubeStreamFallback(catalog: sources.youTube, resolver: youTube),
        ])
        return CompositeStreamResolver(youTube: youTube, saavn: saavn, gaana: gaana, isOffline: isOffline)
    }

    // MARK: Downloads

    /// Songs with a complete copy in the permanent tier: the inventory plus promotions it has not re-read yet.
    var downloadedTrackIDs: Set<String> { inventoryDownloadedTrackIDs.union(downloads.recentlyDownloadedIDs) }

    func isDownloaded(_ track: Track) -> Bool {
        inventoryDownloadedTrackIDs.contains(track.id) || downloads.recentlyDownloadedIDs.contains(track.id)
    }

    /// A complete local copy in either tier, which is what export and the "Download to export" hint depend on.
    func hasLocalCopy(_ track: Track) -> Bool {
        downloadedTrackIDs.contains(track.id) || cachedPlayableTrackIDs.contains(track.id)
    }

    func downloadState(for track: Track) -> DownloadState? {
        if isDownloaded(track) { return .downloaded(bytes: 0) }
        return downloads.state(for: track.id)
    }

    func download(_ track: Track) {
        download([track])
    }

    func download(_ tracks: [Track]) {
        guard downloads.isAvailable else { showToast("Downloads are not available with this playback provider."); return }
        let wanted = tracks.filter { !isDownloaded($0) }
        guard !wanted.isEmpty else { return }
        downloads.download(wanted)
    }

    func removeDownload(_ track: Track) async {
        do {
            guard let change = try await downloads.removeDownload(track.id) else {
                showToast("Downloads are not available with this playback provider.")
                return
            }
            inventoryDownloadedTrackIDs.remove(track.id)
            switch change {
            case .moved, .alreadyThere: showToast("Removed from downloads. It stays cached for now.")
            case .notFound: showToast("This song was not downloaded.")
            }
        } catch {
            showToast(error.localizedDescription)
        }
        await refreshCachedSongs()
    }

    func deleteDownload(id: String) async {
        do {
            guard let deletion = try await downloads.deleteDownload(id) else {
                showToast("Downloads are not available with this playback provider.")
                return
            }
            inventoryDownloadedTrackIDs.remove(id)
            cachedSongsGeneration = UUID()
            cachedSongsTask?.cancel()
            cachedSongsTask = nil
            isRefreshingCachedSongs = false
            switch deletion {
            case .deleted:
                cachedSongs.removeAll { $0.id == id }
                cachedPlayableTrackIDs.remove(id)
                showToast("Download deleted.")
            case .demotedInUse: showToast("This song is playing. It stays cached until playback moves on.")
            case .notFound: showToast("This song was not downloaded.")
            }
        } catch {
            showToast(error.localizedDescription)
        }
        await refreshCachedSongs()
    }

    func collectionDownloadState(for tracks: [Track]) -> CollectionDownloadState {
        downloads.collectionState(for: tracks, downloadedIDs: inventoryDownloadedTrackIDs)
    }

    func removeCollectionDownloads(_ tracks: [Track]) async {
        var seen = Set<String>()
        for track in tracks where seen.insert(track.id).inserted {
            if downloads.isQueued(track.id) { downloads.cancel(track.id) }
            guard isDownloaded(track) else { continue }
            _ = try? await downloads.removeDownload(track.id)
            inventoryDownloadedTrackIDs.remove(track.id)
        }
        showToast("Removed from downloads.")
        await refreshCachedSongs()
    }

    /// Liked songs that are neither downloaded nor already queued; the Settings confirmation states this count.
    var pendingLikedDownloads: [Track] { pendingAutoDownloads(for: .liked) }

    /// The backlog a Download Liked Songs choice would queue: super likes for Super Liked Only, every like for All Liked.
    func pendingAutoDownloads(for scope: AutoDownloadScope) -> [Track] {
        let candidates: [Track] = switch scope {
        case .off: []
        case .superLiked: library.superLikes
        case .liked: library.favorites
        }
        return candidates.filter { !isDownloaded($0) && !downloads.isQueued($0.id) }
    }

    func downloadAllLikedSongs() {
        download(pendingLikedDownloads)
    }

    func downloadPendingAutoDownloads(for scope: AutoDownloadScope) {
        download(pendingAutoDownloads(for: scope))
    }

    func exportAudio(for track: Track) async throws -> AudioExport {
        let cover = try await AudioExportArtworkResolver.resolve(for: track)
        let exporter = exporter
        guard let result = try await downloads.withLocalCopy(for: track.id, operation: { source in
            try await exporter.export(track: track, source: source, artwork: cover)
        }) else { throw AudioExportError.noLocalCopy }
        return result
    }

    func restoreDownloadQueue() {
        guard downloads.isAvailable else { return }
        let library = library
        downloads.restoreQueue { ids in
            try await MainActor.run {
                guard library.hasLoadedDocument, !library.requiresReload else { throw BackgroundDownloadFailure.staging }
                let known = library.favorites + library.playlists.flatMap(\.tracks) + library.recentlyPlayed.map(\.track)
                    + library.events.map(\.track) + library.mixes.flatMap(\.tracks)
                let wanted = Set(ids)
                var seen = Set<String>()
                return known.filter { wanted.contains($0.id) && seen.insert($0.id).inserted }
            }
        }
    }

    /// Likes are written by many callers (rows, player, Watch, iCloud merges); observing the store covers them all.
    private func observeLikesForAutoDownload() {
        withObservationTracking {
            _ = library.favorites
            _ = library.superLikedIDs
        } onChange: {
            Task { @MainActor [weak self] in self?.favoritesChanged() }
        }
    }

    private func favoritesChanged() {
        let favorites = library.favorites
        let superLiked = library.superLikedIDs
        let added = favorites.filter { !knownFavoriteIDs.contains($0.id) }
        let promoted = favorites.filter { superLiked.contains($0.id) && !knownSuperLikedIDs.contains($0.id) }
        knownFavoriteIDs = Set(favorites.map(\.id))
        knownSuperLikedIDs = superLiked
        if downloads.isAvailable {
            switch library.preferences.autoDownloadScope {
            case .liked where !added.isEmpty:
                log.info("event=download_auto_like count=\(added.count)")
                download(added)
            case .superLiked where !promoted.isEmpty:
                // A promotion of an already liked song is new to this scope even though the like is not new.
                log.info("event=download_auto_super_like count=\(promoted.count)")
                download(promoted)
            default: break
            }
        }
        observeLikesForAutoDownload()
    }

    // MARK: Likes

    enum LikeSurface: String { case player, menu, more, library, watch, carPlay, home, nearbyDevice }

    /// The heart tap: like, or remove a like and any super like with it. The tip learns that a like happened.
    func toggleLike(_ track: Track, surface: LikeSurface) {
        let wasSuperLiked = library.isSuperLiked(track)
        let wasLiked = library.isFavorite(track)
        library.toggleFavorite(track)
        guard library.isFavorite(track) != wasLiked else { return }
        if wasSuperLiked {
            log.info("event=super_like action=remove surface=\(surface.rawValue, privacy: .public)")
        } else if !wasLiked {
            TipSupport.donateSongLiked()
            delights.likeAdded(likedCount: library.favorites.count)
        }
    }

    /// The heart hold or menu row: not liked or liked becomes super liked; super liked steps back to liked.
    func toggleSuperLike(_ track: Track, surface: LikeSurface) {
        let promote = !library.isSuperLiked(track)
        let wasLiked = library.isFavorite(track)
        library.setSuperLiked(track, promote)
        guard library.isSuperLiked(track) == promote else { return }
        log.info("event=super_like action=\(promote ? "promote" : "demote", privacy: .public) surface=\(surface.rawValue, privacy: .public)")
        if !wasLiked { delights.likeAdded(likedCount: library.favorites.count) }
    }

    // MARK: Library recovery

    /// Reload runs outside listening callbacks so privacy boundaries retire captured deltas before retries.
    @discardableResult
    func reloadSavedLibrary() -> LibraryReloadResult {
        cancelPendingArtistLookup()
        dismissSearchKeyboard()
        let previous = library.preferences
        let result = library.reloadFromDisk()
        guard result != .failed else {
            showToast(library.errorMessage ?? "Your saved library couldn’t be reloaded.")
            return result
        }

        invalidateRecommendations()
        migrateShuffleDefaultIfNeeded()
        let applied = library.preferences
        homeSections = withoutDisliked(homeSections)
        if isLoadingRadio || radioError != nil { cancelPendingRadio() }
        applyPreferenceServices(applied, replacing: previous)
        // The skip-history file has no reload control of its own; library recovery retries it.
        if listeningSignalStore.isBlocked {
            listeningSignalStore.reload(historyEpoch: library.listeningHistoryEpoch, enabled: applied.saveListeningHistory)
        }
        refreshListeningLanguages()
        player.updateCacheListeningHistory(library.events)
        // A reloaded document is recovered state, not a burst of new likes.
        knownFavoriteIDs = Set(library.favorites.map(\.id))
        knownSuperLikedIDs = library.superLikedIDs

        // An untouched failed-startup placeholder has no live resume state to take precedence over the saved queue.
        if needsInitialPlaybackRestore {
            player.restore(library.playback)
            needsInitialPlaybackRestore = false
        }
        player.flushListeningProgress()
        restoreDownloadQueue()
        hasListeningProfile = !tasteProfile().isColdStart
        showToast(library.errorMessage ?? "Saved library reloaded.")
        return result
    }

    // MARK: Home

    @discardableResult
    func playLiveRadio(_ station: LiveRadioStation) -> Bool {
        guard !isOffline else { showToast("Live radio needs an internet connection."); return false }
        cancelPendingArtistLookup()
        endRadioSession()
        retireAutoplayContinuation()
        dismissSearchKeyboard()
        playbackWarmer.cancel()
        let accepted = player.playLiveRadio(station)
        if accepted { needsInitialPlaybackRestore = false }
        else { showToast(player.errorMessage ?? "This station couldn’t be opened.") }
        return accepted
    }

    func loadHome(force: Bool = false) async {
        refreshListeningLanguages()
        guard !isOffline else {
            isLoadingHome = false
            homeError = nil
            await refreshCachedSongs()
            return
        }
        let languageProfile = listeningLanguageProfile
        let genreProfile = listeningGenreProfile
        let familiarity = library.preferences.discoveryFamiliarity
        let profileKey = languageProfile.requestKey
        let genreKey = genreProfile.requestKey
        let chartLanguages = Self.chartLanguages(for: languageProfile)
        refreshMixes()
        Task { await checkForNewReleases() }
        if !force, !isLoadingHome, !homeSections.isEmpty, loadedLanguageProfileKey == profileKey,
           loadedGenreProfileKey == genreKey, loadedDiscoveryFamiliarity == familiarity,
           let loadedAt, Date().timeIntervalSince(loadedAt) < 900 {
            homeGeneration = UUID()
            return
        }
        let generation = UUID()
        homeGeneration = generation
        isLoadingHome = true
        homeError = nil
        charts.removeAll { !chartLanguages.contains($0.language) }
        defer { if generation == homeGeneration { isLoadingHome = false } }

        let chartProvider = chartProvider
        let engine = engine
        let profile = tasteProfile()
        hasListeningProfile = !profile.isColdStart
        let personalGeneration = personalizationGeneration
        if profile.isColdStart { homeSections.removeAll { $0.id.hasPrefix("personal.") } }
        var discoveryFailure: String?
        var discoverySucceeded = false

        await withTaskGroup(of: HomeUpdate.self) { group in
            group.addTask {
                do { return .sections(try await engine.languageDiscovery(profile: profile, languageProfile: languageProfile,
                                                                        familiarity: familiarity, genreProfile: genreProfile)) }
                catch { return .discoveryFailure(error.localizedDescription) }
            }
            // Charts retain their provider region and dates; their scope is not a claim about song language.
            for language in MusicLanguage.allCases where chartLanguages.contains(language) {
                group.addTask {
                    do { return .chart(try await chartProvider.weeklyChart(language: language)) }
                    catch { return .chartFailure }
                }
            }
            if !profile.isColdStart {
                group.addTask {
                    do { return .personal(try await engine.becauseYouListen(profile: profile, languages: [], languageProfile: languageProfile,
                                                                           familiarity: familiarity, genreProfile: genreProfile)) }
                    catch { return .chartFailure }
                }
            }
            for await update in group {
                guard generation == homeGeneration, profileKey == listeningLanguageProfile.requestKey,
                      familiarity == library.preferences.discoveryFamiliarity,
                      !Task.isCancelled else { group.cancelAll(); return }
                switch update {
                case .sections(let incoming):
                    let sections = incoming.filter { !Self.excludedHomeShelfIDs.contains($0.id) }
                    let personal = homeSections.filter { $0.id.hasPrefix("personal.") }
                    homeSections = personal + withoutDisliked(sections)
                    discoverySucceeded = !sections.isEmpty
                    if player.currentTrack == nil {
                        // With preloading available, Home's first songs no longer earn a speculative complete download.
                        if player.preloader.isAvailable {
                            playbackWarmer.warm(sections.flatMap(\.tracks), surface: .home, owner: Self.homeWarmOwner)
                        } else {
                            player.prefetch(sections.flatMap(\.tracks))
                        }
                    }
                case .personal(let sections):
                    guard personalGeneration == personalizationGeneration else { continue }
                    homeSections.removeAll { $0.id.hasPrefix("personal.") }
                    let preferred = withoutDisliked(sections).filter { !$0.tracks.isEmpty }
                    homeSections.insert(contentsOf: preferred, at: 0)
                case .chart(let chart):
                    charts.removeAll { $0.language == chart.language }
                    charts.append(chart)
                    charts.sort { $0.language.rawValue > $1.language.rawValue }
                case .discoveryFailure(let message): discoveryFailure = message
                case .chartFailure: log.info("optionalChartOrRadioUnavailable=1")
                }
            }
        }
        guard generation == homeGeneration, profileKey == listeningLanguageProfile.requestKey,
              familiarity == library.preferences.discoveryFamiliarity, !Task.isCancelled else { return }
        if let discoveryFailure { homeError = discoveryFailure }
        if discoverySucceeded {
            loadedLanguageProfileKey = profileKey
            loadedGenreProfileKey = genreKey
            loadedDiscoveryFamiliarity = familiarity
            loadedAt = Date()
        }
    }

    private static func chartLanguages(for profile: ListeningLanguageProfile) -> Set<MusicLanguage> {
        let supported: Set<MusicLanguage> = Set(profile.orderedLanguages.compactMap { language in
            switch language {
            case .hindi: .hindi
            case .english: .english
            default: nil
            }
        })
        return supported.isEmpty ? Set(MusicLanguage.allCases) : supported
    }

    // MARK: Mixes

    var discoverWeekly: GeneratedPlaylist? { library.mix(.discoverWeekly) }
    var dailyMix: GeneratedPlaylist? { library.mix(.dailyMix) }
    /// Daily Mix 1 to 3 in order; a later mix from another period than Daily Mix 1 is never shown beside it.
    var dailyMixes: [GeneratedPlaylist] {
        guard let first = dailyMix else { return [] }
        return [first] + GeneratedPlaylistKind.dailyMixes.dropFirst().compactMap { kind in
            library.mix(kind).flatMap { $0.periodKey == first.periodKey && !$0.tracks.isEmpty ? $0 : nil }
        }
    }

    /// Regenerates each mix whose period has rolled over; a mix from the current period is never replaced.
    @discardableResult
    func refreshMixes() -> Task<Void, Never>? {
        guard !isOffline, generatesMixes, library.preferences.saveListeningHistory || !library.mixes.isEmpty else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let weekKey = RecommendationEngine.weekKey(for: now, calendar: calendar)
        let dayKey = RecommendationEngine.dayKey(for: now, calendar: calendar)
        let needsWeekly = library.mix(.discoverWeekly)?.periodKey != weekKey
        let needsDaily = library.mix(.dailyMix)?.periodKey != dayKey
        guard needsWeekly || needsDaily else { return nil }
        if let mixesTask { return mixesTask }
        let profile = tasteProfile()
        hasListeningProfile = !profile.isColdStart
        guard !profile.isColdStart else { return nil }
        let languageProfile = listeningLanguageProfile
        let genreProfile = listeningGenreProfile
        let nudges = library.preferences.languageNudges
        let genreNudges = library.preferences.genreNudges
        let familiarity = library.preferences.discoveryFamiliarity
        let overrides = library.recordingLanguageOverrides
        let fallback = library.preferences.languages
        let followedArtistKeys = Set(library.followedArtists.map { TasteProfile.normalizedArtistName($0.name) })
        let engine = engine
        let generation = personalizationGeneration
        let periods: [(GeneratedPlaylistKind, String)] = [(.discoverWeekly, weekKey), (.dailyMix, dayKey)]
        isGeneratingMixes = true
        mixesTask = Task { @MainActor [weak self] in
            defer {
                if self?.personalizationGeneration == generation {
                    self?.mixesTask = nil
                    self?.isGeneratingMixes = false
                }
            }
            for (kind, periodKey) in periods {
                guard !Task.isCancelled, self?.personalizationGeneration == generation,
                       self?.library.preferences.languageNudges == nudges,
                       self?.library.preferences.genreNudges == genreNudges,
                       self?.library.preferences.discoveryFamiliarity == familiarity,
                      self?.library.recordingLanguageOverrides == overrides,
                      self?.library.preferences.languages == fallback else { return }
                guard self?.library.mix(kind)?.periodKey != periodKey else { continue }
                let generated: [GeneratedPlaylist]
                if kind == .discoverWeekly {
                    generated = (try? await engine.discoverWeekly(profile: profile, languages: [], periodKey: periodKey,
                                                                 languageProfile: languageProfile, familiarity: familiarity,
                                                                 genreProfile: genreProfile)).map { [$0] } ?? []
                } else {
                    generated = (try? await engine.dailyMixes(profile: profile, periodKey: periodKey,
                                                             languageProfile: languageProfile, familiarity: familiarity,
                                                             genreProfile: genreProfile, followedArtistKeys: followedArtistKeys)) ?? []
                }
                guard !Task.isCancelled, let self, self.personalizationGeneration == generation,
                       self.library.preferences.languageNudges == nudges,
                       self.library.preferences.genreNudges == genreNudges,
                       self.library.preferences.discoveryFamiliarity == familiarity,
                      self.library.recordingLanguageOverrides == overrides,
                      self.library.preferences.languages == fallback else { return }
                guard !generated.isEmpty, self.library.mix(kind)?.periodKey != periodKey else { continue }
                let disliked = self.library.dislikedTrackIDs
                let mixes = generated.map { mix in
                    var mix = mix
                    mix.tracks.removeAll { disliked.contains($0.id) }
                    return mix
                }
                if kind == .discoverWeekly { mixes.forEach(self.library.saveMix) } else { self.library.saveDailyMixes(mixes) }
            }
        }
        return mixesTask
    }

    private func retirePersonalization() {
        personalizationGeneration = UUID()
        mixesTask?.cancel()
        mixesTask = nil
        isGeneratingMixes = false
    }

    /// Rebuilt when its library inputs change or a minute passes; Home returns and mix checks otherwise reuse it,
    /// because a build walks the whole listening history on the main actor.
    private func tasteProfile() -> TasteProfile {
        let now = Date()
        let key = TasteProfileCacheKey(inputs: library.tasteInputsRevision, signals: listeningSignalsRevision,
                                       minute: floor(now.timeIntervalSince1970 / 60))
        if let cachedTasteProfile, cachedTasteProfile.key == key { return cachedTasteProfile.profile }
        let profile = TasteProfile.build(events: library.events, favorites: library.favorites, playlists: library.playlists,
                                         recents: library.recentlyPlayed, disliked: library.disliked,
                                         superLikedIDs: library.superLikedIDs, signals: listeningSignals, now: now)
        cachedTasteProfile = (key, profile)
        return profile
    }

    private struct TasteProfileCacheKey: Equatable {
        let inputs: [UInt64]
        /// A new durable skip must rebuild the profile within the same minute.
        let signals: UInt64
        let minute: Double
    }

    // MARK: Navigation

    func receiveReleaseNotification(_ route: ReleaseNotificationRoute) {
        pendingReleaseNotification = route
        openPendingReleaseNotification()
    }

    func setReleaseNotificationNavigationReady(_ ready: Bool) {
        isReleaseNotificationNavigationReady = ready
        openPendingReleaseNotification()
    }

    private func openPendingReleaseNotification() {
        guard isReleaseNotificationNavigationReady, let route = pendingReleaseNotification else { return }
        pendingReleaseNotification = nil
        let saved = library.releases.first { $0.id == route.id }
        let collection = MusicCollection(id: route.id, title: saved?.title ?? route.title,
                                         subtitle: saved?.subtitle ?? route.subtitle,
                                         artworkURL: saved?.artworkURL, kind: .album)
        // Reset local Library destinations as well as the typed path before opening an external destination.
        openLibrary()
        open(collection)
    }

    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        if url.host?.lowercased() == "widget" { return handleWidgetURL(url) }
        if url.scheme?.lowercased() == "ganabajana", url.host?.lowercased() == "player", url.path.isEmpty, url.query == nil {
            performPlaybackIntent(.openPlayer)
            return true
        }
        guard url.scheme == "ganabajana", url.host == "search",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value else { return false }
        openSearch(query)
        return true
    }

    /// RootView sends user tab taps here, including a reselect of the current tab.
    func selectTab(_ tab: AppTab) {
        cancelPendingArtistLookup()
        let isReselection = selectedTab == tab
        selectedTab = tab
        guard tab == .search else { return }
        navigationPaths[.search] = []
        if isReselection {
            searchRootGeneration = UUID()
            searchFocusRequest += 1
        }
        else { dismissSearchKeyboard() }
    }

    func openLibrary() {
        cancelPendingArtistLookup()
        dismissSearchKeyboard()
        widgetLibraryDestination = nil
        showsLibraryCachedSongs = false
        showsLibraryOnThisDevice = false
        libraryScrollTarget = nil
        navigationPaths[.library] = []
        libraryRootGeneration = UUID()
        selectedTab = .library
        isPlayerPresented = false
        isSettingsPresented = false
    }

    /// Library root, then its Cached songs page; used by the offline banner so cached audio has one home.
    func openCachedSongs() {
        openLibrary()
        showsLibraryCachedSongs = true
    }

    /// Library root, then On this device; the offline banner's action.
    func openOnThisDevice() {
        openLibrary()
        showsLibraryOnThisDevice = true
    }

    /// Library root scrolled to the followed artists, for Settings > Following.
    func openFollowingInLibrary() {
        openLibrary()
        libraryScrollTarget = .following
    }

    /// Opens a collection page on the current tab, closing the player first so the page is visible.
    func open(_ collection: MusicCollection) {
        finishSearchResultInteraction(collectionID: collection.id)
        isPlayerPresented = false
        isSettingsPresented = false
        var path = navigationPaths[selectedTab] ?? []
        if path.last?.id != collection.id { path.append(collection) }
        navigationPaths[selectedTab] = path
    }

    func navigationPath(for tab: AppTab) -> Binding<[MusicCollection]> {
        Binding { [weak self] in self?.navigationPaths[tab] ?? [] } set: { [weak self] value in
            self?.navigationPaths[tab] = value
            if tab == .search, !value.isEmpty { self?.dismissSearchKeyboard() }
        }
    }

    /// Opens an artist's page. Credits parsed from a title carry no id, so those are looked up by name first;
    /// when no artist page matches closely enough, search shows what the catalog has.
    func openArtist(_ credit: ArtistCredit, searchSource: SearchSelectionSource? = nil) async {
        guard !Task.isCancelled else { return }
        cancelPendingArtistLookup()
        dismissSearchKeyboard()
        let searchReset = library.searchHistoryResetRevision
        if let page = credit.collection {
            if let searchSource { activateSearchSelection(.collection(page), source: searchSource) }
            else { open(page) }
            return
        }
        let name = credit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let generation = artistLookupGeneration
        let originTab = selectedTab
        isArtistLookupPending = true
        defer { if artistLookupGeneration == generation { isArtistLookupPending = false } }
        var match: MusicCollection?
        do {
            let page = try await catalog.search(query: name, filter: .artists, continuation: nil)
            match = SearchRelevance.matchedArtist(in: page.collections, query: name, correctedQuery: page.correctedQuery)
        } catch { }
        guard artistLookupGeneration == generation, selectedTab == originTab, !Task.isCancelled else { return }
        if let match {
            if let searchSource, library.searchHistoryResetRevision == searchReset {
                activateSearchSelection(.collection(match), source: searchSource)
            } else { open(match) }
        }
        else { openSearch(name) }
    }

    /// View-local destinations and sheets can supersede a lookup without changing a model binding.
    func cancelPendingArtistLookup() {
        cancelPendingWidgetOpen()
        artistLookupGeneration = UUID()
        isArtistLookupPending = false
    }

    func cancelPendingWidgetOpen() {
        widgetOpenTask?.cancel()
        widgetOpenTask = nil
    }

    // MARK: Taste

    /// Disliking skips the song when it is playing; the choice also removes it from mixes and future autoplay.
    func toggleDislike(_ track: Track) {
        let wasDisliked = library.isDisliked(track)
        library.toggleDislike(track)
        guard !wasDisliked, library.isDisliked(track) else {
            if wasDisliked { showToast("Removed from disliked songs") }
            return
        }
        homeSections = homeSections.map { section in
            var section = section
            section.tracks.removeAll { $0.id == track.id }
            return section
        }
        if player.isRadioSession {
            for index in player.queue.indices.reversed() where index != player.currentIndex {
                if ExperienceRadioEngine.isDisliked(player.queue[index], disliked: library.disliked) {
                    player.removeFromQueue(at: index)
                }
            }
        }
        if player.currentTrack?.id == track.id, player.queue.count > 1 || player.isRadioSession, player.isPlaying || player.isLoading {
            player.next(recordsSignal: false)
        }
        showToast("You won’t hear \(track.title) in mixes or autoplay.")
    }

    // MARK: Following

    func isFollowing(_ artist: MusicCollection) -> Bool {
        artist.kind == .artist && library.isFollowing(artistID: artist.id)
    }

    func isFollowPending(_ artist: MusicCollection) -> Bool { followTasks.contains(artist.id) }

    /// Follows or unfollows; following records the artist's current releases as the baseline so only later
    /// releases are announced, and asks for notification permission the first time when alerts are on.
    func toggleFollow(_ artist: MusicCollection) async {
        guard artist.kind == .artist, !followTasks.contains(artist.id) else { return }
        if library.isFollowing(artistID: artist.id) {
            library.unfollow(artistID: artist.id)
            showToast("Unfollowed \(artist.title)")
            return
        }
        followTasks.insert(artist.id)
        defer { followTasks.remove(artist.id) }
        var followed = FollowedArtist(id: artist.id, name: artist.title, artworkURL: artist.artworkURL)
        if let page = try? await catalog.artist(id: artist.id) {
            followed.knownReleaseIDs = page.releases.map(\.id)
            followed.hasEstablishedReleaseBaseline = true
            followed.lastCheckedAt = Date()
            if followed.artworkURL == nil { followed.artworkURL = page.artworkURL }
        }
        library.follow(followed)
        guard library.isFollowing(artistID: artist.id) else { return }
        if library.preferences.newReleaseAlerts {
            let granted = await releases.requestAlertsAuthorization()
            showToast(granted ? "Following \(artist.title). You’ll hear about new releases."
                              : "Following \(artist.title). Turn on notifications in Settings for release alerts.")
        } else {
            showToast("Following \(artist.title)")
        }
    }

    /// Foreground and background refresh entry point for release checks.
    func checkForNewReleases(force: Bool = false) async -> Int {
        guard !isOffline else { return 0 }
        releaseChecksInFlight += 1
        defer { releaseChecksInFlight -= 1 }
        return await releases.checkNow(force: force)
    }

    // MARK: Search

    func consumeSearchFocusRequest(_ request: Int) -> Bool {
        guard request > consumedSearchFocusRequest, request == searchFocusRequest,
              selectedTab == .search, navigationPaths[.search, default: []].isEmpty,
              !isPlayerPresented, !isSettingsPresented else { return false }
        consumedSearchFocusRequest = request
        return true
    }

    func dismissSearchKeyboard() {
        consumedSearchFocusRequest = searchFocusRequest
        searchFocusDismissal += 1
    }

    func commitSearch() {
        cancelPendingArtistLookup()
    }

    private func finishSearchResultInteraction(trackID: String? = nil, collectionID: String? = nil) {
        cancelPendingArtistLookup()
        dismissSearchKeyboard()
    }

    var hasExecutedCurrentSearch: Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return !query.isEmpty && executedSearchQuery == query
    }

    func activateSearchSelection(_ selection: SearchSelection, source: SearchSelectionSource) {
        cancelPendingArtistLookup()
        if isOffline, case .collection = selection {
            showToast("This page needs a connection. You can keep listening to cached songs.")
            return
        }
        let saved = library.recordSearchSelection(selection)
        log.info("event=search_selection source=\(source.rawValue, privacy: .public) saved=\(saved ? 1 : 0)")
        if !saved, let error = library.errorMessage { showToast(error) }
        switch selection {
        case .track(let track): play(track)
        case .collection(var collection):
            collection.tracks = []
            open(collection)
        }
    }

    func removeRecentSearchSelection(id: String) {
        if !library.removeRecentSearchSelection(id: id), let error = library.errorMessage { showToast(error) }
    }

    func clearRecentSearchSelections() {
        cancelPendingArtistLookup()
        if !library.clearRecentSearches(), let error = library.errorMessage { showToast(error) }
    }

    /// Explicit refreshes supersede artist navigation even when the search input is unchanged.
    func search() async {
        cancelPendingArtistLookup()
        await loadSearch()
    }

    /// Lifecycle and debounce work belongs to the existing input intent, which may precede an artist tap.
    func loadSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = searchFilter
        let generation = UUID()
        searchGeneration = generation
        searchError = nil
        searchPage = CatalogPage()
        completedSearch = nil
        hasSearched = false
        // The result set is being replaced, so warm work for the old one stops here.
        playbackWarmer.cancel(owner: PlaybackWarmer.searchOwner)
        guard !query.isEmpty, !isOffline else {
            isSearching = false
            executedSearchQuery = nil
            return
        }
        executedSearchQuery = query
        isSearching = true
        // After the first results, isSearching belongs to pagination; the later clear must not end a page load.
        var publishedFirstResults = false
        defer { if searchGeneration == generation, !publishedFirstResults { isSearching = false } }
        let isCurrent = { [weak self] in
            guard let self else { return false }
            return self.searchGeneration == generation && query == self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                && filter == self.searchFilter
        }
        do {
            let started = ContinuousClock.now
            if let composite = catalog as? CompositeCatalog {
                // YouTube Music's results show and warm as soon as they arrive; slower extra sources join their sections later.
                var primaryMS: Int?
                for try await update in await composite.progressiveSearch(query: query, filter: filter) {
                    try Task.checkCancellation()
                    guard isCurrent() else { return }
                    switch update {
                    case .primary(let page):
                        primaryMS = Int(started.duration(to: .now) / .milliseconds(1))
                        publishSearch(page, query: query, filter: filter)
                        isSearching = false
                        publishedFirstResults = true
                    case .secondary(_, let page):
                        var trackIDs = Set(searchPage.tracks.map(\.id))
                        var collectionIDs = Set(searchPage.collections.map(\.id))
                        searchPage.tracks += page.tracks.filter { trackIDs.insert($0.id).inserted }
                        searchPage.collections += page.collections.filter { collectionIDs.insert($0.id).inserted }
                    }
                }
                let totalMS = Int(started.duration(to: .now) / .milliseconds(1))
                log.info("event=search_loaded first_results_ms=\(primaryMS ?? -1) complete_ms=\(totalMS) progressive=1")
            } else {
                // Only the Search screen asks every enabled catalog; internal lookups stay with the primary source.
                let page = try await CompositeCatalog.searchingAllSources { try await catalog.search(query: query, filter: filter, continuation: nil) }
                try Task.checkCancellation()
                guard isCurrent() else { return }
                publishSearch(page, query: query, filter: filter)
            }
        } catch {
            guard searchGeneration == generation, query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                  filter == searchFilter, !Task.isCancelled else { return }
            hasSearched = true
            searchError = error.localizedDescription
        }
    }

    private func publishSearch(_ page: CatalogPage, query: String, filter: SearchFilter) {
        searchPage = page
        completedSearch = SearchIdentity(query: query, filter: filter)
        hasSearched = true
        playbackWarmer.warm(page.tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
    }

    func loadMoreSearch() async {
        guard !isOffline, !isSearching, let continuation = searchPage.continuation else { return }
        let generation = searchGeneration
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = searchFilter
        guard completedSearch == SearchIdentity(query: query, filter: filter) else { return }
        isSearching = true
        searchError = nil
        defer { if searchGeneration == generation { isSearching = false } }
        do {
            let page = try await catalog.search(query: query, filter: filter, continuation: continuation)
            try Task.checkCancellation()
            guard generation == searchGeneration, query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                  filter == searchFilter else { return }
            var trackIDs = Set(searchPage.tracks.map(\.id))
            var collectionIDs = Set(searchPage.collections.map(\.id))
            searchPage.tracks += page.tracks.filter { trackIDs.insert($0.id).inserted }
            searchPage.collections += page.collections.filter { collectionIDs.insert($0.id).inserted }
            searchPage.continuation = page.continuation
        } catch {
            guard generation == searchGeneration, query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                  filter == searchFilter, !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }

    // MARK: Playback

    /// Album and playlist pages call this as their songs arrive and `cancelWarmPlayback` when they leave.
    static let homeWarmOwner = "home"

    func warmPlayback(_ tracks: [Track], surface: PlaybackWarmer.Surface, owner: String) {
        playbackWarmer.warm(tracks, surface: surface, owner: owner)
    }

    func cancelWarmPlayback(owner: String) {
        playbackWarmer.cancel(owner: owner)
    }

    @discardableResult
    func play(_ track: Track, in tracks: [Track] = []) -> Bool {
        if isOffline, hasLoadedCachedSongs, cachedSongsUsage != nil, !cachedPlayableTrackIDs.contains(track.id) {
            showToast("This song isn’t cached. Choose a cached song to keep listening offline.")
            return false
        }
        finishSearchResultInteraction(trackID: track.id)
        endRadioSession()
        retireAutoplayContinuation()
        let candidates = tracks.isEmpty ? [track] : tracks
        let origin = queueOrigin(for: candidates)
        let queue = isOffline && cachedSongsUsage != nil ? candidates.filter { cachedPlayableTrackIDs.contains($0.id) } : candidates
        if let index = queue.firstIndex(where: { $0.id == track.id }) { player.play(queue, startingAt: index, origin: origin) }
        else { player.play([track] + queue, origin: origin) }
        return true
    }

    func play(_ tracks: [Track], shuffle: Bool = false) {
        let queue = isOffline && cachedSongsUsage != nil ? tracks.filter { cachedPlayableTrackIDs.contains($0.id) } : tracks
        guard !queue.isEmpty else { showToast("There are no songs in this mix yet."); return }
        finishSearchResultInteraction(trackID: queue.first?.id)
        endRadioSession()
        retireAutoplayContinuation()
        let origin = queueOrigin(for: tracks)
        if shuffle { player.playShuffled(queue, origin: origin) }
        else { player.play(queue, shuffle: false, origin: origin) }
    }

    /// Queue navigation keeps the current radio identity but supersedes any pending station tap.
    func playQueueTrack(at index: Int) {
        guard player.queue.indices.contains(index) else { return }
        cancelPendingArtistLookup()
        cancelPendingRadio()
        retireRadioContinuation()
        retireAutoplayContinuation()
        playbackIntentGeneration = UUID()
        dismissSearchKeyboard()
        let isRadio = player.isRadioSession
        if !isRadio { radioSession = nil }
        _ = player.selectQueueTrack(at: index)
    }

    // MARK: Song and artist radio

    private struct SeededRadioSession {
        let id = UUID()
        let seed: RadioSeed
        let anchors: [Track]
        var tuning: RadioTuning
        var round = 0
    }

    var activeRadioSeed: RadioSeed? { player.isRadioSession ? seededSession?.seed : nil }
    var seedRadioSessionID: UUID? { player.isRadioSession ? seededSession?.id : nil }
    var radioTuning: RadioTuning { seededSession?.tuning ?? RadioTuning() }

    var radioSuggestions: [Track] {
        let recents = library.preferences.saveListeningHistory ? library.recentlyPlayed.map(\.track) : []
        var seen = Set<String>()
        return Array((library.superLikes + recents + library.favorites).filter {
            $0.isAudioRecording == true && !library.isDisliked($0) && seen.insert($0.id).inserted
        }.prefix(8))
    }

    @discardableResult
    func startRadio(seed: RadioSeed, tuning: RadioTuning = RadioTuning()) -> Task<Void, Never> {
        cancelPendingRadio()
        pendingRadioSeed = seed
        pendingRadioTuning = tuning
        guard library.hasLoadedDocument else {
            let message = "Reload your saved library before starting radio. Your radio history has been kept."
            seedRadioError = message
            showToast(message)
            return Task { }
        }
        guard !isOffline else {
            seedRadioError = "Radio needs an internet connection. Your current queue is still available."
            return Task { }
        }
        cancelPendingArtistLookup()
        dismissSearchKeyboard()
        playbackWarmer.cancel()
        let token = UUID()
        seedRadioStartGeneration = token
        let control = player.controlRevision
        let epoch = library.listeningHistoryEpoch
        let engine = seedRadioEngine
        let dislikes = library.disliked
        let resting = tasteProfile().restingSongs
        let began = ContinuousClock.now
        isStartingSeedRadio = true
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.seedRadioStartGeneration == token {
                    self?.isStartingSeedRadio = false
                    self?.seedRadioStartTask = nil
                }
            }
            do {
                let anchors = try await engine.anchors(for: seed, disliked: dislikes, resting: resting)
                try Task.checkCancellation()
                guard let self, self.seedRadioStartGeneration == token, self.player.controlRevision == control,
                      self.library.listeningHistoryEpoch == epoch, !self.isOffline else { return }
                let profile = self.listeningLanguageProfile
                // The explicitly chosen recording starts the session; tuning governs recommendations after it.
                let eligible = SeedRadioEngine.select(anchors, excluding: [], disliked: self.library.disliked,
                    tuning: RadioTuning(), heardTrackIDs: [], languageProfile: profile, limit: 3)
                guard let first = eligible.first else { throw SeedRadioError.exhausted(language: tuning.language) }
                self.retireRadioContinuation()
                self.retireAutoplayContinuation()
                self.playbackIntentGeneration = UUID()
                self.needsInitialPlaybackRestore = false
                // Choosing radio for the installed song preserves its occurrence, position and manual queue edits.
                if self.player.currentTrack?.id != first.id || self.player.isLiveRadio {
                    self.player.play([first], isRadio: true, shuffle: false)
                }
                guard self.player.configureSeedRadio(keeping: first.id) else {
                    throw MusicServiceError.unavailable("Radio couldn’t start. Your current queue was kept.")
                }
                self.radioSession = nil
                self.selectedRadioExperience = nil
                self.seededSession = SeededRadioSession(seed: seed, anchors: anchors, tuning: tuning)
                self.seedRadioError = nil
                self.pendingRadioSeed = nil
                self.seedRadioHistory.record(seed: seed, tuning: tuning, historyEpoch: epoch,
                    enabled: self.library.preferences.saveListeningHistory)
                self.log.info("event=seed_radio_start outcome=accepted kind=\(seed.kind, privacy: .public) elapsed_ms=\(began.duration(to: .now) / .milliseconds(1))")
            } catch {
                guard let self, self.seedRadioStartGeneration == token, !Task.isCancelled,
                      self.player.controlRevision == control else { return }
                self.seedRadioError = error.localizedDescription
                self.showToast(error.localizedDescription)
                self.log.notice("event=seed_radio_start outcome=failed kind=\(seed.kind, privacy: .public)")
            }
        }
        seedRadioStartTask = task
        return task
    }

    func cancelSeedRadioStart() {
        seedRadioStartGeneration = UUID()
        seedRadioStartTask?.cancel()
        seedRadioStartTask = nil
        isStartingSeedRadio = false
        seedRadioError = nil
        pendingRadioSeed = nil
    }

    func retrySeedRadioStart() {
        guard let seed = pendingRadioSeed else { return }
        startRadio(seed: seed, tuning: pendingRadioTuning)
    }

    func tuneRadio(_ tuning: RadioTuning) {
        guard player.isRadioSession, seededSession != nil, radioTuning != tuning else { return }
        let needsRecovery = radioContinuationError != nil || isContinuingRadio
        retireRadioContinuation()
        seededSession?.tuning = tuning
        player.refreshSeedRadioRequests()
        if needsRecovery {
            radioContinuationError = "Radio updated. Choose Try More Songs to continue with these settings."
        }
        if let seed = activeRadioSeed {
            seedRadioHistory.record(seed: seed, tuning: tuning, historyEpoch: library.listeningHistoryEpoch,
                                    enabled: library.preferences.saveListeningHistory)
        }
        log.info("event=seed_radio_tune familiarity=\(tuning.familiarity.rawValue, privacy: .public) language=\(tuning.language?.rawValue ?? "automatic", privacy: .public)")
    }

    private func resetSeedRadioLearning() {
        cancelSeedRadioStart()
        synchronizeSeedRadioHistory()
        if seededSession != nil {
            retireRadioContinuation()
            player.refreshSeedRadioRequests()
        }
    }

    private func synchronizeSeedRadioHistory() {
        guard library.hasLoadedDocument else { return }
        seedRadioHistory.synchronize(historyEpoch: library.listeningHistoryEpoch, enabled: library.preferences.saveListeningHistory)
    }

    /// Until the library loads, its epoch is untrustworthy, so the deferred signal store keeps waiting.
    private func synchronizeListeningSignals() {
        guard library.hasLoadedDocument else { return }
        listeningSignalStore.synchronize(historyEpoch: library.listeningHistoryEpoch,
                                         enabled: library.preferences.saveListeningHistory)
    }

    /// Generated mixes reach playback as plain track lists, so their exact membership identifies them.
    private func queueOrigin(for tracks: [Track]) -> ListeningSignal.Origin {
        let ids = Set(tracks.map(\.id))
        guard !ids.isEmpty else { return .chosen }
        let mixes = library.mixes.map(\.tracks) + momentMixes.collections.map(\.tracks)
        return mixes.contains { Set($0.map(\.id)) == ids } ? .generated : .chosen
    }

    private func continueSeedRadio(forceRefresh: Bool = false) async -> [Track] {
        guard let session = seededSession, player.isRadioSession, !isOffline, !Task.isCancelled else { return [] }
        let token = UUID()
        radioContinuationGeneration = token
        let intent = playbackIntentGeneration
        isContinuingRadio = true
        radioContinuationError = nil
        let began = ContinuousClock.now
        defer { if radioContinuationGeneration == token { isContinuingRadio = false } }
        do {
            let heard = library.preferences.saveListeningHistory ? tasteProfile().heardTrackIDs : Set(library.favorites.map(\.id))
            let resting = library.preferences.saveListeningHistory ? tasteProfile().restingSongs : RestingSongs()
            let tracks = try await seedRadioEngine.refill(anchors: session.anchors, round: session.round,
                excluding: player.radioRecentTracks + player.queue, disliked: library.disliked,
                tuning: session.tuning, heardTrackIDs: heard,
                languageProfile: listeningLanguageProfile, resting: resting, forceRefresh: forceRefresh)
            try Task.checkCancellation()
            guard radioContinuationGeneration == token, seededSession?.id == session.id, player.isRadioSession,
                  playbackIntentGeneration == intent, !isOffline else { return [] }
            let selected = SeedRadioEngine.select(tracks, excluding: player.radioRecentTracks + player.queue, disliked: library.disliked,
                tuning: session.tuning, heardTrackIDs: heard, languageProfile: listeningLanguageProfile, resting: resting)
            guard !selected.isEmpty else { throw SeedRadioError.exhausted(language: session.tuning.language) }
            seededSession?.round += 1
            log.info("event=seed_radio_refill outcome=ready count=\(selected.count) elapsed_ms=\(began.duration(to: .now) / .milliseconds(1))")
            return selected
        } catch {
            guard !Task.isCancelled, radioContinuationGeneration == token, seededSession?.id == session.id,
                  playbackIntentGeneration == intent, player.isRadioSession else { return [] }
            radioContinuationError = error.localizedDescription
            log.notice("event=seed_radio_refill outcome=failed")
            return []
        }
    }

    // MARK: Legacy experience radio compatibility

    var radioExperiences: [RadioExperience] {
        // Affinity moves the stations the listener's genres match to the front of their group; content is unchanged.
        ExperienceRadioEngine.orderedStations(RadioExperience.discoveryStations, genreProfile: listeningGenreProfile)
    }

    var activeRadioExperience: RadioExperience? {
        player.isRadioSession ? radioSession?.experience : nil
    }

    var activeRadioContentLabel: String? {
        guard player.isRadioSession, let session = radioSession else { return nil }
        if let profile = session.languageProfile { return session.experience.selection(for: profile).contentLabel }
        return session.experience.selection(for: session.languages)?.contentLabel
    }

    func isActiveRadio(_ experience: RadioExperience) -> Bool {
        player.isRadioSession && radioSession?.experience.stationID == experience.stationID
    }

    var radioSessionLabel: String? {
        guard player.isRadioSession else { return nil }
        if let activeRadioSeed { return activeRadioSeed.radioTitle }
        return activeRadioExperience?.radioTitle ?? "Radio"
    }

    @discardableResult
    func startRadio(_ experience: RadioExperience, languages selectedLanguages: Set<MusicLanguage>? = nil) -> Task<Void, Never> {
        guard !isOffline else {
            showToast("Radio needs a connection. You can keep listening to cached songs.")
            return Task { }
        }
        needsInitialPlaybackRestore = false
        cancelPendingArtistLookup()
        cancelPendingRadio()
        dismissSearchKeyboard()
        let generation = UUID()
        radioSelectionGeneration = generation
        selectedRadioExperience = experience
        isLoadingRadio = true
        radioError = nil
        let engine = experienceRadio
        let disliked = library.disliked
        let preferencesAtStart = library.preferences.languages
        let nudgesAtStart = library.preferences.languageNudges
        let languages = selectedLanguages ?? []
        let usesPreferences = selectedLanguages == nil
        let languageProfile = usesPreferences ? listeningLanguageProfile : nil
        radioRequestLanguages = languages
        radioRequestUsesPreferences = usesPreferences
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.radioSelectionGeneration == generation {
                    self?.isLoadingRadio = false
                    self?.radioSelectionTask = nil
                }
            }
            do {
                let batch = try await engine.start(experience, disliked: disliked, languages: languages, languageProfile: languageProfile)
                try Task.checkCancellation()
                guard let self, self.radioSelectionGeneration == generation,
                      !usesPreferences || (self.library.preferences.languages == preferencesAtStart
                                           && self.library.preferences.languageNudges == nudgesAtStart) else { return }
                let currentDislikes = self.library.disliked
                let tracks = ExperienceRadioEngine.selection(buckets: [batch.tracks], disliked: currentDislikes, languages: languages,
                                                             languageProfile: languageProfile).tracks
                let trackIDs = Set(tracks.map(\.id))
                let buckets = batch.buckets.filter { trackIDs.contains($0.anchor.id) }
                guard tracks.count >= ExperienceRadioEngine.minimumQueueSize, !buckets.isEmpty,
                      !trackIDs.isDisjoint(with: batch.discoveryTrackIDs) else {
                    throw ExperienceRadioError.tooFewSongs
                }
                self.retireRadioContinuation()
                self.seededSession = nil
                self.playbackIntentGeneration = UUID()
                self.radioSession = RadioSession(experience: experience, buckets: buckets, languages: languages,
                                                 usesDiscoveryPreferences: usesPreferences, languageProfile: languageProfile)
                if self.player.shuffleEnabled { self.player.toggleShuffle() }
                self.player.play(tracks, isRadio: true)
            } catch {
                guard let self, self.radioSelectionGeneration == generation,
                      !usesPreferences || (self.library.preferences.languages == preferencesAtStart
                                           && self.library.preferences.languageNudges == nudgesAtStart), !Task.isCancelled else { return }
                self.radioError = error.localizedDescription
            }
        }
        radioSelectionTask = task
        return task
    }

    func cancelPendingRadio() {
        cancelSeedRadioStart()
        radioSelectionGeneration = UUID()
        radioSelectionTask?.cancel()
        radioSelectionTask = nil
        isLoadingRadio = false
        radioError = nil
        selectedRadioExperience = activeRadioExperience
        radioRequestLanguages = player.isRadioSession ? radioSession?.languages : nil
        radioRequestUsesPreferences = player.isRadioSession ? radioSession?.usesDiscoveryPreferences ?? true : true
    }

    func retryRadio() {
        if let experience = selectedRadioExperience {
            startRadio(experience, languages: radioRequestUsesPreferences ? nil : radioRequestLanguages)
        }
    }

    func retryRadioContinuation() {
        if let sessionID = seedRadioSessionID {
            guard !isContinuingRadio else { return }
            let control = player.controlRevision
            radioRetryTask?.cancel()
            radioRetryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let tracks = await self.continueSeedRadio(forceRefresh: true)
                guard !Task.isCancelled, self.seedRadioSessionID == sessionID,
                      self.player.controlRevision == control, !tracks.isEmpty else { return }
                self.player.appendAutoplay(tracks)
            }
            return
        }
        guard player.isRadioSession, let session = radioSession, let track = player.currentTrack,
              !isContinuingRadio else { return }
        radioRetryTask?.cancel()
        let intent = playbackIntentGeneration
        radioRetryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.playbackIntentGeneration == intent,
                  self.player.isRadioSession, self.radioSession?.id == session.id else { return }
            let tracks = await self.continueRadio(after: track, session: session, forceRefresh: true)
            guard !Task.isCancelled, self.player.isRadioSession, self.radioSession?.id == session.id,
                  self.playbackIntentGeneration == intent else { return }
            self.player.appendAutoplay(tracks)
        }
    }

    /// Handoff and nearby-device continuations retire the same radio and Autoplay work as a fresh selection.
    func retireSessionsForContinuation() {
        endRadioSession()
        retireAutoplayContinuation()
    }

    private func endRadioSession() {
        cancelPendingRadio()
        retireRadioContinuation()
        playbackIntentGeneration = UUID()
        radioSession = nil
        seededSession = nil
        selectedRadioExperience = nil
        radioRequestLanguages = nil
        radioRequestUsesPreferences = true
    }

    private func retireRadioContinuation() {
        radioContinuationGeneration = UUID()
        radioRetryTask?.cancel()
        radioRetryTask = nil
        isContinuingRadio = false
        radioContinuationError = nil
    }

    private func continueRadio(after track: Track, session: RadioSession, forceRefresh: Bool = false) async -> [Track] {
        guard !isOffline, !Task.isCancelled, player.isRadioSession, radioSession?.id == session.id else { return [] }
        let generation = UUID()
        radioContinuationGeneration = generation
        let intent = playbackIntentGeneration
        isContinuingRadio = true
        radioContinuationError = nil
        defer { if radioContinuationGeneration == generation { isContinuingRadio = false } }
        do {
            let batch = try await experienceRadio.continueRadio(buckets: session.buckets, round: session.round,
                queue: player.queue + [track], disliked: library.disliked, languages: session.languages,
                experience: session.experience, forceRefresh: forceRefresh, languageProfile: session.languageProfile)
            try Task.checkCancellation()
            guard radioContinuationGeneration == generation, radioSession?.id == session.id,
                  playbackIntentGeneration == intent, player.isRadioSession else { return [] }
            let tracks = ExperienceRadioEngine.selection(buckets: [batch.tracks], excluding: player.queue + [track],
                                                          disliked: library.disliked, languages: session.languages,
                                                          languageProfile: session.languageProfile).tracks
            guard !tracks.isEmpty else { throw ExperienceRadioError.unavailable }
            radioSession?.buckets = batch.buckets
            radioSession?.round += 1
            return tracks
        } catch {
            guard radioContinuationGeneration == generation, radioSession?.id == session.id,
                  playbackIntentGeneration == intent, player.isRadioSession, !Task.isCancelled else { return [] }
            radioContinuationError = error.localizedDescription
            return []
        }
    }

    private func withoutDisliked(_ sections: [DiscoverySection]) -> [DiscoverySection] {
        let disliked = library.dislikedTrackIDs
        guard !disliked.isEmpty else { return sections }
        return sections.map { section in
            var section = section
            section.tracks.removeAll { disliked.contains($0.id) }
            return section
        }
    }

    // MARK: Autoplay continuation

    /// Autoplay continuation: the provider's radio for the song that is ending, minus anything queued or
    /// disliked and minus other versions of songs already in the queue, so a remix never follows its original.
    /// The final end-of-queue attempt asks for a fresh radio; the early answer is still cached and would repeat itself.
    private func autoplayTracks(after track: Track, final: Bool = false) async -> [Track] {
        guard !Task.isCancelled else { return [] }
        if player.isRadioSession, seededSession != nil { return await continueSeedRadio() }
        if player.isRadioSession, let session = radioSession { return await continueRadio(after: track, session: session) }
        return await continueAutoplay(after: track, forceRefresh: final)
    }

    /// Queue-sheet retry for an ordinary queue: a fresh request for the last song in play order. After the queue has
    /// ended, the player continues into the new songs; a paused queue that has not ended only grows.
    func retryAutoplayContinuation() {
        guard !player.isRadioSession, player.settings.autoplay, !isContinuingAutoplay, let track = player.queue.last else { return }
        autoplayContinuationError = nil
        isContinuingAutoplay = true
        autoplayRetryTask?.cancel()
        let intent = playbackIntentGeneration
        autoplayRetryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let tracks = await self.continueAutoplay(after: track, forceRefresh: true)
            // An empty answer must not end a wait the player holds for its own request.
            guard !Task.isCancelled, !tracks.isEmpty, self.playbackIntentGeneration == intent, !self.player.isRadioSession else { return }
            self.player.appendAutoplay(tracks)
        }
    }

    private func retireAutoplayContinuation() {
        autoplayContinuationGeneration = UUID()
        autoplayRetryTask?.cancel()
        autoplayRetryTask = nil
        isContinuingAutoplay = false
        autoplayContinuationError = nil
    }

    /// At most `AutoplayContinuation.maximumProviderCalls` calls: the ending song's radio, one other queue song's radio
    /// when that batch is thin, and one fresh request for the ending song after a transient failure. `forceRefresh`
    /// (final end-of-queue attempt, manual retry) makes the first call bypass a cached radio; cooldowns still apply.
    private func continueAutoplay(after track: Track, forceRefresh: Bool) async -> [Track] {
        guard !isOffline else { return [] }
        // Autoplay picks for the listener, so songs resting after early skips stay out; explicit plays never check.
        let resting = tasteProfile().restingSongs
        let generation = UUID()
        autoplayContinuationGeneration = generation
        let intent = playbackIntentGeneration
        let isRadio = player.isRadioSession
        isContinuingAutoplay = true
        autoplayContinuationError = nil
        defer { if autoplayContinuationGeneration == generation { isContinuingAutoplay = false } }
        func current() -> Bool {
            !Task.isCancelled && autoplayContinuationGeneration == generation && playbackIntentGeneration == intent
                && player.isRadioSession == isRadio
        }
        var selected: [Track] = []
        var errors: [any Error] = []
        var primarySucceeded = false
        var calls = 1
        do {
            let radio = if forceRefresh {
                try await catalog.radio(seed: track, forceRefresh: true)
            } else {
                try await catalog.radio(seed: track)
            }
            guard current() else { return [] }
            primarySucceeded = true
            selected = Self.autoplaySelection(from: resting.excluding(radio), queue: player.queue + [track], disliked: library.dislikedTrackIDs)
        } catch is CancellationError {
            return []
        } catch {
            guard current() else { return [] }
            errors.append(error)
        }

        // Same-album queues starve the ending song's radio; another queue song opens a different neighborhood.
        if selected.count < AutoplayContinuation.minimumBatch, !errors.contains(where: AutoplayContinuation.endsAttempts),
           let seed = AutoplayContinuation.fallbackSeed(queue: player.queue, after: track, recentIDs: library.recentlyPlayed.map(\.id),
                                                        autoplayIDs: player.autoplayTrackIDs, disliked: library.dislikedTrackIDs,
                                                        resting: resting) {
            calls += 1
            log.info("event=autoplay_retry attempt=\(calls) reason=\(primarySucceeded ? "thin" : "failed", privacy: .public)")
            do {
                let radio = try await catalog.radio(seed: seed, forceRefresh: false)
                guard current() else { return [] }
                selected += Self.autoplaySelection(from: resting.excluding(radio), queue: player.queue + [track] + selected,
                                                   disliked: library.dislikedTrackIDs,
                                                   limit: AutoplayContinuation.limit - selected.count)
            } catch is CancellationError {
                return []
            } catch {
                guard current() else { return [] }
                errors.append(error)
            }
        }

        if selected.isEmpty, !primarySucceeded, let first = errors.first, AutoplayContinuation.allowsFreshRetry(first),
           !errors.contains(where: AutoplayContinuation.endsAttempts) {
            calls += 1
            log.info("event=autoplay_retry attempt=\(calls) reason=refresh")
            do {
                try await Task.sleep(for: AutoplayContinuation.retryDelay)
                guard current() else { return [] }
                let radio = try await catalog.radio(seed: track, forceRefresh: true)
                guard current() else { return [] }
                primarySucceeded = true
                selected = Self.autoplaySelection(from: resting.excluding(radio), queue: player.queue + [track], disliked: library.dislikedTrackIDs)
            } catch is CancellationError {
                return []
            } catch {
                guard current() else { return [] }
                errors.append(error)
            }
        }

        guard current() else { return [] }
        if selected.isEmpty {
            let failure = AutoplayContinuation.failure(primarySucceeded: primarySucceeded, errors: errors)
            log.info("event=autoplay_exhausted reason=\(failure.rawValue, privacy: .public) calls=\(calls)")
            if !player.isRadioSession { autoplayContinuationError = failure.message }
        }
        return selected
    }

    static func autoplaySelection(from radio: [Track], queue: [Track], disliked: Set<String>,
                                 limit: Int = AutoplayContinuation.limit) -> [Track] {
        var excluded = Set(queue.map(\.id)).union(disliked)
        var titles = Set(queue.map { SongTitle.core($0.title) })
        return Array(radio.filter { candidate in
            guard !excluded.contains(candidate.id), candidate.isAudioRecording != false else { return false }
            let core = SongTitle.core(candidate.title)
            guard core.isEmpty || titles.insert(core).inserted else { return false }
            excluded.insert(candidate.id)
            return true
        }.prefix(max(0, limit)))
    }

    func showToast(_ text: String) {
        toast = text
        AppAccessibilityAnnouncements.post(text)
    }

    func openSearch(_ query: String) {
        cancelPendingArtistLookup()
        dismissSearchKeyboard()
        navigationPaths[.search] = []
        searchRootGeneration = UUID()
        searchQuery = query
        searchFilter = .songs
        selectedTab = .search
        isPlayerPresented = false
        isSettingsPresented = false
    }

    private struct RadioSession {
        let id = UUID()
        let experience: RadioExperience
        var buckets: [ExperienceRadioEngine.Bucket]
        // Discovery preference edits apply to future station starts, not the listener's active selection.
        let languages: Set<MusicLanguage>
        let usesDiscoveryPreferences: Bool
        var languageProfile: ListeningLanguageProfile?
        var round = 0
    }

    private enum HomeUpdate: Sendable {
        case sections([DiscoverySection]), personal([DiscoverySection]), chart(ChartSnapshot)
        case discoveryFailure(String), chartFailure
    }

    private struct SearchIdentity: Equatable {
        let query: String
        let filter: SearchFilter
    }
}
