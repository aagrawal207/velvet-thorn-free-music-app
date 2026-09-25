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
    let catalog: any MusicCatalogProviding
    let artistArtwork: ArtistArtworkResolver
    let cloudSync: ICloudLibrarySync
    let appIcons: AppIconController
    let lyrics: any LyricsProviding
    let recordingLanguageService: ArtistSpotlightLanguageService
    let languageDiscovery: ListeningLanguageDiscovery
    let connectivity: ConnectivityMonitor
    /// Optional YouTube sign-in used only for stream lookups.
    let account: YouTubeAccountStore
    let tips: TipJarService
    @ObservationIgnored let releases: ReleaseWatcher
    @ObservationIgnored private let chartProvider: any MusicChartsProviding
    @ObservationIgnored private let engine: RecommendationEngine
    @ObservationIgnored private let experienceRadio: ExperienceRadioEngine
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Discovery")
    @ObservationIgnored private var homeGeneration = UUID()
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var personalizationGeneration = UUID()
    @ObservationIgnored private var completedSearch: SearchIdentity?
    @ObservationIgnored private var loadedLanguageProfileKey: String?
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
    @ObservationIgnored var widgetOpenTask: Task<Void, Never>?

    var widgetLibraryDestination: LibrarySavedSongsView.Kind?
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
    var toast: String?
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
          languageDiscovery: ListeningLanguageDiscovery? = nil,
          connectivity: ConnectivityMonitor? = nil,
          generatesMixes: Bool = true) {
        LyricsDNSConfiguration.configure(enabled: library.preferences.useEncryptedDNS)
        self.generatesMixes = generatesMixes
        let connectivity = connectivity ?? ConnectivityMonitor()
        self.connectivity = connectivity
        self.lastConnectivityWasOffline = connectivity.isOffline
        let player = player ?? PlayerController(resolver: YouTubeStreamResolver(isOffline: { connectivity.isOffline }))
        let catalog = catalog ?? YouTubeMusicService()
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
        self.catalog = catalog
        self.artistArtwork = artistArtwork ?? ArtistArtworkResolver(catalog: catalog)
        self.cloudSync = ICloudLibrarySync(library: library)
        self.account = account ?? YouTubeAccountStore()
        #if DEBUG
        let observingPurchases = !ProcessInfo.processInfo.arguments.contains("--uitesting")
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #else
        let observingPurchases = true
        #endif
        self.appIcons = appIcons ?? AppIconController(enabled: observingPurchases || ProcessInfo.processInfo.arguments.contains("--uitesting"))
        self.tips = TipJarService(library: library, observeTransactions: observingPurchases)
        self.chartProvider = charts ?? YouTubeChartsService()
        let lyrics = lyrics ?? CompositeLyricsProvider(primary: LRCLyricsService(), fallback: catalog as? any LyricsProviding,
                                                      prepareTrack: prepareTrack)
        self.lyrics = lyrics
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
        self.engine = RecommendationEngine(catalog: catalog)
        self.experienceRadio = ExperienceRadioEngine(catalog: catalog)
        self.releases = ReleaseWatcher(library: library, catalog: catalog, notifier: releaseNotifier ?? LocalReleaseNotifier())
        player.setAudioCacheLimit(library.preferences.audioCacheLimit)
        player.updateCacheListeningHistory(library.events)
        player.setNetworkOffline(connectivity.isOffline)
        player.setRemoteFallbackEnabled(library.preferences.allowRemoteFallback)
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
            guard let library, library.recordListening(track: track, sessionID: session, startedAt: started, seconds: seconds) else { return false }
            if player?.currentTrack?.id == track.id {
                library.recordRecent(track: track, position: player?.position ?? 0)
            }
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
        player.onTrackStarted = { [weak library, weak player] track in
            library?.recordRecent(track: track, position: player?.position ?? 0)
        }
        player.onQueueExhausted = { [weak self] track in
            await self?.autoplayTracks(after: track) ?? []
        }
        player.onQueueEnded = { [weak self] track in
            await self?.autoplayTracks(after: track, final: true) ?? []
        }
        library.onHistoryCleared = { [weak self] in
            guard let self else { return }
            self.cancelPendingWidgetOpen()
            self.player.discardPendingListening()
            if self.library.events.isEmpty { self.languageDiscovery.reset() }
            else { self.languageDiscovery.pause() }
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
        self.languageDiscovery.onResultsChanged = { [weak self] in
            self?.loadedAt = nil
        }
        connectivity.onChange = { [weak self] status in
            self?.connectivityChanged(status)
        }
    }

    isolated deinit {
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
        widgetPublisher?.refresh()
        connectivity.start()
        cloudSync.start()
        cloudSync.refresh()
        synchronizeAppIcon()
        refreshListeningLanguages()
        Task { [weak self] in await self?.refreshCachedSongs() }
    }

    func deactivateDeviceServices() {
        deviceServicesAreActive = false
        languageDiscovery.pause()
        widgetPublisher?.refresh()
    }

    func startWidgetUpdates(store: WidgetSnapshotStore = WidgetSnapshotStore(directory: WidgetSnapshotStore.sharedDirectory())) {
        guard widgetPublisher == nil else { widgetPublisher?.refresh(); return }
        widgetPublisher = WidgetSnapshotPublisher(library: library, store: store) {
            for kind in MusicWidgetKind.allCases { WidgetCenter.shared.reloadTimelines(ofKind: kind.widgetKind) }
        }
    }

    var listeningLanguageProfile: ListeningLanguageProfile {
        ListeningLanguageProfile(summary: listeningLanguageSummary(), nudges: library.preferences.languageNudges,
                                 evidence: languageDiscovery.results, overrides: library.recordingLanguageOverrides,
                                 fallback: library.preferences.languages)
    }

    func listeningLanguageSummary(for window: ListeningWindow = .month, now: Date = Date()) -> ListeningLanguageSummary {
        library.languageSummary(for: window, now: now, evidence: languageDiscovery.results)
    }

    func refreshListeningLanguages() {
        languageDiscovery.refresh(events: library.events, overrides: library.recordingLanguageOverrides,
                                  enabled: deviceServicesAreActive && library.preferences.saveListeningHistory && !isOffline)
    }

    func setLanguageNudge(_ nudge: LanguageRecommendationNudge, for language: ArtistSongLanguage) {
        updatePreferences { $0.languageNudges[language] = nudge }
        if let error = library.errorMessage { showToast(error) }
    }

    func resetLanguageNudges() {
        updatePreferences { $0.languageNudges = LanguageRecommendationNudges() }
        if let error = library.errorMessage { showToast(error) }
    }

    private func invalidateRecommendations() {
        retirePersonalization()
        homeGeneration = UUID()
        isLoadingHome = false
        homeError = nil
        loadedLanguageProfileKey = nil
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
        if status == .offline || wasOffline {
            homeGeneration = UUID()
            searchGeneration = UUID()
            isLoadingHome = false
            isSearching = false
            loadedAt = nil
        }
        if status == .offline {
            languageDiscovery.pause()
            retirePersonalization()
            retireAutoplayContinuation()
            retireRadioContinuation()
            if isLoadingRadio || radioError != nil { cancelPendingRadio() }
        } else if deviceServicesAreActive {
            refreshListeningLanguages()
        }
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
                self.cachedSongsError = nil
                self.hasLoadedCachedSongs = true
            } catch {
                guard let self, self.cachedSongsGeneration == generation, !Task.isCancelled else { return }
                self.cachedSongsError = error.localizedDescription
            }
        }
        cachedSongsTask = work
        await work.value
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
        if previous.saveListeningHistory, !applied.saveListeningHistory {
            cancelPendingWidgetOpen()
            player.discardPendingListening()
        }
        if applied.languageNudges != previous.languageNudges || applied.languages != previous.languages
            || applied.discoveryFamiliarity != previous.discoveryFamiliarity {
            invalidateRecommendations()
        }
        applyPreferenceServices(applied, replacing: previous)
        if applied.saveListeningHistory != previous.saveListeningHistory {
            refreshListeningLanguages()
            player.updateCacheListeningHistory(library.events)
        }
    }

    private func applyPreferenceServices(_ applied: UserPreferences, replacing previous: UserPreferences) {
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
        if applied.useEncryptedDNS != previous.useEncryptedDNS {
            LyricsDNSConfiguration.configure(enabled: applied.useEncryptedDNS)
        }
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
        let applied = library.preferences
        homeSections = withoutDisliked(homeSections)
        if isLoadingRadio || radioError != nil { cancelPendingRadio() }
        applyPreferenceServices(applied, replacing: previous)
        refreshListeningLanguages()
        player.updateCacheListeningHistory(library.events)

        // An untouched failed-startup placeholder has no live resume state to take precedence over the saved queue.
        if needsInitialPlaybackRestore {
            player.restore(library.playback)
            needsInitialPlaybackRestore = false
        }
        player.flushListeningProgress()
        hasListeningProfile = !tasteProfile().isColdStart
        showToast(library.errorMessage ?? "Saved library reloaded.")
        return result
    }

    // MARK: Home

    func loadHome(force: Bool = false) async {
        refreshListeningLanguages()
        guard !isOffline else {
            isLoadingHome = false
            homeError = nil
            await refreshCachedSongs()
            return
        }
        let languageProfile = listeningLanguageProfile
        let familiarity = library.preferences.discoveryFamiliarity
        let profileKey = languageProfile.requestKey
        let chartLanguages = Self.chartLanguages(for: languageProfile)
        refreshMixes()
        Task { await checkForNewReleases() }
        if !force, !isLoadingHome, !homeSections.isEmpty, loadedLanguageProfileKey == profileKey,
           loadedDiscoveryFamiliarity == familiarity,
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
                                                                        familiarity: familiarity)) }
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
                                                                           familiarity: familiarity)) }
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
                    if player.currentTrack == nil { player.prefetch(sections.flatMap(\.tracks)) }
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
        let nudges = library.preferences.languageNudges
        let familiarity = library.preferences.discoveryFamiliarity
        let overrides = library.recordingLanguageOverrides
        let fallback = library.preferences.languages
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
                       self?.library.preferences.discoveryFamiliarity == familiarity,
                      self?.library.recordingLanguageOverrides == overrides,
                      self?.library.preferences.languages == fallback else { return }
                guard self?.library.mix(kind)?.periodKey != periodKey else { continue }
                let generated: GeneratedPlaylist?
                switch kind {
                case .discoverWeekly:
                    generated = try? await engine.discoverWeekly(profile: profile, languages: [], periodKey: periodKey,
                                                                languageProfile: languageProfile, familiarity: familiarity)
                case .dailyMix:
                    generated = try? await engine.dailyMix(profile: profile, languages: [], periodKey: periodKey,
                                                          languageProfile: languageProfile, familiarity: familiarity)
                }
                guard !Task.isCancelled, let self, self.personalizationGeneration == generation,
                       self.library.preferences.languageNudges == nudges,
                       self.library.preferences.discoveryFamiliarity == familiarity,
                      self.library.recordingLanguageOverrides == overrides,
                      self.library.preferences.languages == fallback else { return }
                guard var mix = generated, self.library.mix(kind)?.periodKey != periodKey else { continue }
                let disliked = self.library.dislikedTrackIDs
                mix.tracks.removeAll { disliked.contains($0.id) }
                self.library.saveMix(mix)
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

    private func tasteProfile() -> TasteProfile {
        TasteProfile.build(events: library.events, favorites: library.favorites, playlists: library.playlists,
                           recents: library.recentlyPlayed, disliked: library.disliked, now: Date())
    }

    // MARK: Navigation

    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        if url.host?.lowercased() == "widget" { return handleWidgetURL(url) }
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
        navigationPaths[.library] = []
        libraryRootGeneration = UUID()
        selectedTab = .library
        isPlayerPresented = false
        isSettingsPresented = false
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
            player.next()
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
        guard !query.isEmpty, !isOffline else {
            isSearching = false
            executedSearchQuery = nil
            return
        }
        executedSearchQuery = query
        isSearching = true
        defer { if searchGeneration == generation { isSearching = false } }
        do {
            let page = try await catalog.search(query: query, filter: filter, continuation: nil)
            try Task.checkCancellation()
            guard searchGeneration == generation, query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                  filter == searchFilter else { return }
            searchPage = page
            completedSearch = SearchIdentity(query: query, filter: filter)
            hasSearched = true
            if filter == .songs { player.prefetch(page.tracks) }
        } catch {
            guard searchGeneration == generation, query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                  filter == searchFilter, !Task.isCancelled else { return }
            hasSearched = true
            searchError = error.localizedDescription
        }
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
        let queue = isOffline && cachedSongsUsage != nil ? candidates.filter { cachedPlayableTrackIDs.contains($0.id) } : candidates
        if let index = queue.firstIndex(where: { $0.id == track.id }) { player.play(queue, startingAt: index) }
        else { player.play([track] + queue) }
        return true
    }

    func play(_ tracks: [Track], shuffle: Bool = false) {
        let tracks = isOffline && cachedSongsUsage != nil ? tracks.filter { cachedPlayableTrackIDs.contains($0.id) } : tracks
        guard !tracks.isEmpty else { showToast("There are no songs in this mix yet."); return }
        finishSearchResultInteraction(trackID: tracks.first?.id)
        endRadioSession()
        retireAutoplayContinuation()
        if shuffle { player.playShuffled(tracks) }
        else { player.play(tracks, shuffle: false) }
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
        player.play(player.queue, startingAt: index, isRadio: isRadio)
    }

    // MARK: Experience radio

    var radioExperiences: [RadioExperience] {
        RadioExperience.discoveryStations
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

    private func endRadioSession() {
        cancelPendingRadio()
        retireRadioContinuation()
        playbackIntentGeneration = UUID()
        radioSession = nil
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
            selected = Self.autoplaySelection(from: radio, queue: player.queue + [track], disliked: library.dislikedTrackIDs)
        } catch is CancellationError {
            return []
        } catch {
            guard current() else { return [] }
            errors.append(error)
        }

        // Same-album queues starve the ending song's radio; another queue song opens a different neighborhood.
        if selected.count < AutoplayContinuation.minimumBatch, !errors.contains(where: AutoplayContinuation.endsAttempts),
           let seed = AutoplayContinuation.fallbackSeed(queue: player.queue, after: track, recentIDs: library.recentlyPlayed.map(\.id),
                                                        autoplayIDs: player.autoplayTrackIDs, disliked: library.dislikedTrackIDs) {
            calls += 1
            log.info("event=autoplay_retry attempt=\(calls) reason=\(primarySucceeded ? "thin" : "failed", privacy: .public)")
            do {
                let radio = try await catalog.radio(seed: seed, forceRefresh: false)
                guard current() else { return [] }
                selected += Self.autoplaySelection(from: radio, queue: player.queue + [track] + selected, disliked: library.dislikedTrackIDs,
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
                selected = Self.autoplaySelection(from: radio, queue: player.queue + [track], disliked: library.dislikedTrackIDs)
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
